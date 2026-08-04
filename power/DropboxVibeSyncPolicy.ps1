[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$DropboxRoot = "$env:USERPROFILE\Dropbox",
    [switch]$Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# These directory names are dependency, virtual-environment, or cache outputs. They
# are reproducible from the source and dependency manifests that remain in Dropbox.
$GeneratedDirectoryNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
@(
    'node_modules', 'bower_components', '.pnpm-store', '.npm',
    '.next', '.nuxt', '.svelte-kit', '.vite', '.turbo', '.cache',
    '.parcel-cache', '.angular', '.venv', 'venv', '__pycache__',
    '.pytest_cache', '.mypy_cache', '.ruff_cache', '.tox', '.eggs',
    '.gradle', '.nyc_output', 'coverage'
) | ForEach-Object { [void]$GeneratedDirectoryNames.Add($_) }

if (-not (Test-Path -LiteralPath $DropboxRoot -PathType Container)) {
    throw "Dropbox root was not found: $DropboxRoot"
}

function Get-GeneratedDirectories {
    param([string]$Root)

    # Dropbox Cloud Files roots are reparse points. PowerShell does not recurse
    # through them when starting at Dropbox itself, so start a separate walk from
    # each first-level folder. Candidate parents are selected before descendants.
    $scanRoots = Get-ChildItem -LiteralPath $Root -Directory -Force -ErrorAction Stop
    $allCandidates = foreach ($scanRoot in $scanRoots) {
        Get-ChildItem -LiteralPath $scanRoot.FullName -Directory -Force -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $GeneratedDirectoryNames.Contains($_.Name) }
    }

    $selected = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in ($allCandidates | Sort-Object FullName.Length, FullName -Unique)) {
        $isBelowSelectedDirectory = $false
        foreach ($parent in $selected) {
            if ($candidate.FullName.StartsWith("$($parent.FullName)\", [System.StringComparison]::OrdinalIgnoreCase)) {
                $isBelowSelectedDirectory = $true
                break
            }
        }
        if (-not $isBelowSelectedDirectory) {
            $selected.Add($candidate)
        }
    }

    $selected
}

$targets = @(Get-GeneratedDirectories -Root $DropboxRoot | Sort-Object FullName -Unique)
if ($targets.Count -eq 0) {
    Write-Host 'No matching generated directories were found.'
    return
}

if (-not $Apply) {
    Write-Host "Dry run: $($targets.Count) generated directory/directories found. No Dropbox state was changed."
    $targets | Select-Object FullName, LastWriteTime | Format-Table -AutoSize
    Write-Host 'Run again with -Apply to keep these directories local and remove their Dropbox copies.'
    return
}

foreach ($target in $targets) {
    if ($PSCmdlet.ShouldProcess($target.FullName, 'Set Dropbox ignored metadata')) {
        Set-Content -LiteralPath $target.FullName -Stream 'com.dropbox.ignored' -Value '1'
        Write-Host "Ignored: $($target.FullName)"
    }
}

Write-Host "Completed. Dropbox will retain these folders locally but remove them from Dropbox.com and other devices."
