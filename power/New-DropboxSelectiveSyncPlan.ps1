[CmdletBinding()]
param(
    [string]$ManifestDirectory = (Join-Path $(if ($env:VIBE_ROOT) { $env:VIBE_ROOT } else { Join-Path $HOME 'Vibe' }) 'WindowsTuneUp\recovery-manifests'),
    [string]$ComparisonCsv = '',
    [string]$CandidateCsv = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LatestFile {
    param([string]$Pattern)
    Get-ChildItem -LiteralPath $ManifestDirectory -Filter $Pattern -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

if ([string]::IsNullOrWhiteSpace($ComparisonCsv)) {
    $item = Get-LatestFile -Pattern 'Dropbox-cloud-local-directory-comparison_*.csv'
    if ($null -eq $item) { throw 'Cloud-versus-local comparison CSV was not found.' }
    $ComparisonCsv = $item.FullName
}
if ([string]::IsNullOrWhiteSpace($CandidateCsv)) {
    $item = Get-LatestFile -Pattern 'Dropbox-selective-sync-exclusion-candidates_*.csv'
    if ($null -eq $item) { throw 'Selective-sync candidate CSV was not found.' }
    $CandidateCsv = $item.FullName
}

$comparison = @(Import-Csv -LiteralPath $ComparisonCsv)
$candidates = @(Import-Csv -LiteralPath $CandidateCsv)
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$planPath = Join-Path $ManifestDirectory "Dropbox-selective-sync-restoration-plan_$stamp.md"
$checkboxCsvPath = Join-Path $ManifestDirectory "Dropbox-selective-sync-checkbox-map_$stamp.csv"
$localOnlyCsvPath = Join-Path $ManifestDirectory "Dropbox-local-only-preservation-review_$stamp.csv"

$candidateSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$candidates.RelativePath | ForEach-Object { [void]$candidateSet.Add($_) }

$nestedCandidateRoots = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($candidate in $candidates) {
    if ([int]$candidate.Depth -gt 1) {
        [void]$nestedCandidateRoots.Add(($candidate.RelativePath -split '\\')[0])
    }
}

$rootCloudFolders = @($comparison | Where-Object { $_.Depth -eq '1' -and $_.Status -ne 'LocalOnly' } | Sort-Object RelativePath)
$checkboxRows = [System.Collections.Generic.List[object]]::new()
foreach ($row in $rootCloudFolders) {
    $isExcluded = $candidateSet.Contains($row.RelativePath)
    $hasNestedExclusions = $nestedCandidateRoots.Contains($row.RelativePath)
    $action = if ($isExcluded) { 'DESELECT' } elseif ($hasNestedExclusions) { 'SELECT_PARENT_THEN_DESELECT_LISTED_CHILDREN' } else { 'SELECT' }
    $checkboxRows.Add([pscustomobject]@{
        Order = 1
        Level = 'TopLevel'
        Action = $action
        RelativePath = $row.RelativePath
        CloudFileCount = [int64]$row.CloudFileCount
        CloudBytes = [int64]$row.CloudBytes
        LocalFileCount = [int64]$row.LocalFileCount
        LocalBytes = [int64]$row.LocalBytes
        Reason = if ($isExcluded) { 'Cloud-only: absent from preserved local footprint' } elseif ($hasNestedExclusions) { 'Present locally, but contains cloud-only descendant branches' } else { 'Present in both cloud and preserved local footprint' }
    })
}
foreach ($row in @($candidates | Where-Object { [int]$_.Depth -gt 1 } | Sort-Object RelativePath)) {
    $checkboxRows.Add([pscustomobject]@{
        Order = 2
        Level = 'Nested'
        Action = 'DESELECT'
        RelativePath = $row.RelativePath
        CloudFileCount = [int64]$row.CloudFileCount
        CloudBytes = [int64]$row.CloudBytes
        LocalFileCount = [int64]0
        LocalBytes = [int64]0
        Reason = 'Cloud-only descendant: absent from preserved local footprint'
    })
}
$checkboxRows | Sort-Object Order, RelativePath | Export-Csv -LiteralPath $checkboxCsvPath -NoTypeInformation -Encoding UTF8

$localOnly = @($comparison | Where-Object { $_.Status -eq 'LocalOnly' })
$localOnlySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$localOnly.RelativePath | ForEach-Object { [void]$localOnlySet.Add($_) }
$localOnlyTopmost = @($localOnly | Where-Object {
    $parent = $_.ParentRelativePath
    [string]::IsNullOrWhiteSpace($parent) -or -not $localOnlySet.Contains($parent)
} | Sort-Object RelativePath)

$generatedPattern = '(^|\\)(node_modules|__pycache__|\.pytest_cache|\.ruff_cache|\.mypy_cache|\.cache|\.next|\.venv|venv|renv\\library)(\\|$)'
$localOnlyReview = foreach ($row in $localOnlyTopmost) {
    $category = if ($row.RelativePath -eq '.dropbox.cache') { 'DropboxInternal' } elseif ($row.RelativePath -match $generatedPattern) { 'GeneratedDependencyOrCache' } else { 'PreserveAndReview' }
    $fullPath = Join-Path (Join-Path $HOME 'Dropbox') $row.RelativePath
    $hasIgnoredMarker = $false
    if (Test-Path -LiteralPath $fullPath) {
        try {
            $markerValue = Get-Content -LiteralPath $fullPath -Stream 'com.dropbox.ignored' -Raw -ErrorAction Stop
            $hasIgnoredMarker = -not [string]::IsNullOrWhiteSpace([string]$markerValue)
        }
        catch { $hasIgnoredMarker = $false }
    }
    [pscustomobject]@{
        RelativePath = $row.RelativePath
        Category = $category
        LocalDirectoryCount = [int64]$row.LocalDirectoryCount
        LocalFileCount = [int64]$row.LocalFileCount
        LocalBytes = [int64]$row.LocalBytes
        HasDropboxIgnoredMarker = $hasIgnoredMarker
        Recommendation = if ($category -eq 'GeneratedDependencyOrCache') { 'Keep local and ignored; do not upload' } elseif ($category -eq 'DropboxInternal') { 'Do not sync' } else { 'Preserve; allow upload only after selective sync is configured' }
    }
}
$localOnlyReview | Export-Csv -LiteralPath $localOnlyCsvPath -NoTypeInformation -Encoding UTF8

$excludedRoot = @($checkboxRows | Where-Object { $_.Level -eq 'TopLevel' -and $_.Action -eq 'DESELECT' } | Sort-Object RelativePath)
$selectedRoot = @($checkboxRows | Where-Object { $_.Level -eq 'TopLevel' -and $_.Action -ne 'DESELECT' } | Sort-Object RelativePath)
$nestedExcluded = @($checkboxRows | Where-Object { $_.Level -eq 'Nested' } | Sort-Object RelativePath)
$preserveReview = @($localOnlyReview | Where-Object { $_.Category -eq 'PreserveAndReview' } | Sort-Object RelativePath)
$generatedReview = @($localOnlyReview | Where-Object { $_.Category -eq 'GeneratedDependencyOrCache' })
$excludedBytes = [double](($candidates | Measure-Object CloudBytes -Sum).Sum)

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Dropbox selective-sync restoration plan')
$lines.Add('')
$lines.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$lines.Add('')
$lines.Add('## Safety rule')
$lines.Add('')
$lines.Add('This plan preserves the directory footprint that existed locally after the old Dropbox client was removed. Every cloud-only branch stays deselected by default. This is conservative: a cloud-only branch may have been an old selective-sync exclusion or may have been created online more recently; either way, it should not be downloaded automatically.')
$lines.Add('')
$lines.Add("The 55 exclusion roots cover approximately $(Format-Size $excludedBytes) of cloud data.")
$lines.Add('')
$lines.Add('## Top-level folders to deselect')
$lines.Add('')
$lines.Add('| Checkbox | Folder | Cloud files | Cloud size |')
$lines.Add('|---|---|---:|---:|')
foreach ($row in $excludedRoot) {
    $lines.Add("| [ ] | $($row.RelativePath.Replace('|','\|')) | $($row.CloudFileCount.ToString('N0')) | $(Format-Size $row.CloudBytes) |")
}

$lines.Add('')
$lines.Add('## Top-level folders to select')
$lines.Add('')
$lines.Add('| Checkbox | Folder | Note | Cloud size | Local size |')
$lines.Add('|---|---|---|---:|---:|')
foreach ($row in $selectedRoot) {
    $note = if ($row.Action -eq 'SELECT_PARENT_THEN_DESELECT_LISTED_CHILDREN') { 'Select parent, then apply nested exclusions below' } else { 'Select' }
    $lines.Add("| [x] | $($row.RelativePath.Replace('|','\|')) | $note | $(Format-Size $row.CloudBytes) | $(Format-Size $row.LocalBytes) |")
}

$lines.Add('')
$lines.Add('## Nested folders to deselect')
$lines.Add('')
foreach ($group in @($nestedExcluded | Group-Object { ($_.RelativePath -split '\\')[0] } | Sort-Object Name)) {
    $lines.Add("### $($group.Name)")
    $lines.Add('')
    $lines.Add('| Checkbox | Path | Cloud files | Cloud size |')
    $lines.Add('|---|---|---:|---:|')
    foreach ($row in @($group.Group | Sort-Object RelativePath)) {
        $lines.Add("| [ ] | $($row.RelativePath.Replace('|','\|')) | $($row.CloudFileCount.ToString('N0')) | $(Format-Size $row.CloudBytes) |")
    }
    $lines.Add('')
}

$lines.Add('## Local-only folders that must be preserved')
$lines.Add('')
$lines.Add('These folders exist locally but were not represented in the cloud metadata. They may contain the work performed while Dropbox was stalled. Do not remove them or deselect their selected ancestor folders.')
$lines.Add('')
$lines.Add('| Local path | Files | Local size |')
$lines.Add('|---|---:|---:|')
foreach ($row in $preserveReview) {
    $lines.Add("| $($row.RelativePath.Replace('|','\|')) | $($row.LocalFileCount.ToString('N0')) | $(Format-Size $row.LocalBytes) |")
}

$lines.Add('')
$lines.Add('## Generated local-only folders')
$lines.Add('')
$lines.Add("Detected topmost generated/cache roots: $($generatedReview.Count). All currently have the `com.dropbox.ignored` marker: $([bool](-not ($generatedReview | Where-Object { -not $_.HasDropboxIgnoredMarker }))).")
$lines.Add('')
$lines.Add('They should remain local and should not upload. The detailed list is in the local-only preservation CSV.')
$lines.Add('')
$lines.Add('## Machine-readable files')
$lines.Add('')
$lines.Add(('- Exact checkbox map: `{0}`' -f $checkboxCsvPath))
$lines.Add(('- Local-only preservation review: `{0}`' -f $localOnlyCsvPath))
$lines.Add(('- Source cloud/local comparison: `{0}`' -f $ComparisonCsv))
$lines.Add(('- Source cloud-only candidates: `{0}`' -f $CandidateCsv))
$lines | Set-Content -LiteralPath $planPath -Encoding UTF8

[pscustomobject]@{
    PlanPath = $planPath
    CheckboxCsvPath = $checkboxCsvPath
    LocalOnlyReviewCsvPath = $localOnlyCsvPath
    SelectedTopLevelCount = $selectedRoot.Count
    ExcludedTopLevelCount = $excludedRoot.Count
    NestedExclusionCount = $nestedExcluded.Count
    LocalOnlyPreserveReviewCount = $preserveReview.Count
    GeneratedIgnoredRootCount = $generatedReview.Count
    ExcludedCloudBytes = [int64]$excludedBytes
}
