[CmdletBinding()]
param(
    [string]$OutputDirectory = '',
    [string]$LocalDirectoryInventoryCsv = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $vibeRoot = if ($env:VIBE_ROOT) { $env:VIBE_ROOT } else { Join-Path $HOME 'Vibe' }
    if (-not (Test-Path -LiteralPath $vibeRoot -PathType Container)) {
        throw "Vibe root does not exist: $vibeRoot. Set VIBE_ROOT to the correct location."
    }
    $OutputDirectory = Join-Path $vibeRoot 'WindowsTuneUp\recovery-manifests'
}

# Safety boundary: this script calls ONLY these read-only Dropbox metadata routes.
$listFolderUri = 'https://api.dropboxapi.com/2/files/list_folder'
$listFolderContinueUri = 'https://api.dropboxapi.com/2/files/list_folder/continue'

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($LocalDirectoryInventoryCsv)) {
    $latestLocalInventory = Get-ChildItem -LiteralPath $OutputDirectory -Filter 'Dropbox-local-directory-tree_*.csv' -File |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
    if ($null -eq $latestLocalInventory) {
        throw "No local Dropbox directory inventory was found in $OutputDirectory"
    }
    $LocalDirectoryInventoryCsv = $latestLocalInventory.FullName
}

if (-not (Test-Path -LiteralPath $LocalDirectoryInventoryCsv -PathType Leaf)) {
    throw "Local directory inventory was not found: $LocalDirectoryInventoryCsv"
}

$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'
$cloudCsvPath = Join-Path $OutputDirectory "Dropbox-cloud-directory-tree_$stamp.csv"
$cloudTreePath = Join-Path $OutputDirectory "Dropbox-cloud-directory-tree_$stamp.txt"
$comparisonCsvPath = Join-Path $OutputDirectory "Dropbox-cloud-local-directory-comparison_$stamp.csv"
$candidateCsvPath = Join-Path $OutputDirectory "Dropbox-selective-sync-exclusion-candidates_$stamp.csv"
$photosComparisonCsvPath = Join-Path $OutputDirectory "Dropbox-Photos-cloud-local-comparison_$stamp.csv"
$summaryPath = Join-Path $OutputDirectory "Dropbox-cloud-local-comparison-summary_$stamp.md"

$imageExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.heic', '.heif', '.webp', '.raw', '.dng', '.cr2', '.cr3', '.nef', '.arw', '.orf', '.rw2', '.svg') |
    ForEach-Object { [void]$imageExtensions.Add($_) }

$videoExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@('.mp4', '.mov', '.m4v', '.avi', '.mkv', '.wmv', '.webm', '.mts', '.m2ts', '.3gp', '.mpg', '.mpeg', '.vob', '.flv') |
    ForEach-Object { [void]$videoExtensions.Add($_) }

function Convert-ApiPathToRelativePath {
    param([AllowEmptyString()][string]$ApiPath)

    if ([string]::IsNullOrWhiteSpace($ApiPath) -or $ApiPath -eq '/') { return '.' }
    return $ApiPath.TrimStart('/').Replace('/', '\')
}

function Get-ParentRelativePath {
    param([string]$RelativePath)

    if ($RelativePath -eq '.') { return $null }
    $index = $RelativePath.LastIndexOf('\')
    if ($index -lt 0) { return '.' }
    return $RelativePath.Substring(0, $index)
}

function Get-Depth {
    param([string]$RelativePath)

    if ($RelativePath -eq '.') { return 0 }
    return ($RelativePath -split '\\').Count
}

function Format-LogicalSize {
    param([double]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Convert-ToInt64 {
    param($Value)

    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return [int64]0 }
    return [int64]$Value
}

function Convert-ToBoolean {
    param($Value)

    return ([string]$Value).Equals('True', [System.StringComparison]::OrdinalIgnoreCase)
}

function Invoke-DropboxMetadataRpc {
    param(
        [Parameter(Mandatory)][ValidateSet('ListFolder', 'ListFolderContinue')][string]$Operation,
        [Parameter(Mandatory)][hashtable]$Body,
        [Parameter(Mandatory)][string]$BearerToken
    )

    $uri = if ($Operation -eq 'ListFolder') { $listFolderUri } else { $listFolderContinueUri }
    $json = $Body | ConvertTo-Json -Depth 8 -Compress
    $headers = @{ Authorization = "Bearer $BearerToken" }

    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            return Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType 'application/json' -Body $json -TimeoutSec 120
        }
        catch {
            $statusCode = $null
            try { $statusCode = [int]$_.Exception.Response.StatusCode }
            catch { $statusCode = $null }

            if (($statusCode -eq 429 -or $statusCode -ge 500) -and $attempt -lt 6) {
                $delay = [Math]::Min(20, [Math]::Pow(2, $attempt))
                Write-Warning "Dropbox metadata request returned HTTP $statusCode. Retrying in $delay seconds (attempt $attempt of 6)."
                Start-Sleep -Seconds $delay
                continue
            }
            throw
        }
    }
}

$directories = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Ensure-CloudDirectoryRecord {
    param([Parameter(Mandatory)][string]$RelativePath)

    if ($directories.ContainsKey($RelativePath)) {
        return $directories[$RelativePath]
    }

    $parentPath = Get-ParentRelativePath -RelativePath $RelativePath
    if ($null -ne $parentPath -and -not $directories.ContainsKey($parentPath)) {
        [void](Ensure-CloudDirectoryRecord -RelativePath $parentPath)
    }

    $record = [pscustomobject]@{
        RelativePath = $RelativePath
        Depth = [int](Get-Depth -RelativePath $RelativePath)
        ParentRelativePath = $parentPath
        DirectChildDirectoryCount = [int64]0
        DirectFileCount = [int64]0
        DirectBytes = [int64]0
        DirectImageFileCount = [int64]0
        DirectImageBytes = [int64]0
        DirectVideoFileCount = [int64]0
        DirectVideoBytes = [int64]0
        DirectLargeFileCount100MB = [int64]0
        DirectLargeFileBytes100MB = [int64]0
        RecursiveDirectoryCount = [int64]0
        RecursiveFileCount = [int64]0
        RecursiveBytes = [int64]0
        RecursiveImageFileCount = [int64]0
        RecursiveImageBytes = [int64]0
        RecursiveVideoFileCount = [int64]0
        RecursiveVideoBytes = [int64]0
        RecursiveLargeFileCount100MB = [int64]0
        RecursiveLargeFileBytes100MB = [int64]0
    }
    $directories.Add($RelativePath, $record)
    return $record
}

[void](Ensure-CloudDirectoryRecord -RelativePath '.')

$secureToken = Read-Host 'Paste the generated Dropbox access token (input is hidden)' -AsSecureString
$tokenPointer = [IntPtr]::Zero
$accessToken = $null

try {
    $tokenPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    $accessToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($tokenPointer)
    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw 'No Dropbox access token was entered.'
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Write-Host 'Requesting recursive Dropbox metadata. No file contents will be downloaded.'

    $response = Invoke-DropboxMetadataRpc -Operation ListFolder -BearerToken $accessToken -Body @{
        path = ''
        recursive = $true
        include_deleted = $false
        include_has_explicit_shared_members = $false
        include_media_info = $false
        include_mounted_folders = $true
        limit = 2000
    }

    $page = 0
    $entryCount = [int64]0
    while ($true) {
        $page++
        foreach ($entry in @($response.entries)) {
            $entryCount++
            $tag = [string]$entry.'.tag'
            $relativePath = Convert-ApiPathToRelativePath -ApiPath ([string]$entry.path_display)

            if ($tag -eq 'folder') {
                [void](Ensure-CloudDirectoryRecord -RelativePath $relativePath)
                continue
            }

            if ($tag -ne 'file') { continue }

            $parentPath = Get-ParentRelativePath -RelativePath $relativePath
            if ($null -eq $parentPath) { $parentPath = '.' }
            $directoryRecord = Ensure-CloudDirectoryRecord -RelativePath $parentPath
            $length = Convert-ToInt64 -Value $entry.size
            $extension = [IO.Path]::GetExtension([string]$entry.name)

            $directoryRecord.DirectFileCount++
            $directoryRecord.DirectBytes += $length
            if ($imageExtensions.Contains($extension)) {
                $directoryRecord.DirectImageFileCount++
                $directoryRecord.DirectImageBytes += $length
            }
            if ($videoExtensions.Contains($extension)) {
                $directoryRecord.DirectVideoFileCount++
                $directoryRecord.DirectVideoBytes += $length
            }
            if ($length -ge 100MB) {
                $directoryRecord.DirectLargeFileCount100MB++
                $directoryRecord.DirectLargeFileBytes100MB += $length
            }
        }

        Write-Progress -Activity 'Reading Dropbox metadata' -Status "Pages: $page; entries: $($entryCount.ToString('N0')); folders: $($directories.Count.ToString('N0'))"
        if (-not [bool]$response.has_more) { break }
        $response = Invoke-DropboxMetadataRpc -Operation ListFolderContinue -BearerToken $accessToken -Body @{ cursor = [string]$response.cursor }
    }
    Write-Progress -Activity 'Reading Dropbox metadata' -Completed
}
finally {
    if ($tokenPointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($tokenPointer)
    }
    $accessToken = $null
    $secureToken = $null
    [GC]::Collect()
}

foreach ($record in $directories.Values) {
    if ($record.RelativePath -eq '.') { continue }
    if ($directories.ContainsKey($record.ParentRelativePath)) {
        $directories[$record.ParentRelativePath].DirectChildDirectoryCount++
    }

    $record.RecursiveFileCount = $record.DirectFileCount
    $record.RecursiveBytes = $record.DirectBytes
    $record.RecursiveImageFileCount = $record.DirectImageFileCount
    $record.RecursiveImageBytes = $record.DirectImageBytes
    $record.RecursiveVideoFileCount = $record.DirectVideoFileCount
    $record.RecursiveVideoBytes = $record.DirectVideoBytes
    $record.RecursiveLargeFileCount100MB = $record.DirectLargeFileCount100MB
    $record.RecursiveLargeFileBytes100MB = $record.DirectLargeFileBytes100MB
}

$deepestFirst = @($directories.Values | Sort-Object -Property @{ Expression = 'Depth'; Descending = $true }, RelativePath)
foreach ($record in $deepestFirst) {
    if ($record.RelativePath -eq '.') { continue }
    if (-not $directories.ContainsKey($record.ParentRelativePath)) { continue }

    $parent = $directories[$record.ParentRelativePath]
    $parent.RecursiveDirectoryCount += (1 + $record.RecursiveDirectoryCount)
    $parent.RecursiveFileCount += $record.RecursiveFileCount
    $parent.RecursiveBytes += $record.RecursiveBytes
    $parent.RecursiveImageFileCount += $record.RecursiveImageFileCount
    $parent.RecursiveImageBytes += $record.RecursiveImageBytes
    $parent.RecursiveVideoFileCount += $record.RecursiveVideoFileCount
    $parent.RecursiveVideoBytes += $record.RecursiveVideoBytes
    $parent.RecursiveLargeFileCount100MB += $record.RecursiveLargeFileCount100MB
    $parent.RecursiveLargeFileBytes100MB += $record.RecursiveLargeFileBytes100MB
}

$cloudOrdered = @($directories.Values | Sort-Object RelativePath)
$cloudOrdered | Export-Csv -LiteralPath $cloudCsvPath -NoTypeInformation -Encoding UTF8

$cloudTree = [System.Collections.Generic.List[string]]::new()
$cloudTree.Add("# Dropbox cloud directory tree generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$cloudTree.Add('# Metadata only: no file contents were downloaded.')
$cloudTree.Add('# Format: path | subdirs | files | logical size | images | videos | >=100MB files')
foreach ($record in $cloudOrdered) {
    $indent = '  ' * $record.Depth
    $displayName = if ($record.RelativePath -eq '.') { '[Dropbox cloud root]' } else { Split-Path -Leaf $record.RelativePath }
    $cloudTree.Add(('{0}{1} | dirs={2:N0} | files={3:N0} | size={4} | images={5:N0}/{6} | videos={7:N0}/{8} | >=100MB={9:N0}/{10}' -f
        $indent,
        $displayName,
        $record.RecursiveDirectoryCount,
        $record.RecursiveFileCount,
        (Format-LogicalSize $record.RecursiveBytes),
        $record.RecursiveImageFileCount,
        (Format-LogicalSize $record.RecursiveImageBytes),
        $record.RecursiveVideoFileCount,
        (Format-LogicalSize $record.RecursiveVideoBytes),
        $record.RecursiveLargeFileCount100MB,
        (Format-LogicalSize $record.RecursiveLargeFileBytes100MB)))
}
$cloudTree | Set-Content -LiteralPath $cloudTreePath -Encoding UTF8

Write-Host 'Loading the local directory inventory for comparison.'
$localRows = @(Import-Csv -LiteralPath $LocalDirectoryInventoryCsv)
$localByPath = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $localRows) {
    $localByPath[[string]$row.RelativePath] = $row
}

$allPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($path in $directories.Keys) { [void]$allPaths.Add($path) }
foreach ($path in $localByPath.Keys) { [void]$allPaths.Add($path) }

$comparison = [System.Collections.Generic.List[object]]::new()
foreach ($path in @($allPaths | Sort-Object)) {
    $isCloud = $directories.ContainsKey($path)
    $isLocal = $localByPath.ContainsKey($path)
    $cloud = if ($isCloud) { $directories[$path] } else { $null }
    $local = if ($isLocal) { $localByPath[$path] } else { $null }

    $status = if ($isCloud -and $isLocal) { 'PresentBoth' } elseif ($isCloud) { 'CloudOnly' } else { 'LocalOnly' }
    $recommendation = switch ($status) {
        'CloudOnly' { 'Keep excluded by default until reviewed' }
        'LocalOnly' { 'Preserve locally; investigate before Dropbox relink' }
        default { 'Locally represented; candidate to retain current availability' }
    }

    $cloudBytes = if ($isCloud) { [int64]$cloud.RecursiveBytes } else { [int64]0 }
    $localBytes = if ($isLocal) { Convert-ToInt64 -Value $local.RecursiveBytes } else { [int64]0 }
    $cloudFiles = if ($isCloud) { [int64]$cloud.RecursiveFileCount } else { [int64]0 }
    $localFiles = if ($isLocal) { Convert-ToInt64 -Value $local.RecursiveFileCount } else { [int64]0 }

    $comparison.Add([pscustomobject]@{
        RelativePath = $path
        ParentRelativePath = Get-ParentRelativePath -RelativePath $path
        Depth = Get-Depth -RelativePath $path
        Status = $status
        Recommendation = $recommendation
        CloudDirectoryCount = if ($isCloud) { [int64]$cloud.RecursiveDirectoryCount } else { [int64]0 }
        LocalDirectoryCount = if ($isLocal) { Convert-ToInt64 -Value $local.RecursiveDirectoryCount } else { [int64]0 }
        CloudFileCount = $cloudFiles
        LocalFileCount = $localFiles
        FileCountDeltaCloudMinusLocal = $cloudFiles - $localFiles
        CloudBytes = $cloudBytes
        LocalBytes = $localBytes
        ByteDeltaCloudMinusLocal = $cloudBytes - $localBytes
        CloudVideoFileCount = if ($isCloud) { [int64]$cloud.RecursiveVideoFileCount } else { [int64]0 }
        LocalVideoFileCount = if ($isLocal) { Convert-ToInt64 -Value $local.RecursiveVideoFileCount } else { [int64]0 }
        CloudImageFileCount = if ($isCloud) { [int64]$cloud.RecursiveImageFileCount } else { [int64]0 }
        LocalImageFileCount = if ($isLocal) { Convert-ToInt64 -Value $local.RecursiveImageFileCount } else { [int64]0 }
        LocalDirectoryIsUnpinned = if ($isLocal) { Convert-ToBoolean -Value $local.DirectoryIsUnpinned } else { $false }
        LocalDirectoryIsPinned = if ($isLocal) { Convert-ToBoolean -Value $local.DirectoryIsPinned } else { $false }
    })
}
$comparison | Export-Csv -LiteralPath $comparisonCsvPath -NoTypeInformation -Encoding UTF8

$cloudOnlySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($row in $comparison) {
    if ($row.Status -eq 'CloudOnly') { [void]$cloudOnlySet.Add($row.RelativePath) }
}

$candidates = @($comparison | Where-Object {
    if ($_.Status -ne 'CloudOnly') { return $false }
    $parent = $_.ParentRelativePath
    return ($null -eq $parent -or -not $cloudOnlySet.Contains($parent))
} | Sort-Object RelativePath)
$candidates | Export-Csv -LiteralPath $candidateCsvPath -NoTypeInformation -Encoding UTF8

$photosComparison = @($comparison | Where-Object {
    $_.RelativePath -eq 'Photos' -or $_.RelativePath.StartsWith('Photos\', [System.StringComparison]::OrdinalIgnoreCase)
} | Sort-Object RelativePath)
$photosComparison | Export-Csv -LiteralPath $photosComparisonCsvPath -NoTypeInformation -Encoding UTF8

$cloudRoot = $directories['.']
$localRoot = $localByPath['.']
$cloudOnly = @($comparison | Where-Object { $_.Status -eq 'CloudOnly' })
$localOnly = @($comparison | Where-Object { $_.Status -eq 'LocalOnly' })
$photosCandidates = @($candidates | Where-Object {
    $_.RelativePath -eq 'Photos' -or $_.RelativePath.StartsWith('Photos\', [System.StringComparison]::OrdinalIgnoreCase)
})

$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('# Dropbox cloud-versus-local directory comparison')
$summary.Add('')
$summary.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$summary.Add('')
$summary.Add('The cloud inventory was obtained through Dropbox metadata-only listing endpoints. No file content was downloaded, and the script contains no write, upload, move, rename, or delete calls.')
$summary.Add('')
$summary.Add('## Totals')
$summary.Add('')
$summary.Add("- Cloud directories: $($directories.Count.ToString('N0'))")
$summary.Add("- Local directories: $($localByPath.Count.ToString('N0'))")
$summary.Add("- Cloud files: $($cloudRoot.RecursiveFileCount.ToString('N0'))")
$summary.Add("- Local files: $((Convert-ToInt64 -Value $localRoot.RecursiveFileCount).ToString('N0'))")
$summary.Add("- Cloud logical size: $(Format-LogicalSize $cloudRoot.RecursiveBytes)")
$summary.Add("- Local logical size: $(Format-LogicalSize (Convert-ToInt64 -Value $localRoot.RecursiveBytes))")
$summary.Add("- Cloud-only directories: $($cloudOnly.Count.ToString('N0'))")
$summary.Add("- Local-only directories: $($localOnly.Count.ToString('N0'))")
$summary.Add("- Topmost cloud-only branches: $($candidates.Count.ToString('N0'))")
$summary.Add('')
$summary.Add('## Interpretation')
$summary.Add('')
$summary.Add('Topmost cloud-only branches are the conservative selective-sync exclusion candidates. They include folders that were previously excluded as well as folders created online since this computer last represented the full tree. Keep them excluded by default until individually reviewed.')
$summary.Add('')
$summary.Add('Local-only folders may contain work that never reached Dropbox. Preserve them and investigate before allowing Dropbox to reconcile the folder.')
$summary.Add('')
$summary.Add('## Topmost cloud-only branches')
$summary.Add('')
$summary.Add('| Path | Cloud directories | Cloud files | Cloud size | Videos | Images |')
$summary.Add('|---|---:|---:|---:|---:|---:|')
foreach ($row in $candidates) {
    $summary.Add("| $($row.RelativePath.Replace('|','\|')) | $($row.CloudDirectoryCount.ToString('N0')) | $($row.CloudFileCount.ToString('N0')) | $(Format-LogicalSize $row.CloudBytes) | $($row.CloudVideoFileCount.ToString('N0')) | $($row.CloudImageFileCount.ToString('N0')) |")
}

$summary.Add('')
$summary.Add('## Photos cloud-only branch candidates')
$summary.Add('')
if ($photosCandidates.Count -eq 0) {
    $summary.Add('No topmost cloud-only branches were found under `Photos`.')
}
else {
    $summary.Add('| Path | Cloud directories | Cloud files | Cloud size | Videos | Images |')
    $summary.Add('|---|---:|---:|---:|---:|---:|')
    foreach ($row in $photosCandidates) {
        $summary.Add("| $($row.RelativePath.Replace('|','\|')) | $($row.CloudDirectoryCount.ToString('N0')) | $($row.CloudFileCount.ToString('N0')) | $(Format-LogicalSize $row.CloudBytes) | $($row.CloudVideoFileCount.ToString('N0')) | $($row.CloudImageFileCount.ToString('N0')) |")
    }
}

$summary.Add('')
$summary.Add('## Output files')
$summary.Add('')
$summary.Add(('- Full cloud directory CSV: `{0}`' -f $cloudCsvPath))
$summary.Add(('- Full readable cloud tree: `{0}`' -f $cloudTreePath))
$summary.Add(('- Full cloud-versus-local comparison: `{0}`' -f $comparisonCsvPath))
$summary.Add(('- Topmost exclusion candidates: `{0}`' -f $candidateCsvPath))
$summary.Add(('- Complete Photos comparison: `{0}`' -f $photosComparisonCsvPath))
$summary | Set-Content -LiteralPath $summaryPath -Encoding UTF8

Write-Host ''
Write-Host 'Cloud metadata inventory and comparison completed.' -ForegroundColor Green
Write-Host "Summary: $summaryPath"
Write-Host "Topmost exclusion candidates: $candidateCsvPath"
Write-Host "Photos comparison: $photosComparisonCsvPath"

[pscustomobject]@{
    CloudDirectoryCount = $directories.Count
    CloudFileCount = $cloudRoot.RecursiveFileCount
    CloudBytes = $cloudRoot.RecursiveBytes
    LocalDirectoryCount = $localByPath.Count
    CloudOnlyDirectoryCount = $cloudOnly.Count
    LocalOnlyDirectoryCount = $localOnly.Count
    TopmostCloudOnlyCandidateCount = $candidates.Count
    PhotosTopmostCloudOnlyCandidateCount = $photosCandidates.Count
    SummaryPath = $summaryPath
    CloudTreePath = $cloudTreePath
    ComparisonCsvPath = $comparisonCsvPath
    CandidateCsvPath = $candidateCsvPath
    PhotosComparisonCsvPath = $photosComparisonCsvPath
}
