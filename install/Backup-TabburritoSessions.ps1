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

.PARAMETER SkipIfRunning
    Exit 0 without backing up when Tabburrito is running, instead of erroring.
    For the weekly scheduled task: a skipped backup is a normal outcome, and
    reporting it as a failure every week would train the user to ignore it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Backup-TabburritoSessions.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Backup-TabburritoSessions.ps1 -Restore
#>
[CmdletBinding()]
param(
    [switch]$Restore,
    [string]$Path,
    [switch]$Force,
    [switch]$SkipIfRunning,
    [switch]$Full
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
    if ($SkipIfRunning) {
        # Unattended path: skipping is the CORRECT outcome, not a failure.
        # Erroring here would make the weekly scheduled task report a failure
        # every week the app happened to be open, training the user to ignore
        # it - and a torn snapshot is worse than a skipped one.
        Write-Host 'Tabburrito is running - skipping this scheduled backup.' -ForegroundColor Yellow
        exit 0
    }
    Write-Error 'Tabburrito is running - a backup taken now could capture a torn database. Close it and rerun, or pass -Force to accept that risk.'
}

# WebView2 spawns msedgewebview2.exe children that outlive the parent by a few
# seconds and keep lockfile/-wal handles open. Wait for the ones using OUR data
# folder to exit, so a backup taken right after closing the app is complete.
# Other apps embed WebView2 too, so match on the command line, never on name.
if (-not (Test-AppRunning)) {
    for ($i = 0; $i -lt 30; $i++) {
        $holding = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -and $_.CommandLine -like "*$DataDir*" })
        if (-not $holding) { break }
        if ($i -eq 0) { Write-Host 'Waiting for WebView2 to release session files...' -ForegroundColor DarkGray }
        Start-Sleep -Milliseconds 500
    }
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
$excludedBytes = 0L
$excludedCount = 0

# Cache directories only. Anchored on path segments so a site whose name
# happens to contain "Cache" cannot be caught by accident. Service Worker's
# CacheStorage/ScriptCache are caches; its sibling Database (registrations)
# is NOT matched and is kept.
$CacheExcludePattern = '(^|\\)(Cache|Code Cache|GPUCache|DawnCache|DawnGraphiteCache|DawnWebGPUCache|GrShaderCache|ShaderCache|component_crx_cache|Subresource Filter|WidevineCdm|BrowserMetrics|Crashpad|CacheStorage|ScriptCache)(\\|$)'

try {
    New-Item -ItemType Directory -Path $staging -Force | Out-Null

    foreach ($item in Get-ChildItem -LiteralPath $DataDir -Recurse -File -Force) {
        $relative = $item.FullName.Substring($DataDir.Length).TrimStart('\')

        # Skip pure caches. They are ~95% of the folder (Cache 217 MB +
        # Code Cache 146 MB when this was added) and regenerate on demand,
        # so archiving them only bloats every snapshot.
        #
        # What is KEPT is deliberate: Cookies and Login Data hold the session
        # tokens, and IndexedDB is where WhatsApp stores its session keys -
        # dropping it would force a QR re-scan, exactly what this protects
        # against. Local/Session Storage, Preferences and Web Data are small
        # and carry per-site auth state.
        if (-not $Full -and ($relative -match $CacheExcludePattern)) {
            $excludedBytes += $item.Length
            $excludedCount++
            continue
        }

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

# --- Verify before trusting -------------------------------------------------
#
# Only ONE backup is kept, so it has to be known-good before the previous one
# is deleted. A size check alone would pass a truncated or corrupt zip; these
# checks actually open the archive, CRC every entry, and confirm the files
# that carry the logins are present and non-empty.

$size = (Get-Item -LiteralPath $zipPath).Length
if ($size -lt 1024) {
    Remove-Item -LiteralPath $zipPath -Force
    Write-Error "Backup produced an implausibly small archive ($size bytes). Nothing was saved."
}

Write-Host 'Verifying archive...' -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression.FileSystem

$verifyErrors = New-Object System.Collections.Generic.List[string]
$authFound    = @{}
$verifiedCount = 0

# Per-entry CRCs are read straight from the zip's central directory.
#
# ZipArchiveEntry has no Crc32 property on .NET Framework (Windows PowerShell
# 5.1) - it is null there, so comparing against it silently compares against
# nothing and rejects healthy archives. Verified 2026-08-05. Parse the
# central directory instead, which is version-independent.
function Get-ZipEntryCrcs {
    param([string]$Path)
    $crcs = @{}
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # Central directory file header signature: PK\x01\x02
    for ($i = 0; $i -lt $bytes.Length - 46; $i++) {
        if ($bytes[$i] -eq 0x50 -and $bytes[$i+1] -eq 0x4B -and
            $bytes[$i+2] -eq 0x01 -and $bytes[$i+3] -eq 0x02) {
            $crc = [System.BitConverter]::ToUInt32($bytes, $i + 16)
            $nameLen  = [System.BitConverter]::ToUInt16($bytes, $i + 28)
            $extraLen = [System.BitConverter]::ToUInt16($bytes, $i + 30)
            $cmtLen   = [System.BitConverter]::ToUInt16($bytes, $i + 32)
            $name = [System.Text.Encoding]::UTF8.GetString($bytes, $i + 46, $nameLen)
            $crcs[$name.Replace('/', '\')] = $crc
            $i += 45 + $nameLen + $extraLen + $cmtLen
        }
    }
    return $crcs
}

# Standard CRC-32 (IEEE 802.3, polynomial 0xEDB88320) lookup table - the same
# checksum zip records per entry. Built once; the per-entry loop below is hot.
$Crc32Table = New-Object uint32[] 256
for ($n = 0; $n -lt 256; $n++) {
    $c = [uint32]$n
    for ($k = 0; $k -lt 8; $k++) {
        if ($c -band 1) { $c = 0xEDB88320 -bxor ($c -shr 1) } else { $c = $c -shr 1 }
    }
    $Crc32Table[$n] = $c
}

$expectedCrcs = Get-ZipEntryCrcs -Path $zipPath
# Files that must be present for a restore to actually preserve logins.
# IndexedDB matters as much as Cookies: WhatsApp keeps its session keys
# there, and without it a restore still means re-scanning the QR code.
$requiredAuth = @('Cookies', 'Login Data', 'IndexedDB')

try {
    $zip = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
    try {
        $verifiedCount = $zip.Entries.Count
        foreach ($entry in $zip.Entries) {
            if ($entry.Length -eq 0) { continue }

            # Read each entry and compare the CRC32 we compute against the one
            # recorded in the archive.
            #
            # Reading alone is NOT sufficient: .NET validates the CRC only on
            # the DEFLATE path. Entries that Compress-Archive chose to STORE
            # uncompressed (already-compressed or high-entropy data, which
            # includes plenty of a WebView2 profile) stream back corrupted
            # bytes without error. Verified 2026-08-05: flipping 1000 bytes
            # inside a stored entry produced 0 read errors, and the archive
            # would have been accepted as healthy.
            try {
                $stream = $entry.Open()
                try {
                    $crc    = [uint32]::MaxValue
                    $buffer = New-Object byte[] 65536
                    while (($read = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        for ($i = 0; $i -lt $read; $i++) {
                            $crc = ($crc -shr 8) -bxor $Crc32Table[[int](($crc -bxor $buffer[$i]) -band 0xFF)]
                        }
                    }
                    $crc = $crc -bxor [uint32]::MaxValue
                } finally { $stream.Dispose() }
            } catch {
                $verifyErrors.Add("$($entry.FullName): $($_.Exception.Message)")
                continue
            }

            $key = $entry.FullName.Replace('/', '\')
            $expected = $expectedCrcs[$key]
            if ($null -eq $expected) {
                $verifyErrors.Add("$($entry.FullName): no CRC recorded in the archive index")
                continue
            }
            if ($crc -ne $expected) {
                $verifyErrors.Add("$($entry.FullName): CRC mismatch (got $crc, expected $expected)")
                continue
            }

            foreach ($needle in $requiredAuth) {
                if ($entry.FullName -like "*$needle*") { $authFound[$needle] = $true }
            }
        }
    } finally { $zip.Dispose() }
} catch {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Write-Error "Archive could not be opened - it is corrupt. Deleted; the previous backup was kept. $($_.Exception.Message)"
}

if ($verifyErrors.Count) {
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    $detail = ($verifyErrors | Select-Object -First 3) -join '; '
    Write-Error "Archive failed CRC verification on $($verifyErrors.Count) entry(ies) - deleted, previous backup kept. $detail"
}

$missingAuth = $requiredAuth | Where-Object { -not $authFound[$_] }
if ($missingAuth -and -not $Full) {
    # A zip that verifies cleanly but has no login data would restore nothing
    # useful - exactly the false-confidence case this whole script exists for.
    Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
    Write-Error "Archive is missing login data ($($missingAuth -join ', ')) - deleted, previous backup kept. Restoring it would not preserve your sessions."
}

Write-Host ("  Verified: {0:N0} entries, CRC OK, login data present." -f $verifiedCount) -ForegroundColor Green

# Keep only the newest backup. Pruning happens AFTER verification above, so a
# corrupt new archive never displaces a good older one.
Get-ChildItem -LiteralPath $BackupDir -Filter '*.zip' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -Skip 1 |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host 'Backup complete.' -ForegroundColor Green
Write-Host ("  File: {0}" -f $zipPath)
Write-Host ("  Size: {0:N1} MB" -f ($size / 1MB))

if ($excludedCount) {
    # Never let an exclusion be silent - a smaller archive must be explained,
    # or it reads as "everything was captured" when it was not.
    Write-Host ("  Mode: logins only - excluded {0:N0} cache file(s), {1:N1} MB" -f $excludedCount, ($excludedBytes / 1MB)) -ForegroundColor DarkGray
    Write-Host '  Cookies, Login Data, IndexedDB and site storage ARE included.' -ForegroundColor DarkGray
    Write-Host '  Use -Full to archive caches too.' -ForegroundColor DarkGray
}

if ($skipped.Count) {
    Write-Host ("  Skipped {0} locked file(s):" -f $skipped.Count) -ForegroundColor Yellow
    $skipped | Select-Object -First 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor Yellow }
    if ($skipped.Count -gt 5) { Write-Host ("    ... and {0} more" -f ($skipped.Count - 5)) -ForegroundColor Yellow }
    Write-Host '  Close Tabburrito and rerun for a complete, consistent backup.' -ForegroundColor Yellow
}
Write-Host ''
