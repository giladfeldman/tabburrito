<#
.SYNOPSIS
    Decides whether the installed Tabburrito is stale and must be rebuilt.

.DESCRIPTION
    Extracted from Update-Tabburrito.ps1 so the decision can be tested without
    running a real cargo build. Update-Tabburrito.ps1 imports this module and
    uses Get-TabburritoUpdateDecision as its only staleness authority.
#>

Set-StrictMode -Version Latest

function Get-TabburritoUpdateDecision {
    <#
    .SYNOPSIS
        Returns whether to pull and whether to rebuild+reinstall.

    .PARAMETER LocalHead
        Current local HEAD commit sha.

    .PARAMETER InstalledCommit
        The `sourceCommit` recorded in install-manifest.json - i.e. the commit
        the CURRENTLY INSTALLED exe was built from. Empty when the manifest is
        missing or unreadable, which counts as stale.

    .PARAMETER RemoteAlreadyIncluded
        $true when the remote head is already an ancestor of local HEAD (i.e.
        there is nothing to pull). Result of `git merge-base --is-ancestor`.

    .PARAMETER TargetExeExists
        Whether the installed exe is present on disk.

    .PARAMETER Force
        Rebuild regardless.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$LocalHead,
        [AllowEmptyString()][string]$InstalledCommit = '',
        [bool]$RemoteAlreadyIncluded = $true,
        [bool]$TargetExeExists = $true,
        [bool]$Force = $false
    )

    $needsPull = -not $RemoteAlreadyIncluded

    # THE FIX (INST-6): staleness is "what is installed" vs "what the source
    # tree is at" - NOT "what the remote has" vs "what we have". The old logic
    # only ever compared against the remote, so a commit made locally and never
    # pushed could never trigger a rebuild: the updater logged "Up to date" and
    # the installed exe silently stayed on an older commit indefinitely.
    $installStale = ($InstalledCommit -ne $LocalHead)

    # A pull moves local HEAD, so it always implies a rebuild.
    $needsBuild = $Force -or (-not $TargetExeExists) -or $needsPull -or $installStale

    $reason =
        if ($Force)             { 'forced' }
        elseif (-not $TargetExeExists) { 'installed exe is missing' }
        elseif ($needsPull)     { 'new commits on the remote' }
        elseif (-not $InstalledCommit) { 'no install manifest - cannot tell what is installed' }
        elseif ($installStale)  { "installed build is behind local HEAD (installed $(_Short $InstalledCommit), local $(_Short $LocalHead))" }
        else                    { 'already up to date' }

    [pscustomobject]@{
        NeedsPull  = $needsPull
        NeedsBuild = $needsBuild
        Reason     = $reason
    }
}

function _Short {
    param([AllowEmptyString()][string]$Sha)
    if (-not $Sha) { return '(none)' }
    if ($Sha.Length -le 7) { return $Sha }
    return $Sha.Substring(0, 7)
}

function Get-InstalledCommit {
    <#
    .SYNOPSIS
        Reads sourceCommit out of install-manifest.json, or '' when unreadable.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$InstallDir)

    $manifestPath = Join-Path $InstallDir 'install-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath)) { return '' }
    try {
        $json = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
        $obj  = $json | ConvertFrom-Json -ErrorAction Stop
        # A manifest without the property is as uninformative as no manifest.
        if ($obj.PSObject.Properties.Name -notcontains 'sourceCommit') { return '' }
        if (-not $obj.sourceCommit) { return '' }
        return [string]$obj.sourceCommit
    } catch {
        return ''
    }
}

Export-ModuleMember -Function Get-TabburritoUpdateDecision, Get-InstalledCommit
