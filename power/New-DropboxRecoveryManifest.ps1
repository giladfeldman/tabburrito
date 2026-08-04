[CmdletBinding()]
param(
    [string]$DropboxRoot = 'C:\Users\filin\Dropbox',
    [datetime]$Cutoff = [datetime]'2026-07-30T08:33:51',
    [string]$OutputDirectory = $null
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if (-not $OutputDirectory) {
    $vibeRoot = if ($env:VIBE_ROOT) { $env:VIBE_ROOT } else { Join-Path $HOME 'Vibe' }
    if (-not (Test-Path -LiteralPath $vibeRoot -PathType Container)) {
        throw "Vibe root was not found: $vibeRoot (set VIBE_ROOT or pass -OutputDirectory explicitly)"
    }
    $OutputDirectory = Join-Path $vibeRoot 'WindowsTuneUp\recovery-manifests'
}

$prunedDirectoryNames = [System.Collections.Generic.HashSet[string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase
)
@(
    '.dropbox.cache', '.git', 'node_modules', 'bower_components',
    '.pnpm-store', '.npm', '.yarn', '.next', '.nuxt', '.svelte-kit',
    '.vite', '.turbo', '.cache', 'cache', 'caches', '.venv', 'venv',
    'virtualenv', '__pycache__', '.pytest_cache', '.mypy_cache',
    '.ruff_cache', '.tox', '.gradle', 'coverage', '.nyc_output',
    'target', 'build', 'dist', 'out'
) | ForEach-Object { [void]$prunedDirectoryNames.Add($_) }

if (-not (Test-Path -LiteralPath $DropboxRoot -PathType Container)) {
    throw "Dropbox root was not found: $DropboxRoot"
}

$DropboxRoot = (Get-Item -LiteralPath $DropboxRoot -Force).FullName.TrimEnd('\')
$dropboxRootPrefix = "$DropboxRoot\"

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$scanErrors = [System.Collections.Generic.List[object]]::new()
$candidates = [System.Collections.Generic.List[object]]::new()
$directoriesVisited = 0
$filesChecked = 0
$prunedDirectories = 0
$skippedLinks = 0

$stack = [System.Collections.Generic.Stack[string]]::new()
$stack.Push((Get-Item -LiteralPath $DropboxRoot -Force).FullName)

while ($stack.Count -gt 0) {
    $directory = $stack.Pop()
    $directoriesVisited++

    try {
        $children = Get-ChildItem -LiteralPath $directory -Force -ErrorAction Stop
    }
    catch {
        $scanErrors.Add([pscustomobject]@{
            Stage = 'Enumerate'
            Path = $directory
            Error = $_.Exception.Message
        })
        continue
    }

    foreach ($child in $children) {
        if ($child.PSIsContainer) {
            if ($prunedDirectoryNames.Contains($child.Name)) {
                $prunedDirectories++
                continue
            }

            # Skip actual filesystem links/junctions, which can point outside the
            # Dropbox tree or be broken. Dropbox Cloud Files reparse directories
            # have no LinkType and remain safe to enumerate.
            if ($child.LinkType) {
                $skippedLinks++
                continue
            }

            $stack.Push($child.FullName)
            continue
        }

        $filesChecked++
        if ($child.LastWriteTime -lt $Cutoff -and $child.CreationTime -lt $Cutoff) {
            continue
        }

        if (-not $child.FullName.StartsWith($dropboxRootPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            $scanErrors.Add([pscustomobject]@{
                Stage = 'Relativize'
                Path = $child.FullName
                Error = 'Resolved path falls outside the Dropbox root.'
            })
            continue
        }
        $relativePath = $child.FullName.Substring($dropboxRootPrefix.Length)
        $segments = $relativePath -split '[\\/]'
        $scope = if ($segments[0] -ieq 'Vibe') { 'Vibe' } else { 'Dropbox-other' }
        $group = if ($scope -eq 'Vibe' -and $segments.Count -gt 1) {
            "Vibe\$($segments[1])"
        }
        else {
            $segments[0]
        }

        $candidates.Add([pscustomobject]@{
            Scope = $scope
            Group = $group
            RelativePath = $relativePath
            FullPathAtAudit = $child.FullName
            SizeBytes = [int64]$child.Length
            LastWriteTimeLocal = $child.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')
            CreationTimeLocal = $child.CreationTime.ToString('yyyy-MM-dd HH:mm:ss')
            SHA256 = ''
            HashStatus = 'Pending'
        })
    }
}

$orderedCandidates = @($candidates | Sort-Object RelativePath)
$hashed = 0
foreach ($candidate in $orderedCandidates) {
    try {
        $candidate.SHA256 = (Get-FileHash -LiteralPath $candidate.FullPathAtAudit -Algorithm SHA256 -ErrorAction Stop).Hash
        $candidate.HashStatus = 'OK'
        $hashed++
    }
    catch {
        $candidate.HashStatus = "ERROR: $($_.Exception.Message)"
        $scanErrors.Add([pscustomobject]@{
            Stage = 'Hash'
            Path = $candidate.FullPathAtAudit
            Error = $_.Exception.Message
        })
    }
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$csvPath = Join-Path $OutputDirectory "Dropbox-preservation-manifest_$stamp.csv"
$summaryPath = Join-Path $OutputDirectory "Dropbox-preservation-summary_$stamp.md"
$errorPath = Join-Path $OutputDirectory "Dropbox-preservation-errors_$stamp.csv"

$orderedCandidates | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding UTF8
if ($scanErrors.Count -gt 0) {
    $scanErrors | Export-Csv -LiteralPath $errorPath -NoTypeInformation -Encoding UTF8
}

$totalBytes = [int64](($orderedCandidates | Measure-Object SizeBytes -Sum).Sum)
$vibeItems = @($orderedCandidates | Where-Object Scope -eq 'Vibe')
$otherItems = @($orderedCandidates | Where-Object Scope -eq 'Dropbox-other')
$groupRows = @(
    $orderedCandidates |
        Group-Object Scope, Group |
        ForEach-Object {
            [pscustomobject]@{
                Scope = $_.Group[0].Scope
                Group = $_.Group[0].Group
                Files = $_.Count
                SizeMB = [math]::Round((($_.Group | Measure-Object SizeBytes -Sum).Sum / 1MB), 1)
                LatestWrite = ($_.Group | Sort-Object LastWriteTimeLocal -Descending | Select-Object -First 1).LastWriteTimeLocal
            }
        } |
        Sort-Object Scope, Group
)

$summaryLines = [System.Collections.Generic.List[string]]::new()
$summaryLines.Add('# Dropbox preservation manifest')
$summaryLines.Add('')
$summaryLines.Add("- Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$summaryLines.Add(('- Dropbox root at audit: `{0}`' -f $DropboxRoot))
$summaryLines.Add("- Conservative cutoff: $($Cutoff.ToString('yyyy-MM-dd HH:mm:ss')) local time")
$summaryLines.Add("- Candidate files: $($orderedCandidates.Count)")
$summaryLines.Add("- Total candidate size: $([math]::Round($totalBytes / 1MB, 1)) MB")
$summaryLines.Add("- Inside Vibe: $($vibeItems.Count) files")
$summaryLines.Add("- Elsewhere in Dropbox: $($otherItems.Count) files")
$summaryLines.Add("- SHA-256 checksums completed: $hashed")
$summaryLines.Add("- Scan/hash errors: $($scanErrors.Count)")
$summaryLines.Add("- Directories visited: $directoriesVisited")
$summaryLines.Add("- Files checked: $filesChecked")
$summaryLines.Add("- Generated/cache roots pruned: $prunedDirectories")
$summaryLines.Add("- Filesystem links/junctions skipped: $skippedLinks")
$summaryLines.Add('')
$summaryLines.Add('This is a conservative local preservation inventory, not proof of cloud state. A file is included when either its creation or modification time is at or after the cutoff. Generated dependency, cache, build, and version-control directories are excluded.')
$summaryLines.Add('')
$summaryLines.Add('## Groups')
$summaryLines.Add('')
$summaryLines.Add('| Scope | Group | Files | Size (MB) | Latest modification |')
$summaryLines.Add('|---|---|---:|---:|---|')
foreach ($row in $groupRows) {
    $safeGroup = $row.Group.Replace('|', '\|')
    $summaryLines.Add("| $($row.Scope) | $safeGroup | $($row.Files) | $($row.SizeMB) | $($row.LatestWrite) |")
}

$summaryLines | Set-Content -LiteralPath $summaryPath -Encoding UTF8

[pscustomobject]@{
    Manifest = $csvPath
    Summary = $summaryPath
    Errors = if ($scanErrors.Count -gt 0) { $errorPath } else { $null }
    CandidateFiles = $orderedCandidates.Count
    TotalSizeMB = [math]::Round($totalBytes / 1MB, 1)
    VibeFiles = $vibeItems.Count
    OtherDropboxFiles = $otherItems.Count
    HashesCompleted = $hashed
    ErrorsCount = $scanErrors.Count
    DirectoriesVisited = $directoriesVisited
    FilesChecked = $filesChecked
    PrunedDirectories = $prunedDirectories
    SkippedLinks = $skippedLinks
}
