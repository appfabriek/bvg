#requires -Version 5.1
<#
.SYNOPSIS
  bvg installer for Windows. Default: installs as a Windows service running
  under Local System, starts automatically at boot, restarts on crash.

  Optioneel `-Portable` (of `$env:BVG_PORTABLE=1`): service-loze, user-level
  install in %LocalAppData%\bvg, code-sign-keten in de CurrentUser-stores,
  geen Windows-service, geen scheduled task, geen admin/UAC. Starten doe je
  zelf met `bvg.exe daemon` (BVG_INSTALL_DIR wijst de host naar de install-dir).

.DESCRIPTION
  One-liner install:

    $env:BVG_JOIN_TOKEN   = "jt_..."
    $env:BVG_BVGEERT_HOST = "https://staging.rozendom.nl"
    $env:BVG_TRANSPORT    = "mijn-verbinding"   # optional
    iwr https://github.com/appfabriek/bvg/releases/latest/download/install.ps1 -UseBasicParsing | iex

  The script self-elevates via UAC, downloads the latest
  bvg-windows-x64.zip release asset, redeems the join-token (HTTPS
  POST to /api/v1/transport/redeem), saves credentials.json (locked down
  to Administrators + SYSTEM), and registers the Windows service.

  Re-pair without reinstall:

    $env:BVG_CREDENTIALS = "$env:ProgramData\bvg\credentials.json"
    & "$env:ProgramData\bvg\bvg.exe" join --host <host> --token <jt_...>
    Restart-Service bvg
#>

[CmdletBinding()]
param(
  [string]$Repo        = "appfabriek/bvg",
  [string]$ServiceName = "bvg",
  [string]$InstallDir  = (Join-Path $env:ProgramData "bvg"),
  [string]$InstallUrl,
  # Service-loze, user-level install: geen Windows-service, geen scheduled task,
  # geen admin/UAC. Installeert naar %LocalAppData%\bvg en zet de code-sign-keten
  # in de CurrentUser-stores. Starten doe je zelf met `bvg.exe daemon`.
  [switch]$Portable
)

$ErrorActionPreference = "Stop"

# Portable kan ook via env (zodat de iwr|iex-oneliner werkt: $env:BVG_PORTABLE=1).
if ($env:BVG_PORTABLE -eq "1" -or $env:BVG_PORTABLE -eq "true") { $Portable = $true }
if ($Portable -and -not $PSBoundParameters.ContainsKey('InstallDir')) {
  $InstallDir = Join-Path $env:LOCALAPPDATA "bvg"
}
# Code-sign-keten: machine-stores vereisen admin; user-level gaat naar CurrentUser.
$CertStoreLocation = if ($Portable) { "CurrentUser" } else { "LocalMachine" }
# Native commands (bvg.exe join, taskkill, sc.exe) schrijven soms naar stderr
# zonder dat het een fout is (bv. "falling back to azure..."). In PS 7.3+ maakt
# $PSNativeCommandUseErrorActionPreference dat onder Stop tot een terminating
# error -> de install zou stoppen vóór de exit-code-check. Uitzetten; we checken
# overal expliciet $LASTEXITCODE. (Bestaat niet in 5.1; setten is daar no-op.)
$PSNativeCommandUseErrorActionPreference = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 0x3000

if (-not $InstallUrl) {
  $InstallUrl = "https://github.com/$Repo/releases/latest/download/install.ps1"
}

function Say($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Done($msg) { Write-Host $msg -ForegroundColor Green }
function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

function Assert-BvgExeSignature {
  param([string]$Path, [bool]$Required)

  # Private Trust chained naar een GEDEELDE Microsoft-root. Een geldige keten
  # bewijst dus alleen "ondertekend door een Azure Private-Trust-klant". Pin
  # daarom op de signer-CN zodat alleen ONZE binary wordt geaccepteerd.
  $expectedCN = "bvgeert.nl"

  $signature = Get-AuthenticodeSignature -FilePath $Path
  if ($signature.Status -eq "Valid") {
    $subject = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { "" }
    if ($subject -notmatch "CN=$([regex]::Escape($expectedCN))(,|$)") {
      $msg = "bvg.exe is geldig ondertekend maar door een onverwachte uitgever: '$subject' (verwacht CN=$expectedCN)"
      if ($Required) { Fail "$msg. Refusing to install." }
      Say "WARN: $msg"
      return
    }
    Done "bvg.exe Authenticode signature is valid: $subject"
    return
  }

  $message = "bvg.exe Authenticode signature is $($signature.Status)"
  if ($Required) {
    Fail "$message. Refusing to install a release that requires signed binaries."
  }
  Say "WARN: $message - accepting unsigned legacy release"
}

function Install-CodeSignChain {
  # Private Trust: de bvg signing-CA-keten zit niet in het Windows root program
  # EN wordt op restricted/offline machines niet via AIA opgehaald. De binary is
  # leaf-only getekend (Azure Trusted Signing), dus zonder de intermediates kan
  # WinVerifyTrust de keten niet bouwen — fataal voor de host die als LocalSystem
  # draait (geen user-cache, geen netwerk). Daarom levert de release de HELE keten
  # mee (bvg-codesign-chain.p7b: root + intermediates). Self-signed certs -> de
  # LocalMachine\Root store, intermediates -> LocalMachine\CA. Idempotent op
  # thumbprint. Valt terug op de losse root (bvg-codesign-root.cer) voor oude zips.
  param([string]$Dir, [string]$StoreLocation = "LocalMachine")

  $certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
  $p7b = Join-Path $Dir "bvg-codesign-chain.p7b"
  $rootCer = Join-Path $Dir "bvg-codesign-root.cer"
  try {
    if (Test-Path $p7b)          { $certs.Import($p7b) }
    elseif (Test-Path $rootCer)  { $certs.Import($rootCer) }
    else                         { return }
  } catch {
    Say "WARN: kon code-signing keten niet inlezen: $($_.Exception.Message)"
    return
  }

  foreach ($cert in $certs) {
    $storeName = if ($cert.Subject -eq $cert.Issuer) { "Root" } else { "CA" }
    try {
      $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, $StoreLocation)
      $store.Open("ReadWrite")
      if (($store.Certificates.Find("FindByThumbprint", $cert.Thumbprint, $false)).Count -eq 0) {
        $store.Add($cert)
        Done "installed code-signing cert in ${storeName}: $($cert.Subject) [$($cert.Thumbprint)]"
      } else {
        Say "code-signing cert al aanwezig in ${storeName} [$($cert.Thumbprint)]"
      }
      $store.Close()
    } catch {
      Say "WARN: kon code-signing cert niet in ${storeName} plaatsen: $($_.Exception.Message)"
    }
  }
}

# --- 1. Self-elevate via UAC ---------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if ($Portable) {
  Say "portable (service-loze, user-level) install in $InstallDir - geen admin/UAC nodig"
} elseif (-not $IsAdmin) {
  Say "elevation required - relaunching with UAC prompt..."
  # Forward the env-vars the elevated session needs.
  $envFwd = @(
    "BVG_JOIN_TOKEN", "BVG_BVGEERT_HOST", "BVG_TRANSPORT", "BVG_AZURE_HUB"
  ) | ForEach-Object {
    $v = [Environment]::GetEnvironmentVariable($_)
    if ($v) { "`$env:$_ = '$($v -replace ""'"", ""''"")';" }
  }

  $safeInstallUrl = $InstallUrl -replace "'", "''"
  $scriptText = ($envFwd -join " ") + " " + `
    "iwr '$safeInstallUrl' -UseBasicParsing | iex"
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($scriptText))
  $pwsh = if (Get-Command pwsh.exe -ErrorAction SilentlyContinue) { "pwsh.exe" } else { "powershell.exe" }
  Start-Process -FilePath $pwsh `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-EncodedCommand", $encoded) `
    -Verb RunAs -Wait
  exit
}

# --- 2. Pre-flight checks ------------------------------------------------
# Soft fails (warnings) for the non-fatal checks, hard fails for things that
# absolutely won't work. Keeps `iwr ... | iex` debuggable on weird machines.

$WinVer = [Environment]::OSVersion.Version
if ($WinVer.Major -lt 10) {
  Fail "Windows 10 or newer is required (detected: $($WinVer.ToString()))"
}

# Disk space — 200 MB needed (77MB exe + 77MB rollback + headroom).
# Get-Item zonder -LiteralPath/-Force faalt op Win11 26200 voor
# C:\ProgramData ("Could not find item") — directory-junction quirk.
# DriveInfo omzeilt het pad-provider-gedoe helemaal.
$drive = [System.IO.DriveInfo]::new((Split-Path $env:ProgramData -Qualifier))
if ($drive.AvailableFreeSpace -lt 200MB) {
  Fail "less than 200 MB free on drive $($drive.Name) - install needs ~150 MB"
}

# Reachability of GitHub release host. Don't block on this (corp proxy can be weird)
# but warn the operator early.
function Test-Reachable {
  param([string]$Host_, [int]$Port = 443, [int]$TimeoutMs = 3000)
  try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $iar = $tcp.BeginConnect($Host_, $Port, $null, $null)
    $ok = $iar.AsyncWaitHandle.WaitOne($TimeoutMs)
    if ($ok -and $tcp.Connected) { $tcp.EndConnect($iar); $tcp.Close(); return $true }
    $tcp.Close(); return $false
  } catch { return $false }
}
if (-not (Test-Reachable "github.com")) {
  Say "WARN: github.com:443 not reachable from this machine - download likely to fail"
}

# --- 3. Resolve required env-vars ----------------------------------------
$JoinToken   = $env:BVG_JOIN_TOKEN
$BvgeertHost = $env:BVG_BVGEERT_HOST
$Transport   = $env:BVG_TRANSPORT
$AzureHub    = $env:BVG_AZURE_HUB
$Domain      = $env:BVG_DOMAIN

# Token is OPTIONEEL (#369, verfijnd #371): zonder token doen we een anonieme
# install — binary + install.env, GEEN pair. We slaan de service NIET meer over
# (was Spec 1): de service-install draait nu ook in het token-loze pad, zodat de
# host als pre-enroll daemon start en de DLL anoniem vers houdt via het
# PublicUpdateChannel (Spec 2). De gebruiker enrollt later met
# `bvg.exe enroll --token <jt>` → bij de volgende start draait hij de normale,
# geauthenticeerde modus. Met token blijft alles ongewijzigd. `-Portable` blijft
# service-loos (start zelf `bvg.exe daemon`).
$Anonymous = (-not $JoinToken)
if (-not $BvgeertHost -and -not $AzureHub) {
  Fail "BVG_BVGEERT_HOST is required (direct mode) or BVG_AZURE_HUB (azure mode)."
}

# --- 3. Download release asset -------------------------------------------
$null = New-Item -ItemType Directory -Force -Path $InstallDir
$ZipUrl  = "https://github.com/$Repo/releases/latest/download/bvg-windows-x64.zip"
$ShaUrl  = "https://github.com/$Repo/releases/latest/download/bvg-windows-x64.zip.sha256"
$ZipPath = Join-Path $env:TEMP "bvg-windows-x64.zip"
$ShaPath = Join-Path $env:TEMP "bvg-windows-x64.zip.sha256"
$ExePath = Join-Path $InstallDir "bvg.exe"

Say "downloading $ZipUrl..."
try {
  Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
  Invoke-WebRequest -Uri $ShaUrl -OutFile $ShaPath -UseBasicParsing
} catch {
  Fail "download failed: $($_.Exception.Message)"
}

$expectedHash = ((Get-Content -Path $ShaPath -Raw) -split '\s+')[0].ToLower()
$localHash = (Get-FileHash -Path $ZipPath -Algorithm SHA256).Hash.ToLower()
if (-not $expectedHash -or $localHash -ne $expectedHash) {
  Fail "sha256 mismatch for bvg-windows-x64.zip (downloaded=$localHash expected=$expectedHash)"
}
Remove-Item $ShaPath -Force -ErrorAction SilentlyContinue

# Stop EN kill een eventueel draaiende host voordat we uitpakken. De host kan
# na een eerdere mislukte start "blijven draaien" en bvg.exe + de geladen
# bvg.Client.dll vergrendelen; dan pakt Expand-Archive maar half uit (versions\
# leeg, geen state) en faalt de install stil. Stop-Service alleen is niet genoeg
# (een vastgelopen host reageert niet op de stop), dus killen we het proces hard.
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
# Portable raakt de bestaande Windows-service NOOIT aan (andere install-dir;
# de service lockt de portable-dir niet). We killen alleen een eventueel eerder
# portable-proces uit DEZE $ExePath.
if (-not $Portable -and $existing -and $existing.Status -eq "Running") {
  Say "stopping existing service..."
  Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
}
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
  Where-Object { $_.ExecutablePath -eq $ExePath -or (-not $Portable -and $_.Name -eq "bvg.exe") } |
  ForEach-Object { Say "killing lingering bvg host (PID $($_.ProcessId))..."; Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# Vangnet (kill ook child-processen) — image-wide, dus ALLEEN niet-portable.
# Volledig binnen cmd zodat taskkill's "not found"-stderr op een schone machine
# GEEN terminating NativeCommandError wordt onder $ErrorActionPreference='Stop'.
if (-not $Portable) {
  cmd.exe /c "taskkill /F /IM bvg.exe /T >nul 2>&1 & exit 0"
}
Start-Sleep -Seconds 2

Say "extracting to $InstallDir..."
Remove-Item (Join-Path $InstallDir "signature-required.txt") -Force -ErrorAction SilentlyContinue
Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $ExePath)) { Fail "bvg.exe not found after extract" }
# Eerst de private signing-root vertrouwen, dan pas de keten valideren -
# anders geeft Get-AuthenticodeSignature 'UnknownError' op een schone machine.
Install-CodeSignChain -Dir $InstallDir -StoreLocation $CertStoreLocation
$SignatureRequired = Test-Path (Join-Path $InstallDir "signature-required.txt")
Assert-BvgExeSignature -Path $ExePath -Required $SignatureRequired

# --- 3b. EXE/DLL-split: verifieer de initiele client-DLL en zet state op ---
# De zip bevat versions\<v>\bvg.Client.dll. De host laadt die bij start; we
# verifieren 'm hier (zelfde Valid + CN=bvgeert.nl poort als de exe) en schrijven
# state\current.json zodat active = last_known_good = deze versie.
$verRoot = Join-Path $InstallDir "versions"
$verDir  = Get-ChildItem $verRoot -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
if (-not $verDir) { Fail "versions\ ontbreekt na extract - oude/ongeldige release-zip?" }
$ClientDll = Join-Path $verDir.FullName "bvg.Client.dll"
if (-not (Test-Path $ClientDll)) { Fail "bvg.Client.dll niet gevonden in $($verDir.FullName)" }
Assert-BvgExeSignature -Path $ClientDll -Required $SignatureRequired
$StateDir = Join-Path $InstallDir "state"
$null = New-Item -ItemType Directory -Force -Path $StateDir
@{ active = $verDir.Name; last_known_good = $verDir.Name; fail_counts = @{} } |
  ConvertTo-Json | Set-Content (Join-Path $StateDir "current.json") -Encoding UTF8
Done "client $($verDir.Name) geinstalleerd + state geschreven"

# --- install.env: bewaar host/route zodat `bvg enroll` ze later kan lezen ----
# Altijd schrijven (ook bij anonieme install) onder $InstallDir, zodat een latere
# `bvg.exe enroll --token <jt>` alleen het token nodig heeft (#369).
$InstallEnvPath = Join-Path $InstallDir "install.env"
$envLines = @()
if ($Domain)      { $envLines += "BVG_DOMAIN=$Domain" }
if ($BvgeertHost) { $envLines += "BVG_BVGEERT_HOST=$BvgeertHost" }
if ($AzureHub)    { $envLines += "BVG_AZURE_HUB=$AzureHub" }
if ($Transport)   { $envLines += "BVG_TRANSPORT=$Transport" }
Set-Content -Path $InstallEnvPath -Value $envLines -Encoding ASCII
Done "host/route bewaard in $InstallEnvPath"

# --- Anonieme install (geen token): GEEN pair, maar WEL de service ----------
# Spec 2 (#371): de token-loze install registreert + start de service alsnog,
# zodat de host als pre-enroll daemon draait (detecteert "niet geënrolld" →
# anoniem PublicUpdateChannel → DLL vers houden). De pairing-stap (sectie 4)
# wordt overgeslagen; al het overige (service-registratie, self-update-task)
# loopt identiek aan de getokende install. `-Portable` blijft service-loos.
if ($Anonymous) {
  Done "geen token → anonieme install; host start als pre-enroll daemon (DLL vers via PublicUpdateChannel)"
  Write-Host "enroll later met: & '$ExePath' enroll --token <jt_...>   (host/route uit install.env)"
}

# --- 4. One-time pair (redeem join-token) --------------------------------
$CredentialsPath = Join-Path $InstallDir "credentials.json"
$env:BVG_CREDENTIALS = $CredentialsPath
# Portable: de host leest BVG_INSTALL_DIR voor versions\/state\; zet 'm nu in de
# sessie (zodat een in-install host-aanroep klopt) en straks persistent via setx.
if ($Portable) { $env:BVG_INSTALL_DIR = $InstallDir }

if (-not $Anonymous) {

# Een vorige install zet credentials.json read-only voor Administrators
# (alleen SYSTEM krijgt Full). Bij re-install kan `bvg join` 'em
# dan niet overschrijven → 'Access to the path … is denied'. Admins
# mogen via directory-ACL wel verwijderen — los de stale file dus eerst op.
if (Test-Path -LiteralPath $CredentialsPath) {
  Remove-Item -LiteralPath $CredentialsPath -Force -ErrorAction SilentlyContinue
}

Say "pairing with bvgeert..."

# Try direct route first if BVG_BVGEERT_HOST is set. If direct fails AND BVG_AZURE_HUB
# is also set, fall back to the azure route — this covers restricted networks that
# can't reach bvgeert on 443 directly but do allow wss://*.webpubsub.azure.com:443.
$paired = $false

if ($BvgeertHost) {
  Say "  trying direct route via $BvgeertHost..."
  $directArgs = @("join", "--host", $BvgeertHost, "--token", $JoinToken)
  if ($Transport) { $directArgs += @("--transport", $Transport) }
  # bvg.exe via Start-Process: een non-zero exit (directe route faalt vaak en
  # valt terug op azure) of stderr mag NOOIT een terminating error worden.
  # Onder $ErrorActionPreference='Stop' doet `& bvg.exe` dat wel zodra
  # $PSNativeCommandUseErrorActionPreference $true is (default in sommige PS7;
  # via iex niet betrouwbaar uit te zetten). Start-Process omzeilt dat volledig.
  $ec = (Start-Process -FilePath $ExePath -ArgumentList $directArgs -Wait -NoNewWindow -PassThru).ExitCode
  if ($ec -eq 0) {
    $paired = $true
    Done "  paired via direct route"
  } elseif ($AzureHub) {
    Say "  direct route failed (exit $ec) - falling back to azure route"
  } else {
    Fail "direct route failed (exit $ec) and no BVG_AZURE_HUB to fall back on"
  }
}

if (-not $paired -and $AzureHub) {
  if (-not $Transport) { Fail "BVG_TRANSPORT is required for azure route" }
  Say "  trying azure route via $AzureHub..."
  $azureArgs = @("join", "--hub", $AzureHub, "--transport", $Transport, "--token", $JoinToken)
  $ec = (Start-Process -FilePath $ExePath -ArgumentList $azureArgs -Wait -NoNewWindow -PassThru).ExitCode
  if ($ec -eq 0) {
    $paired = $true
    Done "  paired via azure route"
  } else {
    Fail "azure route failed (exit $ec)"
  }
}

if (-not $paired) { Fail "pairing failed - no route succeeded" }

# Defensive lock-down: bvg.exe already restricts the ACL on save, but
# enforce the spec ("SYSTEM + Administrators read only") explicitly here too.
# Portable (user-level) slaat dit over: de creds zijn dan user-privé in
# %LocalAppData% en een SYSTEM/Administrators-only ACL zou de gebruiker zelf
# buitensluiten.
if (-not $Portable -and (Test-Path $CredentialsPath)) {
  & icacls.exe $CredentialsPath /inheritance:r `
    /grant:r "SYSTEM:(F)" `
    /grant:r "Administrators:(R)" | Out-Null
}

} # einde getokende pairing (overgeslagen bij anonieme install)

# --- 5+6. Windows-service + dagelijkse self-update (overgeslagen in portable) ---
# Draait OOK in het anonieme pad (#371): de service start de host als
# pre-enroll daemon. Alleen -Portable blijft service-loos.
if (-not $Portable) {

if ($existing) {
  Say "removing previous service registration..."
  & sc.exe delete $ServiceName | Out-Null
  Start-Sleep -Seconds 1
}

Say "registering service '$ServiceName'..."
& sc.exe create $ServiceName binPath= "`"$ExePath`"" start= auto DisplayName= "BvGeert transport daemon" obj= "LocalSystem" | Out-Null
if ($LASTEXITCODE -ne 0) { Fail "sc.exe create failed (exit $LASTEXITCODE)" }

# Restart-on-failure: 3 retries, 10s apart, reset counter after 1h.
& sc.exe failure $ServiceName reset= 3600 actions= restart/10000/restart/10000/restart/10000 | Out-Null

# Persist BVG_CREDENTIALS as a per-service env-var so the LocalSystem
# context reads from %ProgramData% instead of LOCALAPPDATA. Bij een anonieme
# install bestaat credentials.json nog niet; het pad wijst alvast naar de
# plek waar `bvg enroll` 'm straks schrijft. Bij een niet-default install-dir
# zetten we ook BVG_INSTALL_DIR zodat de host install.env/versions/state vindt
# (de pre-enroll daemon leest host/route uit install.env).
$envKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$existingEnv = @()
try { $existingEnv = (Get-ItemProperty -Path $envKey -Name Environment -ErrorAction Stop).Environment } catch { }
$mergedEnv = @($existingEnv | Where-Object { $_ -notlike "BVG_CREDENTIALS=*" -and $_ -notlike "BVG_INSTALL_DIR=*" }) + "BVG_CREDENTIALS=$CredentialsPath"
if ($InstallDir -ne (Join-Path $env:ProgramData "bvg")) {
  $mergedEnv += "BVG_INSTALL_DIR=$InstallDir"
}
New-ItemProperty -Path $envKey -Name Environment -PropertyType MultiString -Value $mergedEnv -Force | Out-Null

Say "starting service..."
& sc.exe start $ServiceName | Out-Null
# Geef de host tijd om de DLL te verifieren, laden en verbinden (tot ~20s).
$svc = $null
for ($i = 0; $i -lt 10; $i++) {
  Start-Sleep -Seconds 2
  $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -eq "Running") { break }
}
if ($svc -and $svc.Status -eq "Running") {
  Done "service '$ServiceName' is running"
} else {
  # Toon de reden meteen in deze console i.p.v. een vage 'check logs'.
  Say "service bereikte 'Running' niet (status: $($svc.Status)). Laatste loglijnen:"
  $log = Get-ChildItem (Join-Path $InstallDir "logs\bvg-*.log") -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
  if ($log) { Get-Content $log.FullName -Tail 15 | ForEach-Object { Say "  $_" } }
  Fail "service did not reach Running state - zie bovenstaande log en $InstallDir\logs\"
}

# --- 6. Schedule daily self-update ---------------------------------------
# The release zip includes scripts/bvg-update.ps1. It's copied into
# $InstallDir during extraction. We schedule it to run once a day at a random
# minute (avoids all clients hammering the GitHub API at the same second).
$UpdaterScript = Join-Path $InstallDir "bvg-update.ps1"
$UpdateTaskName = "$ServiceName-update"
if (Test-Path $UpdaterScript) {
  Say "scheduling daily self-update task '$UpdateTaskName'..."
  $randomMinute = Get-Random -Minimum 0 -Maximum 60
  $randomHour = Get-Random -Minimum 3 -Maximum 5   # 3-4am LOCAL, low-traffic window
  $trigger = New-ScheduledTaskTrigger -Daily -At ([datetime]::Today.AddHours($randomHour).AddMinutes($randomMinute))
  $action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$UpdaterScript`""
  $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest
  $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
  Register-ScheduledTask -TaskName $UpdateTaskName -Trigger $trigger -Action $action -Principal $principal -Settings $settings -Force | Out-Null
  Done "self-update task registered (daily at ${randomHour}:$('{0:00}' -f $randomMinute))"
} else {
  Say "WARN: $UpdaterScript not found - skipping self-update scheduler (older release zip?)"
}

} # einde niet-portable (service + self-update)

# Persist version stamp so the updater knows what's installed.
if (Test-Path (Join-Path $InstallDir "version.txt")) {
  # Already in the zip — keep what the release stamped.
} else {
  # Fallback: ask the exe.
  try { (& $ExePath --version).Trim() | Set-Content -Path (Join-Path $InstallDir "version.txt") -NoNewline -Encoding ASCII } catch { }
}

Done "installation complete"
Write-Host ""
Write-Host "logs:         $InstallDir\logs\bvg-*.log"
Write-Host "credentials:  $CredentialsPath"
if ($Anonymous) {
  Write-Host "mode:         pre-enroll (niet geënrolld) — DLL vers via PublicUpdateChannel"
  Write-Host "enroll:       & '$ExePath' enroll --token <jt_...>   (host/route uit install.env)"
}
if ($Portable) {
  # Persisteer de paden als user-env zodat `bvg.exe daemon` ze in een nieuwe
  # console vindt. BVG_INSTALL_DIR is vereist (default is %ProgramData%).
  & setx BVG_INSTALL_DIR "$InstallDir" | Out-Null
  & setx BVG_CREDENTIALS "$CredentialsPath" | Out-Null
  Write-Host ""
  Write-Host "PORTABLE install (geen Windows-service). zelf starten:"
  Write-Host "  `$env:BVG_INSTALL_DIR = '$InstallDir'"
  Write-Host "  & '$ExePath' daemon"
  Write-Host "(BVG_INSTALL_DIR + BVG_CREDENTIALS zijn als user-env gezet voor nieuwe consoles)"
  Write-Host "re-pair:      & '$ExePath' join --host <host> --token <jt_...>"
  Write-Host "update:       her-run install.ps1 -Portable (of draai bvg-update.ps1 handmatig)"
} else {
  Write-Host "service:      sc.exe query $ServiceName"
  Write-Host "update task:  Get-ScheduledTask -TaskName $UpdateTaskName"
  Write-Host "update log:   $InstallDir\logs\updater.log"
  Write-Host "force update: Start-ScheduledTask -TaskName $UpdateTaskName"
  Write-Host "opt-out:      Disable-ScheduledTask -TaskName $UpdateTaskName"
  Write-Host "re-pair:      `$env:BVG_CREDENTIALS = '$CredentialsPath'; & '$ExePath' join --host <host> --token <jt_...>; Restart-Service $ServiceName"
}
