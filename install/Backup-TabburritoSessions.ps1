<#
.SYNOPSIS
    Backs up (or restores) Tabburrito's WebView2 sessions and logins.

.DESCRIPTION
    Snapshots %LOCALAPPDATA%\Tabburrito\TabburritoWebViewData to a timestamped
    zip so a lost session folder means restoring a backup, not re-scanning the
    WhatsApp QR code and logging back in to all five services.

    This exists because on 2026-08-04 the entire session folder was destroyed
    with no backup of any kind - File History was off, no restore points, and
    the folder was gitignored. Recovery was impossible.

    IMPORTANT: WebView2 holds files open while Tabburrito runs. Backups taken
    with the app running can capture a torn database. This script refuses to
    run unless the app is closed, or -Force is passed.

.PARAMETER Restore
    Restore from a backup zip instead of creating one.

.PARAMETER Path
    Backup zip to restore from. Defaults to the newest backup.

.PARAMETER Force
    Back up even while Tabburrito is running (may produce a torn snapshot).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Backup-TabburritoSessions.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Backup-TabburritoSessions.ps1 -Restore
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [string]$Path,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DataDir   = Join-Path $env:LOCALAPPDATA 'Tabburrito\TabburritoWebViewData'
$BackupDir = Join-Path $env:LOCALAPPDATA 'Tabburrito\Backups'

function Test-AppRunning {
    [bool](Get-Process -Name 'tabburrito' -ErrorAction SilentlyContinue)
}

# --- Restore ---------------------------------------------------------------
if ($Restore) {
    if (-not $Path) {
        $newest = Get-ChildItem -LiteralPath $BackupDir -Filter '*.zip' -ErrorAction SilentlyContinue |
                  Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $newest) { Write-Error "No backups found in $BackupDir" }
        $Path = $newest.FullName
    }
    if (-not (Test-Path -LiteralPath $Path)) { Write-Error "Backup not found: $Path" }

    if (Test-AppRunning) { Write-Error 'Close Tabburrito before restoring.' }

    # Preserve whatever is currently there before overwriting it.
    if (Test-Path -LiteralPath $DataDir) {
        $stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
        $aside = "$DataDir.replaced-$stamp"
        Move-Item -LiteralPath $DataDir -Destination $aside
        Write-Host "Existing sessions moved aside to: $aside" -ForegroundColor Yellow
    }

    New-Item -ItemType Directory -Path $DataDir -Force | Out-Null
    Expand-Archive -LiteralPath $Path -DestinationPath $DataDir -Force
    Write-Host "Restored sessions from $Path" -ForegroundColor Green
    return
}

# --- Backup ----------------------------------------------------------------
if (-not (Test-Path -LiteralPath $DataDir)) {
    Write-Host "No session data at $DataDir - nothing to back up." -ForegroundColor Yellow
    return
}

if ((Test-AppRunning) -and -not $Force) {
    Write-Error 'Tabburrito is running - a backup taken now could capture a torn database. Close it and rerun, or pass -Force to accept that risk.'
}

New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
$stamp   = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$zipPath = Join-Path $BackupDir "TabburritoSessions_$stamp.zip"

Write-Host 'Backing up sessions...' -ForegroundColor Cyan

# Stage a copy first. Compress-Archive aborts the entire archive when it hits a
# file WebView2 holds open (notably EBWebView\lockfile), so archiving $DataDir
# directly fails outright while the app is running. Copying first lets us skip
# only the locked files and still capture everything else.
$staging = Join-Path $env:TEMP "TabburritoBackupStaging_$stamp"
$skipped = New-Object System.Collections.Generic.List[string]

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    foreach ($item in Get-ChildItem -LiteralPath $DataDir -Recurse -File -Force) {
        $relative = $item.FullName.Substring($DataDir.Length).TrimStart('\')
        $dest     = Join-Path $staging $relative
        $destDir  = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        try {
            Copy-Item -LiteralPath $item.FullName -Destination $dest -Force -ErrorAction Stop
        } catch {
            # Locked/transient file (e.g. lockfile). Record it rather than failing
            # the whole backup, but never hide it - see the report below.
            $skipped.Add($relative)
        }
    }

    $staged = Get-ChildItem -LiteralPath $staging -Recurse -File
    if (-not $staged) {
        Write-Error "Nothing could be copied from $DataDir - no backup was created."
    }

    Compress-Archive -Path (Join-Path $staging '*') -DestinationPath $zipPath -CompressionLevel Optimal
} finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

# Fail loudly rather than reporting a green result for an empty archive -
# a backup that silently contains nothing is worse than no backup at all.
$size = (Get-Item -LiteralPath $zipPath).Length
if ($size -lt 1024) {
    Remove-Item -LiteralPath $zipPath -Force
    Write-Error "Backup produced an implausibly small archive ($size bytes). Nothing was saved."
}

# Keep the 10 most recent backups.
Get-ChildItem -LiteralPath $BackupDir -Filter '*.zip' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 10 |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Backup complete.' -ForegroundColor Green
Write-Host ("  File: {0}" -f $zipPath)
Write-Host ("  Size: {0:N1} MB" -f ($size / 1MB))

if ($skipped.Count) {
    Write-Host ("  Skipped {0} locked file(s):" -f $skipped.Count) -ForegroundColor Yellow
    $skipped | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    if ($skipped.Count -gt 5) { Write-Host ("    ... and {0} more" -f ($skipped.Count - 5)) -ForegroundColor Yellow }
    Write-Host '  Close Tabburrito and rerun for a complete, consistent backup.' -ForegroundColor Yellow
}
Write-Host ''
