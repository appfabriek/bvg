#requires -Version 5.1
<#
.SYNOPSIS
  bvg installer for Windows (Dart wire-client).

  Downloads the self-contained bvg.exe Dart binary from the latest release,
  optionally enrolls it against the bvgeert transport over Azure using a
  one-time join-token, and installs a Windows service that runs `bvg launch`
  (which applies any pending self-update then runs the daemon). Without a join
  token the client installs in anonymous (pre-enroll) mode and can be enrolled
  later.

.DESCRIPTION
  One-liner install (the bvg1 proxy snippet / bvgeert admin UI generates this):

    $env:BVG_JOIN_TOKEN         = "jt_..."
    $env:BVG_ANON_BOOTSTRAP_URL = "https://bvg1.example/anon"
    $env:BVG_TRANSPORT          = "my-connection"
    iwr https://github.com/appfabriek/bvg/releases/latest/download/install.ps1 -UseBasicParsing | iex

  The script self-elevates via UAC, downloads bvg-windows-x64.exe, enrolls
  with the join-token (if one is given), persists BVG_CREDENTIALS as a machine
  env var, and registers a Windows service via WinSW.

  Required env vars:
    BVG_ANON_BOOTSTRAP_URL  bvg1 anon-access endpoint (anonymous Azure URLs)
    BVG_TRANSPORT           transport / connection identifier

  Optional env vars:
    BVG_JOIN_TOKEN          one-time join token (jt_...); if set, enroll now,
                            otherwise install in anonymous (pre-enroll) mode
    BVG_NO_SERVICE          1/true => download (+ enroll if token) but do not
                            install or start the service; print the manual
                            run-command instead (also via -NoService switch)
    BVG_INSTALL_DIR         install dir (default: $env:ProgramData\bvg)
    BVG_INSTALL_BASE_URL    release asset base URL
    BVG_CREDENTIALS         credentials path (default: <install-dir>\credentials.json)
#>

[CmdletBinding()]
param(
  [string]$ServiceName = "bvg",
  [switch]$NoService
)

$ErrorActionPreference = "Stop"
# Native commands (bvg.exe, WinSW) may write to stderr without it being a
# fatal error. In PS 7.3+ $PSNativeCommandUseErrorActionPreference turns that
# into a terminating error under Stop; we check $LASTEXITCODE explicitly, so
# disable it. (No-op on 5.1.)
$PSNativeCommandUseErrorActionPreference = $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 0x3000

function Say($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Done($msg) { Write-Host $msg -ForegroundColor Green }
function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

# Private Trust: install the bundled signing-CA chain into the machine stores
# (root -> LocalMachine\Root, intermediates -> LocalMachine\CA) so Windows can
# validate the leaf-only Authenticode signature, also offline / as SYSTEM.
# Idempotent on thumbprint. Prefers the chain bundle; falls back to the root.
function Install-CodeSignChain($Dir) {
  $certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
  $p7b = Join-Path $Dir "bvg-codesign-chain.p7b"
  $rootCer = Join-Path $Dir "bvg-codesign-root.cer"
  try {
    if (Test-Path $p7b)         { $certs.Import($p7b) }
    elseif (Test-Path $rootCer) { $certs.Import($rootCer) }
    else                        { return }
  } catch { Say "WARN: could not read code-signing chain: $($_.Exception.Message)"; return }

  foreach ($cert in $certs) {
    $storeName = if ($cert.Subject -eq $cert.Issuer) { "Root" } else { "CA" }
    try {
      $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, "LocalMachine")
      $store.Open("ReadWrite")
      if (($store.Certificates.Find("FindByThumbprint", $cert.Thumbprint, $false)).Count -eq 0) {
        $store.Add($cert)
        Done "trusted code-signing cert in ${storeName}: $($cert.Subject)"
      }
      $store.Close()
    } catch { Say "WARN: could not install code-signing cert in ${storeName}: $($_.Exception.Message)" }
  }
}

# Verify bvg.exe is Authenticode-signed by CN=bvgeert.nl. When a
# signature-required.txt marker is present we REFUSE an unsigned / invalid /
# wrong-signer binary (fail-closed); otherwise we only warn (legacy/unsigned).
function Assert-BvgExeSignature($Path, [bool]$Required) {
  $expectedCN = "bvgeert.nl"
  $sig = Get-AuthenticodeSignature -FilePath $Path
  if ($sig.Status -eq "Valid") {
    $subject = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "" }
    if ($subject -notmatch "CN=$([regex]::Escape($expectedCN))(,|$)") {
      if ($Required) { Fail "bvg.exe signed by unexpected issuer '$subject' (expected CN=$expectedCN) - refusing to install" }
      Say "WARN: bvg.exe signed by unexpected issuer '$subject'"
      return
    }
    Done "bvg.exe signature valid: $subject"
    return
  }
  if ($Required) {
    Fail "bvg.exe Authenticode signature is $($sig.Status) - refusing to install an unsigned/invalid binary (signature-required.txt present)"
  }
  Say "WARN: bvg.exe Authenticode signature is $($sig.Status) - continuing (no signature-required.txt marker)"
}

$BaseUrl = if ($env:BVG_INSTALL_BASE_URL) { $env:BVG_INSTALL_BASE_URL } `
           else { "https://github.com/appfabriek/bvg/releases/latest/download" }
$WinSwUrl = "https://github.com/winsw/winsw/releases/download/v2.12.0/WinSW.NET4.exe"

# --- 1. Resolve + require config env-vars --------------------------------
# BVG_JOIN_TOKEN is OPTIONAL (tokenless = anonymous pre-enroll mode). The
# anonymous daemon still needs the bootstrap url + transport, so those stay
# required.
$JoinToken    = $env:BVG_JOIN_TOKEN
$BootstrapUrl = $env:BVG_ANON_BOOTSTRAP_URL
$Transport    = $env:BVG_TRANSPORT

# Resolve no-service mode: -NoService switch or BVG_NO_SERVICE env var.
$NoServiceMode = [bool]$NoService
if (-not $NoServiceMode -and $env:BVG_NO_SERVICE) {
  $NoServiceMode = @("1", "true", "yes") -contains $env:BVG_NO_SERVICE.ToLower()
}
# Mirror the switch into the env var so it survives UAC self-elevation (the
# elevated session is launched via `iwr | iex`, which cannot receive -NoService).
if ($NoServiceMode) { $env:BVG_NO_SERVICE = "1" }

$missing = @()
if (-not $BootstrapUrl) { $missing += "BVG_ANON_BOOTSTRAP_URL" }
if (-not $Transport)    { $missing += "BVG_TRANSPORT" }
if ($missing.Count -gt 0) {
  Fail "missing required env var(s): $($missing -join ', '). Set them and re-run."
}

# --- 2. Self-elevate via UAC ---------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
  Say "elevation required - relaunching with UAC prompt..."
  $InstallUrl = if ($env:BVG_INSTALL_BASE_URL) { "$BaseUrl/install.ps1" } `
                else { "https://github.com/appfabriek/bvg/releases/latest/download/install.ps1" }
  # Forward the env-vars the elevated session needs.
  $envFwd = @(
    "BVG_JOIN_TOKEN", "BVG_ANON_BOOTSTRAP_URL", "BVG_TRANSPORT",
    "BVG_NO_SERVICE", "BVG_INSTALL_DIR",
    "BVG_INSTALL_BASE_URL", "BVG_CREDENTIALS"
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

# --- 3. Pre-flight -------------------------------------------------------
$WinVer = [Environment]::OSVersion.Version
if ($WinVer.Major -lt 10) {
  Fail "Windows 10 or newer is required (detected: $($WinVer.ToString()))"
}

$InstallDir = if ($env:BVG_INSTALL_DIR) { $env:BVG_INSTALL_DIR } `
              else { Join-Path $env:ProgramData "bvg" }
$null = New-Item -ItemType Directory -Force -Path $InstallDir
$ExePath = Join-Path $InstallDir "bvg.exe"
$CredentialsPath = if ($env:BVG_CREDENTIALS) { $env:BVG_CREDENTIALS } `
                   else { Join-Path $InstallDir "credentials.json" }

# --- 4. Download the binary ----------------------------------------------
$AssetUrl = "$BaseUrl/bvg-windows-x64.exe"
Say "downloading $AssetUrl to $ExePath..."

# Stop a running service so the exe is not locked during overwrite.
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing -and $existing.Status -eq "Running") {
  Say "stopping existing service '$ServiceName'..."
  Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
if ($curl) {
  & curl.exe -fsSL -o $ExePath $AssetUrl
  if ($LASTEXITCODE -ne 0) { Fail "download failed (curl exit $LASTEXITCODE)" }
} else {
  try {
    Invoke-WebRequest -Uri $AssetUrl -OutFile $ExePath -UseBasicParsing
  } catch {
    Fail "download failed: $($_.Exception.Message)"
  }
}
if (-not (Test-Path $ExePath)) { Fail "bvg.exe not found after download" }
Done "bvg.exe installed to $ExePath"

# --- 4a. Trust the signing chain + verify the binary --------------------
# Fetch the Private-Trust signing chain + the signature-required.txt marker,
# trust the chain, then verify bvg.exe. With the marker present an invalid
# signature is fatal (fail-closed); without it (older release) we only warn.
$ChainPath  = Join-Path $InstallDir "bvg-codesign-chain.p7b"
$RootCer    = Join-Path $InstallDir "bvg-codesign-root.cer"
$MarkerPath = Join-Path $InstallDir "signature-required.txt"
foreach ($pair in @(
    @("bvg-codesign-chain.p7b", $ChainPath),
    @("bvg-codesign-root.cer",  $RootCer),
    @("signature-required.txt", $MarkerPath))) {
  try {
    if ($curl) { & curl.exe -fsSL -o $pair[1] "$BaseUrl/$($pair[0])" 2>$null }
    else       { Invoke-WebRequest -Uri "$BaseUrl/$($pair[0])" -OutFile $pair[1] -UseBasicParsing }
  } catch { }
}
Install-CodeSignChain $InstallDir
Assert-BvgExeSignature $ExePath ([bool](Test-Path $MarkerPath))

# Put bvg.exe on PATH (Machine) so `bvg ...` works from any shell. We are
# elevated here, so the Machine scope is writable.
$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if (($machinePath -split ';') -notcontains $InstallDir) {
  [Environment]::SetEnvironmentVariable("PATH", ("$machinePath;$InstallDir").TrimStart(';'), "Machine")
  Done "added $InstallDir to Machine PATH (open a new shell to pick it up)"
}

# --- 5. Enroll (one-time, redeem the join token) -- or skip (anonymous) --
$env:BVG_CREDENTIALS = $CredentialsPath

if ($JoinToken) {
  if (Test-Path -LiteralPath $CredentialsPath) {
    Remove-Item -LiteralPath $CredentialsPath -Force -ErrorAction SilentlyContinue
  }
  Say "enrolling with bvgeert (transport=$Transport)..."
  $enrollArgs = @(
    "enroll",
    "--token", $JoinToken,
    "--bootstrap", $BootstrapUrl,
    "--transport", $Transport,
    "--hostname", $env:COMPUTERNAME
  )
  $ec = (Start-Process -FilePath $ExePath -ArgumentList $enrollArgs -Wait -NoNewWindow -PassThru).ExitCode
  if ($ec -ne 0) { Fail "enroll failed (exit $ec)" }
  Done "enrolled; credentials at $CredentialsPath"
} else {
  Say "no token -> installing in anonymous (pre-enroll) mode; enroll later with: bvg enroll --token <jt> --bootstrap $BootstrapUrl --transport $Transport --hostname $env:COMPUTERNAME"
}

# --- 5b. No-service mode: stop before touching any service ---------------
# The daemon auto-selects: enrolled creds -> full agent; not enrolled ->
# anonymous pre-enroll daemon. Run it manually with the env vars below.
if ($NoServiceMode) {
  Done "download complete; service NOT installed (BVG_NO_SERVICE)"
  Write-Host ""
  Write-Host "run the daemon manually with:"
  Write-Host "  `$env:BVG_CREDENTIALS=`"$CredentialsPath`"; `$env:BVG_ANON_BOOTSTRAP_URL=`"$BootstrapUrl`"; `$env:BVG_TRANSPORT=`"$Transport`"; & `"$ExePath`" daemon"
  Write-Host ""
  Write-Host "binary:       $ExePath"
  Write-Host "credentials:  $CredentialsPath"
  Write-Host "transport:    $Transport"
  exit 0
}

# --- 6. Register a Windows service via WinSW -----------------------------
$WinSwExe = Join-Path $InstallDir "bvg-svc.exe"
$WinSwXml = Join-Path $InstallDir "bvg-svc.xml"

Say "downloading WinSW service wrapper..."
if ($curl) {
  & curl.exe -fsSL -o $WinSwExe $WinSwUrl
  if ($LASTEXITCODE -ne 0) { Fail "WinSW download failed (curl exit $LASTEXITCODE)" }
} else {
  try {
    Invoke-WebRequest -Uri $WinSwUrl -OutFile $WinSwExe -UseBasicParsing
  } catch {
    Fail "WinSW download failed: $($_.Exception.Message)"
  }
}
if (-not (Test-Path $WinSwExe)) { Fail "WinSW.NET4.exe not found after download" }

$xml = @"
<service>
  <id>$ServiceName</id>
  <name>BvGeert transport daemon</name>
  <description>BvGeert transport client (bvg daemon)</description>
  <executable>$ExePath</executable>
  <arguments>launch</arguments>
  <startmode>Automatic</startmode>
  <onfailure action="restart" delay="5 sec"/>
  <log mode="roll"/>
  <env name="BVG_CREDENTIALS" value="$CredentialsPath"/>
  <env name="BVG_ANON_BOOTSTRAP_URL" value="$BootstrapUrl"/>
  <env name="BVG_TRANSPORT" value="$Transport"/>
</service>
"@
Set-Content -Path $WinSwXml -Value $xml -Encoding ASCII

# Tear down a previous registration so install is idempotent.
if ($existing) {
  Say "removing previous service registration..."
  & $WinSwExe uninstall | Out-Null
  & sc.exe delete $ServiceName 2>$null | Out-Null
  Start-Sleep -Seconds 1
}

Say "registering service '$ServiceName'..."
& $WinSwExe install
if ($LASTEXITCODE -ne 0) { Fail "WinSW install failed (exit $LASTEXITCODE)" }

# Persist BVG_CREDENTIALS as a machine env var so any context resolves it.
[Environment]::SetEnvironmentVariable("BVG_CREDENTIALS", $CredentialsPath, "Machine")

Say "starting service..."
& $WinSwExe start | Out-Null
$svc = $null
for ($i = 0; $i -lt 10; $i++) {
  Start-Sleep -Seconds 2
  $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -eq "Running") { break }
}
if ($svc -and $svc.Status -eq "Running") {
  Done "service '$ServiceName' is running"
} else {
  Say "service did not reach Running (status: $($svc.Status))."
  $log = Get-ChildItem (Join-Path $InstallDir "bvg-svc.*.log") -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime | Select-Object -Last 1
  if ($log) { Get-Content $log.FullName -Tail 15 | ForEach-Object { Say "  $_" } }
  Fail "service did not reach Running state - see $InstallDir\bvg-svc.*.log"
}

# --- 7. Success summary --------------------------------------------------
Done "installation complete"
Write-Host ""
Write-Host "binary:       $ExePath"
Write-Host "credentials:  $CredentialsPath"
Write-Host "transport:    $Transport"
Write-Host "service:      sc.exe query $ServiceName  (WinSW: $WinSwExe)"
Write-Host "logs:         $InstallDir\bvg-svc.*.log"
Write-Host ""
Write-Host "status:       & '$ExePath' status"
