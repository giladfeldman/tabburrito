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

Import-Module (Join-Path $PSScriptRoot 'TabburritoUpdate.psm1') -Force

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

    # NOTE: `2>&1` on a native command is a trap in Windows PowerShell 5.1 -
    # each stderr line becomes a NativeCommandError ErrorRecord, which under
    # $ErrorActionPreference='Stop' TERMINATES even when the exe exited 0.
    # git writes progress to stderr, so discard it at the native level instead.
    & git fetch --quiet 2>$null | Out-Null

    # Resolve the upstream branch; fall back to origin/<current-branch>.
    $upstream = (& git rev-parse --abbrev-ref '@{upstream}' 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $upstream) {
        $branch = (& git rev-parse --abbrev-ref HEAD 2>$null)
        $upstream = "origin/$branch"
    }

    $remoteHead = (& git rev-parse $upstream 2>$null)
    $haveRemote = ($LASTEXITCODE -eq 0 -and $remoteHead)

    if ($haveRemote) {
        # Compare by ANCESTRY, not just inequality. Hashes also differ when the
        # local branch is AHEAD of the remote (unpushed work), and treating that
        # as "new version available" made the updater try to pull nonexistent
        # commits and then fail on unrelated dirty files. Only a remote head that
        # is NOT already an ancestor of local means there is something to pull.
        & git merge-base --is-ancestor $remoteHead $localHead 2>$null
        $remoteAlreadyIncluded = ($LASTEXITCODE -eq 0)
    } else {
        # No remote is not a reason to skip a rebuild: local commits still need
        # to reach the installed exe (INST-6). Previously this exited 0 here.
        Write-Log "No remote tracking branch ($upstream) - checking local commits only." 'Yellow'
        $remoteAlreadyIncluded = $true
    }

    # Staleness is decided against what is ACTUALLY INSTALLED (the manifest's
    # sourceCommit), not against the remote. See install\TabburritoUpdate.psm1
    # and install\Tests\UpdateDecision.Tests.ps1 for the INST-6 regression.
    $installedCommit = Get-InstalledCommit -InstallDir $InstallDir

    $decision = Get-TabburritoUpdateDecision `
        -LocalHead $localHead `
        -InstalledCommit $installedCommit `
        -RemoteAlreadyIncluded $remoteAlreadyIncluded `
        -TargetExeExists ([bool](Test-Path -LiteralPath $TargetExe)) `
        -Force ([bool]$Force)

    if (-not $decision.NeedsBuild) {
        if ($haveRemote -and $localHead -ne $remoteHead) {
            # Ahead of origin: nothing to fetch, and saying only "up to date"
            # would hide unpushed work from the user.
            $ahead = (& git rev-list --count "$upstream..HEAD" 2>$null)
            Write-Log "Already up to date (installed build matches local HEAD; local is $ahead commit(s) ahead of $upstream - push to publish)." 'Green'
        } else {
            Write-Log 'Already up to date.' 'Green'
        }
        exit 0
    }

    Write-Log "Rebuild needed: $($decision.Reason)" 'Yellow'

    if ($decision.NeedsPull) {
        Write-Log "New version available: $($remoteHead.Substring(0,7))" 'Yellow'

        # Refuse to clobber uncommitted local work.
        $dirty = (& git status --porcelain 2>$null)
        if ($dirty) {
            Write-Log 'Working tree has uncommitted changes - skipping pull. Commit or stash, then rerun.' 'Yellow'
            exit 1
        }

        & git merge --ff-only $upstream 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            Write-Log 'Cannot fast-forward (branches diverged). Resolve manually.' 'Red'
            exit 1
        }

        # HEAD moved; the manifest written by the install step must record the
        # commit we actually built, not the one we started from.
        $localHead = (& git rev-parse HEAD 2>$null)
    }

    # --- Build -------------------------------------------------------------
    Write-Log 'Building release...' 'Cyan'
    $env:CARGO_TARGET_DIR = $BuildDir
    # These are set by build_local.bat for its vendored toolchain; clear them
    # so the update uses the system Rust install.
    $env:CARGO_HOME  = $null
    $env:RUSTUP_HOME = $null

    # cargo writes its progress ("Compiling ...", "Finished ...") to STDERR.
    # With $ErrorActionPreference='Stop' this script previously died on a
    # SUCCESSFUL build, because `2>&1` turns each stderr line into a
    # NativeCommandError. That went unnoticed until 2026-08-13: the updater had
    # never actually reached the build step (see INST-6 - it always concluded
    # "Already up to date"), so the first real rebuild was the first time this
    # ran. Relax the preference for the duration of the native call only.
    $prevEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $buildOutput = & cargo build --release --manifest-path (Join-Path $RepoRoot 'src-tauri\Cargo.toml') 2>&1
        $buildExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prevEAP
    }

    if ($buildExit -ne 0) {
        Write-Log 'BUILD FAILED - installed version left untouched.' 'Red'
        Add-Content -Path $LogFile -Value ($buildOutput | Out-String) -Encoding utf8
        exit 1
    }

    if (-not (Test-Path -LiteralPath $BuiltExe)) {
        Write-Log "Build reported success but exe is missing: $BuiltExe" 'Red'
        exit 1
    }

    # Sign the build-directory copy too, not just the installed one: Defender
    # scans the build dir as cargo writes it, and that is where the 2026-08-13
    # false positive was re-triggered 12 seconds after the rebuild.
    & (Join-Path $PSScriptRoot 'Sign-Tabburrito.ps1') -Path $BuiltExe | ForEach-Object { Write-Log $_ }

    # --- Install -----------------------------------------------------------
    Write-Log 'Installing new version...' 'Cyan'
    # Shortcuts are recreated (not skipped) so the update path self-heals: a
    # Defender quarantine deletes the Desktop / Start Menu / Quick Launch links
    # along with the exe, and -NoShortcuts left them permanently missing.
    & (Join-Path $PSScriptRoot 'Install-Tabburrito.ps1') -SourceExe $BuiltExe
    if ($LASTEXITCODE -ne 0) { Write-Log 'Install step failed.' 'Red'; exit 1 }

    Write-Log 'Update complete. Sessions untouched.' 'Green'
}
finally {
    Pop-Location
}
