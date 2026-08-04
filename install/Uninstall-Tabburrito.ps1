<#
.SYNOPSIS
    Uninstalls Tabburrito, preserving your logged-in sessions by default.

.DESCRIPTION
    Removes the installed program, shortcuts, scheduled update task, and
    Add/Remove Programs entry.

    Your WebView2 sessions in %LOCALAPPDATA%\Tabburrito are KEPT unless you
    explicitly pass -PurgeData. Deleting sessions means re-scanning the
    WhatsApp QR code and logging back in to every service, so it is never
    the default and never a side effect of removing the program.

.PARAMETER PurgeData
    Also delete all saved sessions and logins. Irreversible.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Uninstall-Tabburrito.ps1
#>
[CmdletBinding()]
param(
    [switch]$PurgeData
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Tabburrito'
$DataParent = Join-Path $env:LOCALAPPDATA 'Tabburrito'

Write-Host ''
Write-Host 'Uninstalling Tabburrito...' -ForegroundColor Cyan

$running = Get-Process -Name 'tabburrito' -ErrorAction SilentlyContinue
if ($running) {
    $running | Stop-Process -Force
    for ($i = 0; $i -lt 50 -and (Get-Process -Name 'tabburrito' -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 100
    }
}

# Scheduled auto-update task
schtasks /Delete /TN 'Tabburrito Auto-Update' /F 2>$null | Out-Null

# Shortcuts
foreach ($lnk in @(
    (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Tabburrito.lnk'),
    (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Tabburrito.lnk')
)) {
    if (Test-Path -LiteralPath $lnk) { Remove-Item -LiteralPath $lnk -Force }
}

# Program files
if (Test-Path -LiteralPath $InstallDir) {
    Remove-Item -LiteralPath $InstallDir -Recurse -Force
    Write-Host "Removed $InstallDir" -ForegroundColor Green
}

# Add/Remove Programs entry
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tabburrito'
if (Test-Path $uninstallKey) { Remove-Item -Path $uninstallKey -Recurse -Force }

# User data - opt-in only
if ($PurgeData) {
    if (Test-Path -LiteralPath $DataParent) {
        Remove-Item -LiteralPath $DataParent -Recurse -Force
        Write-Host 'Deleted all sessions and logins (-PurgeData).' -ForegroundColor Yellow
    }
} elseif (Test-Path -LiteralPath $DataParent) {
    Write-Host ''
    Write-Host 'Sessions were KEPT at:' -ForegroundColor Green
    Write-Host "  $DataParent"
    Write-Host 'Reinstalling will pick them up automatically.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Uninstalled.' -ForegroundColor Green
Write-Host ''
