#requires -Version 5.1
<#
.SYNOPSIS
  Removes the bvg Windows service (Dart wire-client) and its install dir.

.DESCRIPTION
  Stops + deletes the WinSW service, removes the BVG_CREDENTIALS machine env
  var and the install dir from the machine PATH, and deletes the install dir.
  If `bvg` is on PATH you can equivalently run: `bvg uninstall`.

.PARAMETER KeepFiles
  Leave %ProgramData%\bvg\ in place (credentials, logs).

.EXAMPLE
  iwr https://github.com/appfabriek/bvg/releases/latest/download/uninstall.ps1 -UseBasicParsing | iex
#>

[CmdletBinding()]
param(
  [string]$ServiceName = "bvg",
  [string]$InstallDir  = (Join-Path $env:ProgramData "bvg"),
  [switch]$KeepFiles
)

$ErrorActionPreference = "Stop"
# Native-command stderr (sc.exe, taskkill, WinSW) must not abort the script.
$PSNativeCommandUseErrorActionPreference = $false

function Say($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Done($msg) { Write-Host $msg -ForegroundColor Green }
function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) { Fail "uninstall must run elevated (Run as Administrator)" }

# --- 1. Stop + remove the service ----------------------------------------
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  if ($svc.Status -eq "Running") {
    Say "stopping service..."
    Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
  }
}
# Prefer WinSW's own uninstall (cleans its registration), then sc.exe as a
# fallback for any leftover registration.
$winsw = Join-Path $InstallDir "bvg-svc.exe"
if (Test-Path $winsw) {
  Say "removing WinSW service registration..."
  & $winsw stop      2>$null | Out-Null
  & $winsw uninstall 2>$null | Out-Null
  Start-Sleep -Seconds 1
}
& sc.exe delete $ServiceName 2>$null | Out-Null

# Force-kill a still-running daemon so the exe + credentials.json unlock.
cmd.exe /c "taskkill /F /IM bvg.exe /T >nul 2>&1 & exit 0"
Start-Sleep -Seconds 2

# --- 2. Remove machine env + PATH entry ----------------------------------
[Environment]::SetEnvironmentVariable("BVG_CREDENTIALS", $null, "Machine")
$machinePath = [Environment]::GetEnvironmentVariable("PATH", "Machine")
if ($machinePath) {
  $new = (($machinePath -split ';') | Where-Object { $_ -and $_ -ne $InstallDir }) -join ';'
  if ($new -ne $machinePath) {
    [Environment]::SetEnvironmentVariable("PATH", $new, "Machine")
    Done "removed $InstallDir from machine PATH"
  }
}

# --- 2b. Remove the Private-Trust signing chain --------------------------
# Pull the chain we trusted at install time back out of the machine stores.
# Read the bundled p7b/root from InstallDir BEFORE the dir is deleted below.
$chainCerts = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$p7b = Join-Path $InstallDir "bvg-codesign-chain.p7b"
$rootCer = Join-Path $InstallDir "bvg-codesign-root.cer"
try {
  if (Test-Path $p7b)         { $chainCerts.Import($p7b) }
  elseif (Test-Path $rootCer) { $chainCerts.Import($rootCer) }
} catch { Say "WARN: could not read code-signing chain: $($_.Exception.Message)" }
foreach ($cert in $chainCerts) {
  $storeName = if ($cert.Subject -eq $cert.Issuer) { "Root" } else { "CA" }
  try {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, "LocalMachine")
    $store.Open("ReadWrite")
    $found = $store.Certificates.Find("FindByThumbprint", $cert.Thumbprint, $false)
    foreach ($c in $found) { $store.Remove($c) }
    $store.Close()
    if ($found.Count -gt 0) { Done "removed code-signing cert from ${storeName}" }
  } catch { Say "WARN: could not remove code-signing cert from ${storeName}: $($_.Exception.Message)" }
}

# --- 3. Remove the install dir -------------------------------------------
if (-not $KeepFiles -and (Test-Path $InstallDir)) {
  Say "removing $InstallDir..."
  # credentials.json may carry a tight ACL; take ownership + reset first.
  try {
    & takeown.exe /F $InstallDir /R /A /D Y *> $null
    & icacls.exe $InstallDir /reset /T /C /Q *> $null
  } catch { Say "WARN: could not reset ACLs: $($_.Exception.Message)" }
  Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
}

Done "bvg uninstall complete"
Say "note: this client may still show (offline) under /admin/clients - remove it there to fully deregister."
