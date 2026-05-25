#requires -Version 5.1
<#
.SYNOPSIS
  Removes the bvg Windows service and (optionally) the install dir.

.PARAMETER KeepFiles
  When set, leaves %ProgramData%\bvg\ in place (credentials, logs).
  Without this switch, the install directory is removed.

.EXAMPLE
  iwr https://raw.githubusercontent.com/appfabriek/bvg/main/uninstall.ps1 -UseBasicParsing | iex
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

$ExePath = Join-Path $InstallDir "bvg.exe"
$CredsPath = Join-Path $InstallDir "credentials.json"

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

# Tell bvgeert we're leaving so the Transport::Client record gets disabled.
# Best-effort: if the network's down or the token's expired, we still
# continue with the local cleanup.
if ((Test-Path $ExePath) -and (Test-Path $CredsPath)) {
  Say "deregistering from bvgeert..."
  $env:BVG_CREDENTIALS = $CredsPath
  try {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & $ExePath unpair 2>&1 | ForEach-Object { Write-Host "  $_" }
    $ErrorActionPreference = $prev
  } catch { Write-Host "  unpair failed (continuing)" -ForegroundColor Yellow }
}

$updateTask = "$ServiceName-update"
$existingTask = Get-ScheduledTask -TaskName $updateTask -ErrorAction SilentlyContinue
if ($existingTask) {
  Say "removing scheduled update task '$updateTask'..."
  Unregister-ScheduledTask -TaskName $updateTask -Confirm:$false
}

if (-not $KeepFiles -and (Test-Path $InstallDir)) {
  Say "removing $InstallDir..."
  # credentials.json is owned by SYSTEM with ACL hardened to "SYSTEM:F +
  # Administrators:R" by install.ps1, so Remove-Item gets "Access denied".
  # Take ownership as Administrators, then reset the ACL across the tree
  # so default ProgramData inheritance gives us full control.
  try { & takeown.exe /F $InstallDir /R /A /D Y 2>$null | Out-Null } catch { }
  try { & icacls.exe $InstallDir /reset /T /C 2>$null | Out-Null } catch { }

  $prev = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  Remove-Item -Path $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
  $ErrorActionPreference = $prev

  # Fallback: PowerShell's Remove-Item sometimes still chokes on stubborn
  # ACLs that cmd's rd handles fine. Use it as a last resort.
  if (Test-Path $InstallDir) {
    & cmd.exe /c "rd /S /Q `"$InstallDir`"" 2>$null
  }

  if (Test-Path $InstallDir) {
    Fail "could not remove $InstallDir — try manually: takeown /F $InstallDir /R /A /D Y; icacls $InstallDir /reset /T /C; rmdir /S /Q $InstallDir"
  }
}

Done "uninstall complete"
