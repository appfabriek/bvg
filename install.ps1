#requires -Version 5.1
<#
.SYNOPSIS
  bvg installer for Windows. Installs as a Windows service running
  under Local System, starts automatically at boot, restarts on crash.

.DESCRIPTION
  One-liner install:

    $env:BVG_JOIN_TOKEN   = "jt_..."
    $env:BVG_BVGEERT_HOST = "https://staging.rozendom.nl"
    $env:BVG_TRANSPORT    = "mijn-verbinding"   # optional
    iwr https://raw.githubusercontent.com/appfabriek/bvg/main/install.ps1 -UseBasicParsing | iex

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
  [string]$InstallDir  = (Join-Path $env:ProgramData "bvg")
)

$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor 0x3000

function Say($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Done($msg) { Write-Host $msg -ForegroundColor Green }
function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

# --- 1. Self-elevate via UAC ---------------------------------------------
$IsAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
  Say "elevation required - relaunching with UAC prompt..."
  # Forward the env-vars the elevated session needs.
  $envFwd = @(
    "BVG_JOIN_TOKEN", "BVG_BVGEERT_HOST", "BVG_TRANSPORT", "BVG_AZURE_HUB"
  ) | ForEach-Object {
    $v = [Environment]::GetEnvironmentVariable($_)
    if ($v) { "`$env:$_ = '$($v -replace ""'"", ""''"")';" }
  }

  $scriptText = ($envFwd -join " ") + " " + `
    "iwr https://raw.githubusercontent.com/$Repo/main/install.ps1 -UseBasicParsing | iex"
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

if (-not $JoinToken) {
  Fail "BVG_JOIN_TOKEN is required. Get a join-token from the bvgeert admin (Admin > Connections > new client)."
}
if (-not $BvgeertHost -and -not $AzureHub) {
  Fail "BVG_BVGEERT_HOST is required (direct mode) or BVG_AZURE_HUB (azure mode)."
}

# --- 3. Download release asset -------------------------------------------
$null = New-Item -ItemType Directory -Force -Path $InstallDir
$ZipUrl  = "https://github.com/$Repo/releases/latest/download/bvg-windows-x64.zip"
$ZipPath = Join-Path $env:TEMP "bvg-windows-x64.zip"
$ExePath = Join-Path $InstallDir "bvg.exe"

Say "downloading $ZipUrl..."
try {
  Invoke-WebRequest -Uri $ZipUrl -OutFile $ZipPath -UseBasicParsing
} catch {
  Fail "download failed: $($_.Exception.Message)"
}

# Stop the service if it already runs so we can overwrite the exe.
$existing = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($existing -and $existing.Status -eq "Running") {
  Say "stopping existing service..."
  Stop-Service -Name $ServiceName -Force
  Start-Sleep -Seconds 2
}

Say "extracting to $InstallDir..."
Expand-Archive -Path $ZipPath -DestinationPath $InstallDir -Force
Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue
if (-not (Test-Path $ExePath)) { Fail "bvg.exe not found after extract" }

# --- 4. One-time pair (redeem join-token) --------------------------------
$CredentialsPath = Join-Path $InstallDir "credentials.json"
$env:BVG_CREDENTIALS = $CredentialsPath

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
  & $ExePath @directArgs
  if ($LASTEXITCODE -eq 0) {
    $paired = $true
    Done "  paired via direct route"
  } elseif ($AzureHub) {
    Say "  direct route failed (exit $LASTEXITCODE) - falling back to azure route"
  } else {
    Fail "direct route failed (exit $LASTEXITCODE) and no BVG_AZURE_HUB to fall back on"
  }
}

if (-not $paired -and $AzureHub) {
  if (-not $Transport) { Fail "BVG_TRANSPORT is required for azure route" }
  Say "  trying azure route via $AzureHub..."
  $azureArgs = @("join", "--hub", $AzureHub, "--transport", $Transport, "--token", $JoinToken)
  & $ExePath @azureArgs
  if ($LASTEXITCODE -eq 0) {
    $paired = $true
    Done "  paired via azure route"
  } else {
    Fail "azure route failed (exit $LASTEXITCODE)"
  }
}

if (-not $paired) { Fail "pairing failed - no route succeeded" }

# Defensive lock-down: bvg.exe already restricts the ACL on save, but
# enforce the spec ("SYSTEM + Administrators read only") explicitly here too.
if (Test-Path $CredentialsPath) {
  & icacls.exe $CredentialsPath /inheritance:r `
    /grant:r "SYSTEM:(F)" `
    /grant:r "Administrators:(R)" | Out-Null
}

# --- 5. Register Windows service -----------------------------------------
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
# context reads from %ProgramData% instead of LOCALAPPDATA.
$envKey = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
$existingEnv = @()
try { $existingEnv = (Get-ItemProperty -Path $envKey -Name Environment -ErrorAction Stop).Environment } catch { }
$mergedEnv = @($existingEnv | Where-Object { $_ -notlike "BVG_CREDENTIALS=*" }) + "BVG_CREDENTIALS=$CredentialsPath"
New-ItemProperty -Path $envKey -Name Environment -PropertyType MultiString -Value $mergedEnv -Force | Out-Null

Say "starting service..."
& sc.exe start $ServiceName | Out-Null
Start-Sleep -Seconds 3
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq "Running") {
  Done "service '$ServiceName' is running"
} else {
  Fail "service did not reach Running state - check $InstallDir\logs\"
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
Write-Host "service:      sc.exe query $ServiceName"
Write-Host "update task:  Get-ScheduledTask -TaskName $UpdateTaskName"
Write-Host "update log:   $InstallDir\logs\updater.log"
Write-Host "force update: Start-ScheduledTask -TaskName $UpdateTaskName"
Write-Host "opt-out:      Disable-ScheduledTask -TaskName $UpdateTaskName"
Write-Host "re-pair:      `$env:BVG_CREDENTIALS = '$CredentialsPath'; & '$ExePath' join --host <host> --token <jt_...>; Restart-Service $ServiceName"
