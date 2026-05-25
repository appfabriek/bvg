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

if (-not $KeepFiles -and (Test-Path $InstallDir)) {
  Say "removing $InstallDir..."
  # credentials.json has its ACL hardened to "SYSTEM:F + Administrators:R" by
  # install.ps1 — Administrators can't delete it without first restoring
  # write/delete rights. Grant Administrators full control across the tree
  # before Remove-Item.
  try { & icacls.exe $InstallDir /grant "Administrators:(F)" /T /C 2>$null | Out-Null } catch { }
  Remove-Item -Path $InstallDir -Recurse -Force
}

Done "uninstall complete"
