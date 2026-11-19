<#
.SYNOPSIS
    Tests for Get-TabburritoUpdateDecision (no Pester dependency).

.DESCRIPTION
    Regression coverage for INST-6, found 2026-08-13: the updater compared the
    remote head against local HEAD and never against what was actually
    INSTALLED, so a commit made locally and never pushed could not trigger a
    rebuild. c50d3e6 sat unshipped through six consecutive "Already up to date"
    runs while the installed exe stayed on 026219e.

    Run: powershell -ExecutionPolicy Bypass -File .\install\Tests\UpdateDecision.Tests.ps1
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'TabburritoUpdate.psm1') -Force

$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) {
        $script:Pass++
        Write-Host "  PASS  $Name" -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host "  FAIL  $Name" -ForegroundColor Red
        Write-Host "        expected: $Expected" -ForegroundColor Red
        Write-Host "        actual  : $Actual" -ForegroundColor Red
    }
}

$A = 'aaaaaaa1111111111111111111111111111111111'   # "installed" commit
$B = 'bbbbbbb2222222222222222222222222222222222'   # newer local commit

Write-Host ''
Write-Host 'Get-TabburritoUpdateDecision' -ForegroundColor Cyan

# --- THE REGRESSION (INST-6) ----------------------------------------------
# Local is ahead of origin (nothing to pull) and the installed exe was built
# from an OLDER commit. The old logic returned NeedsBuild=$false here.
$d = Get-TabburritoUpdateDecision -LocalHead $B -InstalledCommit $A `
        -RemoteAlreadyIncluded $true -TargetExeExists $true -Force $false
Assert-Equal $true  $d.NeedsBuild 'INST-6: local commit ahead of install -> rebuilds'
Assert-Equal $false $d.NeedsPull  'INST-6: local commit ahead of install -> does NOT pull'

# --- Must not rebuild forever ---------------------------------------------
# Once that commit is installed, the very next run must go quiet again.
$d = Get-TabburritoUpdateDecision -LocalHead $B -InstalledCommit $B `
        -RemoteAlreadyIncluded $true -TargetExeExists $true -Force $false
Assert-Equal $false $d.NeedsBuild 'installed commit == local HEAD -> no rebuild'
Assert-Equal 'already up to date' $d.Reason 'up-to-date reason string'

# --- Remote has new commits ------------------------------------------------
$d = Get-TabburritoUpdateDecision -LocalHead $A -InstalledCommit $A `
        -RemoteAlreadyIncluded $false -TargetExeExists $true -Force $false
Assert-Equal $true $d.NeedsPull  'remote ahead -> pulls'
Assert-Equal $true $d.NeedsBuild 'remote ahead -> rebuilds'

# --- Missing exe (the Defender-quarantine case, INST-3) --------------------
$d = Get-TabburritoUpdateDecision -LocalHead $A -InstalledCommit $A `
        -RemoteAlreadyIncluded $true -TargetExeExists $false -Force $false
Assert-Equal $true $d.NeedsBuild 'quarantined/missing exe -> rebuilds'
Assert-Equal 'installed exe is missing' $d.Reason 'missing-exe reason string'

# --- Missing manifest is stale, not "fine" ---------------------------------
$d = Get-TabburritoUpdateDecision -LocalHead $A -InstalledCommit '' `
        -RemoteAlreadyIncluded $true -TargetExeExists $true -Force $false
Assert-Equal $true $d.NeedsBuild 'no manifest -> rebuilds rather than assuming current'

# --- Force ------------------------------------------------------------------
$d = Get-TabburritoUpdateDecision -LocalHead $A -InstalledCommit $A `
        -RemoteAlreadyIncluded $true -TargetExeExists $true -Force $true
Assert-Equal $true   $d.NeedsBuild 'force -> rebuilds'
Assert-Equal 'forced' $d.Reason    'force reason string'

# --- Get-InstalledCommit ----------------------------------------------------
Write-Host ''
Write-Host 'Get-InstalledCommit' -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("tabburrito-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
try {
    Assert-Equal '' (Get-InstalledCommit -InstallDir $tmp) 'no manifest file -> empty'

    Set-Content -Path (Join-Path $tmp 'install-manifest.json') -Value '{ not json' -Encoding utf8
    Assert-Equal '' (Get-InstalledCommit -InstallDir $tmp) 'corrupt manifest -> empty (not a crash)'

    Set-Content -Path (Join-Path $tmp 'install-manifest.json') -Value '{"version":"0.1.0"}' -Encoding utf8
    Assert-Equal '' (Get-InstalledCommit -InstallDir $tmp) 'manifest without sourceCommit -> empty'

    Set-Content -Path (Join-Path $tmp 'install-manifest.json') -Value "{`"sourceCommit`":`"$A`"}" -Encoding utf8
    Assert-Equal $A (Get-InstalledCommit -InstallDir $tmp) 'valid manifest -> sourceCommit'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host ("{0} passed, {1} failed" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail) { 'Red' } else { 'Green' })
if ($script:Fail) { exit 1 }
exit 0
