<#
.SYNOPSIS
    Updates the installed Tabburrito when new commits land on GitHub.

.DESCRIPTION
    Checks the tracked remote branch for commits newer than the installed
    build. If found: pulls, rebuilds the release exe, and reinstalls it.

    Sessions live in %LOCALAPPDATA%\Tabburrito and are never touched.

    The build target directory is deliberately OUTSIDE the repo
    (%LOCALAPPDATA%\TabburritoBuild). Build output must never sit next to
    user data - that arrangement is what destroyed the sessions on
    2026-08-04 when the build cache was cleaned.

    Safety: if the rebuild fails, the currently installed exe is left exactly
    as it was. A broken build never replaces a working install.

.PARAMETER Force
    Rebuild and reinstall even when already up to date.

.PARAMETER Quiet
    Suppress console output (used by the scheduled task).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Update-Tabburrito.ps1
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent $PSScriptRoot
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\Tabburrito'
$TargetExe  = Join-Path $InstallDir 'tabburrito.exe'
$BuildDir   = Join-Path $env:LOCALAPPDATA 'TabburritoBuild\cargo-target'
$BuiltExe   = Join-Path $BuildDir 'release\tabburrito.exe'
$LogFile    = Join-Path $env:LOCALAPPDATA 'TabburritoBuild\update.log'

function Write-Log {
    param([string]$Message, [string]$Color = 'Gray')
    $line = "[{0}] {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message
    New-Item -ItemType Directory -Path (Split-Path -Parent $LogFile) -Force | Out-Null
    Add-Content -Path $LogFile -Value $line -Encoding utf8
    if (-not $Quiet) { Write-Host $Message -ForegroundColor $Color }
}

Write-Log 'Checking for updates...' 'Cyan'

# --- Resolve cargo ---------------------------------------------------------
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (Test-Path -LiteralPath (Join-Path $cargoBin 'cargo.exe')) {
        $env:PATH = "$cargoBin;$env:PATH"
    } else {
        Write-Log 'cargo not found - cannot build. Install Rust from https://rustup.rs/' 'Red'
        exit 1
    }
}

# --- Fetch remote ----------------------------------------------------------
Push-Location $RepoRoot
try {
    $localHead = (& git rev-parse HEAD 2>$null)
    if ($LASTEXITCODE -ne 0) { Write-Log 'Not a git repository.' 'Red'; exit 1 }

    & git fetch --quiet 2>&1 | Out-Null

    # Resolve the upstream branch; fall back to origin/<current-branch>.
    $upstream = (& git rev-parse --abbrev-ref '@{upstream}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $upstream) {
        $branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
        $upstream = "origin/$branch"
    }

    $remoteHead = (& git rev-parse $upstream 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $remoteHead) {
        Write-Log "No remote tracking branch ($upstream). Nothing to update from." 'Yellow'
        exit 0
    }

    # Compare by ANCESTRY, not just inequality. Hashes also differ when the
    # local branch is AHEAD of the remote (unpushed work), and treating that
    # as "new version available" made the updater try to pull nonexistent
    # commits and then fail on unrelated dirty files. Only a remote head that
    # is NOT already an ancestor of local means there is something to pull.
    & git merge-base --is-ancestor $remoteHead $localHead 2>$null
    $remoteAlreadyIncluded = ($LASTEXITCODE -eq 0)
    $hasNewCommits = -not $remoteAlreadyIncluded

    $needsUpdate = $hasNewCommits -or $Force -or -not (Test-Path -LiteralPath $TargetExe)

    if (-not $needsUpdate) {
        if ($localHead -ne $remoteHead) {
            # Ahead of origin: nothing to fetch, and saying "up to date"
            # would hide unpushed work from the user.
            $ahead = (& git rev-list --count "$upstream..HEAD" 2>$null)
            Write-Log "Up to date (local is $ahead commit(s) ahead of $upstream - push to publish)." 'Green'
        } else {
            Write-Log 'Already up to date.' 'Green'
        }
        exit 0
    }

    if ($hasNewCommits) {
        Write-Log "New version available: $($remoteHead.Substring(0,7))" 'Yellow'

        # Refuse to clobber uncommitted local work.
        $dirty = (& git status --porcelain 2>$null)
        if ($dirty) {
            Write-Log 'Working tree has uncommitted changes - skipping pull. Commit or stash, then rerun.' 'Yellow'
            exit 1
        }

        & git merge --ff-only $upstream 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'Cannot fast-forward (branches diverged). Resolve manually.' 'Red'
            exit 1
        }
    }

    # --- Build -------------------------------------------------------------
    Write-Log 'Building release...' 'Cyan'
    $env:CARGO_TARGET_DIR = $BuildDir
    # These are set by build_local.bat for its vendored toolchain; clear them
    # so the update uses the system Rust install.
    $env:CARGO_HOME  = $null
    $env:RUSTUP_HOME = $null

    $buildOutput = & cargo build --release --manifest-path (Join-Path $RepoRoot 'src-tauri\Cargo.toml') 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Log 'BUILD FAILED - installed version left untouched.' 'Red'
        Add-Content -Path $LogFile -Value ($buildOutput | Out-String) -Encoding utf8
        exit 1
    }

    if (-not (Test-Path -LiteralPath $BuiltExe)) {
        Write-Log "Build reported success but exe is missing: $BuiltExe" 'Red'
        exit 1
    }

    # --- Install -----------------------------------------------------------
    Write-Log 'Installing new version...' 'Cyan'
    & (Join-Path $PSScriptRoot 'Install-Tabburrito.ps1') -SourceExe $BuiltExe -NoShortcuts
    if ($LASTEXITCODE -ne 0) { Write-Log 'Install step failed.' 'Red'; exit 1 }

    Write-Log 'Update complete. Sessions untouched.' 'Green'
}
finally {
    Pop-Location
}
