<#
.SYNOPSIS
    Installs Tabburrito (WebView2) as a proper per-user Windows application.

.DESCRIPTION
    Installs to %LOCALAPPDATA%\Programs\Tabburrito - the standard per-user
    application location (same convention VS Code, Slack, and Discord use).
    Per-user rather than Program Files means no elevation is required, which
    also lets the auto-updater replace the exe unattended.

    User data (WebView2 sessions/logins) lives separately in
    %LOCALAPPDATA%\Tabburrito\TabburritoWebViewData and is NEVER touched by
    install, update, or uninstall unless you pass -PurgeData.

    Why this exists: the previous "release" exe lived inside the cargo build
    output directory (build\cargo-target-webview2\release\) with sessions
    beside it. A routine build-cache cleanup deleted every logged-in session
    on 2026-08-04. Installed program files and user data must never live
    inside a build directory.

.PARAMETER SourceExe
    Path to a freshly built tabburrito.exe. Defaults to the standard
    out-of-repo build location.

.PARAMETER NoShortcuts
    Skip creating Start Menu and Desktop shortcuts.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Install-Tabburrito.ps1
#>
[CmdletBinding()]
param(
    [string]$SourceExe,
    [switch]$NoShortcuts
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Paths -----------------------------------------------------------------
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Tabburrito'
$DataDir    = Join-Path $env:LOCALAPPDATA 'Tabburrito\TabburritoWebViewData'
$TargetExe  = Join-Path $InstallDir 'tabburrito.exe'
$RepoRoot   = Split-Path -Parent $PSScriptRoot

if (-not $SourceExe) {
    $SourceExe = Join-Path $env:LOCALAPPDATA 'TabburritoBuild\cargo-target\release\tabburrito.exe'
}

Write-Host ''
Write-Host 'Tabburrito installer' -ForegroundColor Cyan
Write-Host '====================' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path -LiteralPath $SourceExe)) {
    Write-Error @"
Built exe not found: $SourceExe

Build it first:
  `$env:CARGO_TARGET_DIR="`$env:LOCALAPPDATA\TabburritoBuild\cargo-target"
  cargo build --release --manifest-path "$RepoRoot\src-tauri\Cargo.toml"
"@
}

# --- Stop any running instance so the exe is not locked --------------------
$running = Get-Process -Name 'tabburrito' -ErrorAction SilentlyContinue
if ($running) {
    Write-Host 'Stopping running Tabburrito...' -ForegroundColor Yellow
    $running | Stop-Process -Force
    # Wait for the file lock to clear rather than sleeping a fixed interval.
    for ($i = 0; $i -lt 50 -and (Get-Process -Name 'tabburrito' -ErrorAction SilentlyContinue); $i++) {
        Start-Sleep -Milliseconds 100
    }
}

# --- Install ---------------------------------------------------------------
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
New-Item -ItemType Directory -Path $DataDir    -Force | Out-Null

# Copy to a temp name then move into place, so a failed copy cannot leave a
# half-written exe as the installed application.
$staged = "$TargetExe.staged"
Copy-Item -LiteralPath $SourceExe -Destination $staged -Force
Move-Item -LiteralPath $staged -Destination $TargetExe -Force

$version = (Get-Item -LiteralPath $TargetExe).VersionInfo.FileVersion
if (-not $version) { $version = '0.1.0' }

# Record what is installed so the updater can compare against the remote build.
# repoRoot lets the running app locate Update-Tabburrito.ps1 for the in-app
# "Check for updates" button — the installed exe lives outside the repo.
$manifest = [ordered]@{
    version     = $version
    installedAt = (Get-Date).ToString('o')
    exePath     = $TargetExe
    dataDir     = $DataDir
    repoRoot    = $RepoRoot
    sourceCommit = (& git -C $RepoRoot rev-parse HEAD 2>$null)
}
# Write WITHOUT a BOM. Windows PowerShell 5.1's `-Encoding utf8` emits a UTF-8
# BOM, and serde_json (which the app uses to read this file) rejects a leading
# BOM as a syntax error - that broke the in-app updater on 2026-08-05.
[System.IO.File]::WriteAllText(
    (Join-Path $InstallDir 'install-manifest.json'),
    ($manifest | ConvertTo-Json),
    (New-Object System.Text.UTF8Encoding $false))

# --- Shortcuts -------------------------------------------------------------
if (-not $NoShortcuts) {
    $shell = New-Object -ComObject WScript.Shell
    $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Tabburrito.lnk'
    foreach ($linkPath in @($startMenu, (Join-Path ([Environment]::GetFolderPath('Desktop')) 'Tabburrito.lnk'))) {
        $lnk = $shell.CreateShortcut($linkPath)
        $lnk.TargetPath       = $TargetExe
        $lnk.WorkingDirectory = $InstallDir
        $lnk.Description      = 'Tabburrito - multi-service web app dock'
        $lnk.Save()
    }
    Write-Host 'Created Start Menu and Desktop shortcuts.' -ForegroundColor Green
}

# --- Add/Remove Programs registration --------------------------------------
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tabburrito'
New-Item -Path $uninstallKey -Force | Out-Null
$uninstallCmd = "powershell -ExecutionPolicy Bypass -File `"$RepoRoot\install\Uninstall-Tabburrito.ps1`""
Set-ItemProperty -Path $uninstallKey -Name 'DisplayName'     -Value 'Tabburrito'
Set-ItemProperty -Path $uninstallKey -Name 'DisplayVersion'  -Value $version
Set-ItemProperty -Path $uninstallKey -Name 'Publisher'       -Value 'Tabburrito'
Set-ItemProperty -Path $uninstallKey -Name 'InstallLocation' -Value $InstallDir
Set-ItemProperty -Path $uninstallKey -Name 'DisplayIcon'     -Value $TargetExe
Set-ItemProperty -Path $uninstallKey -Name 'UninstallString' -Value $uninstallCmd
Set-ItemProperty -Path $uninstallKey -Name 'NoModify'        -Value 1 -Type DWord
Set-ItemProperty -Path $uninstallKey -Name 'NoRepair'        -Value 1 -Type DWord

Write-Host ''
Write-Host 'Installed successfully.' -ForegroundColor Green
Write-Host "  Program : $TargetExe"
Write-Host "  Version : $version"
Write-Host "  Sessions: $DataDir"
Write-Host ''
Write-Host 'Sessions are stored separately from the program and survive every' -ForegroundColor DarkGray
Write-Host 'update and uninstall (unless you pass -PurgeData to the uninstaller).' -ForegroundColor DarkGray
Write-Host ''
