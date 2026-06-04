#requires -Version 5.1
<#
.SYNOPSIS
  Removes the bvg Windows service and (optionally) the install dir.

.PARAMETER KeepFiles
  When set, leaves %ProgramData%\bvg\ in place (credentials, logs).
  Without this switch, the install directory is removed.

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

function Say($msg)  { Write-Host $msg -ForegroundColor Cyan }
function Done($msg) { Write-Host $msg -ForegroundColor Green }
function Fail($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

$IsAdmin = ([Security.Principal.WindowsPrincipal] `
  [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) { Fail "uninstall must run elevated" }

$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($svc) {
  if ($svc.Status -eq "Running") {
    Say "stopping service..."
    Stop-Service -Name $ServiceName -Force
    Start-Sleep -Seconds 2
  }
  Say "deleting service registration..."
  & sc.exe delete $ServiceName | Out-Null
  Start-Sleep -Seconds 1
} else {
  Say "service '$ServiceName' not registered, skipping"
}

$updateTask = "$ServiceName-update"
$existingTask = Get-ScheduledTask -TaskName $updateTask -ErrorAction SilentlyContinue
if ($existingTask) {
  Say "removing scheduled update task '$updateTask'..."
  Unregister-ScheduledTask -TaskName $updateTask -Confirm:$false
}

# Verwijder de Private Trust signing-keten die install.ps1 in de machine-stores
# zette (root in Root, intermediates in CA). Lees 'm uit InstallDir vóór we de
# bestanden weggooien. No-op bij Public Trust of legacy installs.
$chainCerts = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
$p7b = Join-Path $InstallDir "bvg-codesign-chain.p7b"
$rootCer = Join-Path $InstallDir "bvg-codesign-root.cer"
try {
  if (Test-Path $p7b)         { $chainCerts.Import($p7b) }
  elseif (Test-Path $rootCer) { $chainCerts.Import($rootCer) }
} catch { Say "WARN: kon code-signing keten niet inlezen: $($_.Exception.Message)" }

foreach ($cert in $chainCerts) {
  $storeName = if ($cert.Subject -eq $cert.Issuer) { "Root" } else { "CA" }
  try {
    $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, "LocalMachine")
    $store.Open("ReadWrite")
    $found = $store.Certificates.Find("FindByThumbprint", $cert.Thumbprint, $false)
    foreach ($c in $found) { $store.Remove($c) }
    $store.Close()
    if ($found.Count -gt 0) { Say "removed code-signing cert from ${storeName} [$($cert.Thumbprint)]" }
  } catch {
    Say "WARN: could not remove code-signing cert from ${storeName}: $($_.Exception.Message)"
  }
}

if (-not $KeepFiles -and (Test-Path $InstallDir)) {
  Say "removing $InstallDir..."
  # credentials.json staat op een strakke ACL (alleen SYSTEM:Full, Administrators:Read,
  # zonder inheritance) — daardoor faalt Remove-Item met "Access denied". Neem eerst
  # ownership van de tree en reset de ACL's zodat alles verwijderbaar is.
  try {
    & takeown.exe /F $InstallDir /R /A /D Y *> $null
    & icacls.exe $InstallDir /reset /T /C /Q *> $null
  } catch { Say "WARN: kon ACL's niet resetten: $($_.Exception.Message)" }
  Remove-Item -Path $InstallDir -Recurse -Force
}

Done "uninstall complete"
