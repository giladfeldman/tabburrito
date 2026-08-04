[CmdletBinding()]
param(
    [string]$DropboxRoot = (Join-Path $HOME 'Dropbox'),
    [string]$OutputDirectory = (Join-Path $(if ($env:VIBE_ROOT) { $env:VIBE_ROOT } else { Join-Path $HOME 'Vibe' }) 'WindowsTuneUp\recovery-manifests')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $DropboxRoot -PathType Container)) {
    throw "Dropbox root was not found: $DropboxRoot"
}

if (-not (Test-Path -LiteralPath $OutputDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$DropboxRoot = (Get-Item -LiteralPath $DropboxRoot -Force).FullName.TrimEnd('\')
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmmss'

$allCsvPath = Join-Path $OutputDirectory "Dropbox-local-directory-tree_$stamp.csv"
$allTextPath = Join-Path $OutputDirectory "Dropbox-local-directory-tree_$stamp.txt"
$photosCsvPath = Join-Path $OutputDirectory "Dropbox-Photos-local-directory-tree_$stamp.csv"
$photosTextPath = Join-Path $OutputDirectory "Dropbox-Photos-local-directory-tree_$stamp.txt"
$summaryPath = Join-Path $OutputDirectory "Dropbox-local-directory-tree-summary_$stamp.md"
$errorsPath = Join-Path $OutputDirectory "Dropbox-local-directory-tree-errors_$stamp.csv"

$imageExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@('.jpg', '.jpeg', '.png', '.gif', '.bmp', '.tif', '.tiff', '.heic', '.heif', '.webp', '.raw', '.dng', '.cr2', '.cr3', '.nef', '.arw', '.orf', '.rw2', '.svg') |
    ForEach-Object { [void]$imageExtensions.Add($_) }

$videoExtensions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
@('.mp4', '.mov', '.m4v', '.avi', '.mkv', '.wmv', '.webm', '.mts', '.m2ts', '.3gp', '.mpg', '.mpeg', '.vob', '.flv') |
    ForEach-Object { [void]$videoExtensions.Add($_) }

$offlineFlag = [int64]0x1000
$pinnedFlag = [int64]0x80000
$unpinnedFlag = [int64]0x100000
$recallOnOpenFlag = [int64]0x40000
$recallOnDataAccessFlag = [int64]0x400000
$reparsePointFlag = [int64][System.IO.FileAttributes]::ReparsePoint

function Get-RelativePath {
    param([string]$FullName)

    if ($FullName.Equals($DropboxRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        return '.'
    }
    return $FullName.Substring($DropboxRoot.Length).TrimStart('\')
}

function Get-Depth {
    param([string]$RelativePath)

    if ($RelativePath -eq '.') { return 0 }
    return ($RelativePath -split '\\').Count
}

function Get-ParentRelativePath {
    param([string]$RelativePath)

    if ($RelativePath -eq '.') { return $null }
    $index = $RelativePath.LastIndexOf('\')
    if ($index -lt 0) { return '.' }
    return $RelativePath.Substring(0, $index)
}

function Format-LogicalSize {
    param([double]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Test-CloudPlaceholderAttribute {
    param([int64]$AttributeNumber)

    return (($AttributeNumber -band $offlineFlag) -ne 0 -or
            ($AttributeNumber -band $recallOnOpenFlag) -ne 0 -or
            ($AttributeNumber -band $recallOnDataAccessFlag) -ne 0)
}

$records = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
$errors = [System.Collections.Generic.List[object]]::new()
$stack = [System.Collections.Generic.Stack[System.IO.DirectoryInfo]]::new()
$stack.Push((Get-Item -LiteralPath $DropboxRoot -Force))

while ($stack.Count -gt 0) {
    $directory = $stack.Pop()
    $relativePath = Get-RelativePath -FullName $directory.FullName
    $depth = Get-Depth -RelativePath $relativePath
    $attributeNumber = [int64]$directory.Attributes
    $linkType = ''
    $linkTarget = ''

    if (($attributeNumber -band $reparsePointFlag) -ne 0) {
        try {
            $adaptedItem = Get-Item -LiteralPath $directory.FullName -Force -ErrorAction Stop
            $linkType = [string]$adaptedItem.LinkType
            $linkTarget = [string]($adaptedItem.Target -join ';')
        }
        catch {
            $errors.Add([pscustomobject]@{
                Path = $directory.FullName
                Operation = 'InspectReparsePoint'
                Error = $_.Exception.Message
            })
        }
    }

    $skipTraversal = -not [string]::IsNullOrWhiteSpace($linkType)
    $directFileCount = [int64]0
    $directBytes = [int64]0
    $directImageFileCount = [int64]0
    $directImageBytes = [int64]0
    $directVideoFileCount = [int64]0
    $directVideoBytes = [int64]0
    $directLargeFileCount = [int64]0
    $directLargeFileBytes = [int64]0
    $directCloudPlaceholderFileCount = [int64]0
    $directPinnedFileCount = [int64]0
    $directUnpinnedFileCount = [int64]0
    $directChildDirectoryCount = [int64]0

    if (-not $skipTraversal) {
        try {
            $entries = $directory.GetFileSystemInfos()
            foreach ($entry in $entries) {
                if (($entry.Attributes -band [System.IO.FileAttributes]::Directory) -ne 0) {
                    $directChildDirectoryCount++
                    $stack.Push([System.IO.DirectoryInfo]$entry)
                    continue
                }

                $file = [System.IO.FileInfo]$entry
                $length = [int64]0
                try { $length = [int64]$file.Length }
                catch {
                    $errors.Add([pscustomobject]@{
                        Path = $file.FullName
                        Operation = 'ReadFileLength'
                        Error = $_.Exception.Message
                    })
                }

                $directFileCount++
                $directBytes += $length
                $fileAttributeNumber = [int64]$file.Attributes

                if ($imageExtensions.Contains($file.Extension)) {
                    $directImageFileCount++
                    $directImageBytes += $length
                }
                if ($videoExtensions.Contains($file.Extension)) {
                    $directVideoFileCount++
                    $directVideoBytes += $length
                }
                if ($length -ge 100MB) {
                    $directLargeFileCount++
                    $directLargeFileBytes += $length
                }
                if (Test-CloudPlaceholderAttribute -AttributeNumber $fileAttributeNumber) {
                    $directCloudPlaceholderFileCount++
                }
                if (($fileAttributeNumber -band $pinnedFlag) -ne 0) { $directPinnedFileCount++ }
                if (($fileAttributeNumber -band $unpinnedFlag) -ne 0) { $directUnpinnedFileCount++ }
            }
        }
        catch {
            $errors.Add([pscustomobject]@{
                Path = $directory.FullName
                Operation = 'EnumerateDirectory'
                Error = $_.Exception.Message
            })
        }
    }

    $record = [pscustomobject]@{
        RelativePath = $relativePath
        FullPath = $directory.FullName
        Depth = [int]$depth
        ParentRelativePath = Get-ParentRelativePath -RelativePath $relativePath
        DirectChildDirectoryCount = $directChildDirectoryCount
        DirectFileCount = $directFileCount
        DirectBytes = $directBytes
        DirectImageFileCount = $directImageFileCount
        DirectImageBytes = $directImageBytes
        DirectVideoFileCount = $directVideoFileCount
        DirectVideoBytes = $directVideoBytes
        DirectLargeFileCount100MB = $directLargeFileCount
        DirectLargeFileBytes100MB = $directLargeFileBytes
        DirectCloudPlaceholderFileCount = $directCloudPlaceholderFileCount
        DirectPinnedFileCount = $directPinnedFileCount
        DirectUnpinnedFileCount = $directUnpinnedFileCount
        RecursiveDirectoryCount = [int64]0
        RecursiveFileCount = $directFileCount
        RecursiveBytes = $directBytes
        RecursiveImageFileCount = $directImageFileCount
        RecursiveImageBytes = $directImageBytes
        RecursiveVideoFileCount = $directVideoFileCount
        RecursiveVideoBytes = $directVideoBytes
        RecursiveLargeFileCount100MB = $directLargeFileCount
        RecursiveLargeFileBytes100MB = $directLargeFileBytes
        RecursiveCloudPlaceholderFileCount = $directCloudPlaceholderFileCount
        RecursivePinnedFileCount = $directPinnedFileCount
        RecursiveUnpinnedFileCount = $directUnpinnedFileCount
        DirectoryAttributes = $directory.Attributes.ToString()
        DirectoryAttributeNumber = $attributeNumber
        DirectoryIsCloudPlaceholder = (Test-CloudPlaceholderAttribute -AttributeNumber $attributeNumber)
        DirectoryIsPinned = (($attributeNumber -band $pinnedFlag) -ne 0)
        DirectoryIsUnpinned = (($attributeNumber -band $unpinnedFlag) -ne 0)
        LinkType = $linkType
        LinkTarget = $linkTarget
        TraversalSkipped = $skipTraversal
        LastWriteTime = $directory.LastWriteTime.ToString('o')
    }

    $records[$relativePath] = $record
}

$deepestFirst = @($records.Values | Sort-Object -Property @{ Expression = 'Depth'; Descending = $true }, RelativePath)
foreach ($record in $deepestFirst) {
    if ($record.RelativePath -eq '.') { continue }
    if (-not $records.ContainsKey($record.ParentRelativePath)) { continue }

    $parent = $records[$record.ParentRelativePath]
    $parent.RecursiveDirectoryCount += (1 + $record.RecursiveDirectoryCount)
    $parent.RecursiveFileCount += $record.RecursiveFileCount
    $parent.RecursiveBytes += $record.RecursiveBytes
    $parent.RecursiveImageFileCount += $record.RecursiveImageFileCount
    $parent.RecursiveImageBytes += $record.RecursiveImageBytes
    $parent.RecursiveVideoFileCount += $record.RecursiveVideoFileCount
    $parent.RecursiveVideoBytes += $record.RecursiveVideoBytes
    $parent.RecursiveLargeFileCount100MB += $record.RecursiveLargeFileCount100MB
    $parent.RecursiveLargeFileBytes100MB += $record.RecursiveLargeFileBytes100MB
    $parent.RecursiveCloudPlaceholderFileCount += $record.RecursiveCloudPlaceholderFileCount
    $parent.RecursivePinnedFileCount += $record.RecursivePinnedFileCount
    $parent.RecursiveUnpinnedFileCount += $record.RecursiveUnpinnedFileCount
}

$ordered = @($records.Values | Sort-Object RelativePath)
$ordered | Export-Csv -LiteralPath $allCsvPath -NoTypeInformation -Encoding UTF8

$treeLines = [System.Collections.Generic.List[string]]::new()
$treeLines.Add("# Local Dropbox directory tree generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$treeLines.Add("# Root: $DropboxRoot")
$treeLines.Add('# Logical sizes use file metadata. This scan did not open file contents or download online-only files.')
$treeLines.Add('# Format: path | subdirs | files | logical size | images | videos | >=100MB files | cloud-placeholder files')
foreach ($record in $ordered) {
    $indent = '  ' * $record.Depth
    $displayName = if ($record.RelativePath -eq '.') { '[Dropbox root]' } else { Split-Path -Leaf $record.RelativePath }
    $treeLines.Add(('{0}{1} | dirs={2:N0} | files={3:N0} | size={4} | images={5:N0}/{6} | videos={7:N0}/{8} | >=100MB={9:N0}/{10} | cloud-placeholder-files={11:N0}' -f
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
        (Format-LogicalSize $record.RecursiveLargeFileBytes100MB),
        $record.RecursiveCloudPlaceholderFileCount))
}
$treeLines | Set-Content -LiteralPath $allTextPath -Encoding UTF8

$photos = @($ordered | Where-Object { $_.RelativePath -eq 'Photos' -or $_.RelativePath.StartsWith('Photos\', [System.StringComparison]::OrdinalIgnoreCase) })
$photos | Export-Csv -LiteralPath $photosCsvPath -NoTypeInformation -Encoding UTF8

$photosTreeLines = [System.Collections.Generic.List[string]]::new()
$photosTreeLines.Add("# Local Dropbox Photos directory tree generated $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$photosTreeLines.Add('# Every locally present Photos directory is listed. Recursive counts/sizes include all descendants.')
$photosTreeLines.Add('# This cannot list cloud folders that selective sync had removed from this computer; those require a cloud-side inventory.')
foreach ($record in $photos) {
    $photoDepth = [Math]::Max(0, $record.Depth - 1)
    $indent = '  ' * $photoDepth
    $displayName = if ($record.RelativePath -eq 'Photos') { '[Photos]' } else { Split-Path -Leaf $record.RelativePath }
    $photosTreeLines.Add(('{0}{1} | files={2:N0} | size={3} | images={4:N0}/{5} | videos={6:N0}/{7} | >=100MB={8:N0}/{9} | cloud-placeholder-files={10:N0}' -f
        $indent,
        $displayName,
        $record.RecursiveFileCount,
        (Format-LogicalSize $record.RecursiveBytes),
        $record.RecursiveImageFileCount,
        (Format-LogicalSize $record.RecursiveImageBytes),
        $record.RecursiveVideoFileCount,
        (Format-LogicalSize $record.RecursiveVideoBytes),
        $record.RecursiveLargeFileCount100MB,
        (Format-LogicalSize $record.RecursiveLargeFileBytes100MB),
        $record.RecursiveCloudPlaceholderFileCount))
}
$photosTreeLines | Set-Content -LiteralPath $photosTextPath -Encoding UTF8

$rootRecord = $records['.']
$photosRecord = if ($records.ContainsKey('Photos')) { $records['Photos'] } else { $null }
$topLevel = @($ordered | Where-Object { $_.Depth -eq 1 } | Sort-Object RelativePath)
$photoFirstLevel = @($photos | Where-Object { $_.Depth -eq 2 } | Sort-Object RelativePath)
$largestPhotoBranches = @($photos | Where-Object { $_.RelativePath -ne 'Photos' } | Sort-Object RecursiveBytes -Descending | Select-Object -First 100)

$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add('# Local Dropbox directory inventory')
$summary.Add('')
$summary.Add("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')")
$summary.Add('')
$summary.Add(('Root: `{0}`' -f $DropboxRoot))
$summary.Add('')
$summary.Add('## Whole local Dropbox tree')
$summary.Add('')
$summary.Add("- Directories: $($records.Count.ToString('N0'))")
$summary.Add("- Files: $($rootRecord.RecursiveFileCount.ToString('N0'))")
$summary.Add("- Logical size: $(Format-LogicalSize $rootRecord.RecursiveBytes)")
$summary.Add("- Image files: $($rootRecord.RecursiveImageFileCount.ToString('N0')) ($(Format-LogicalSize $rootRecord.RecursiveImageBytes))")
$summary.Add("- Video files: $($rootRecord.RecursiveVideoFileCount.ToString('N0')) ($(Format-LogicalSize $rootRecord.RecursiveVideoBytes))")
$summary.Add("- Files at least 100 MB: $($rootRecord.RecursiveLargeFileCount100MB.ToString('N0')) ($(Format-LogicalSize $rootRecord.RecursiveLargeFileBytes100MB))")
$summary.Add("- Files marked with online-only/recall attributes: $($rootRecord.RecursiveCloudPlaceholderFileCount.ToString('N0'))")
$summary.Add('')
$summary.Add('## Important limitation')
$summary.Add('')
$summary.Add('This records every directory that exists locally. A folder that the old selective-sync configuration excluded entirely is absent locally, so its name cannot be recovered from this scan alone. Exact reconstruction requires comparing this inventory with a metadata-only tree from Dropbox cloud before enabling bulk sync.')
$summary.Add('')
$summary.Add('## Top-level local branches')
$summary.Add('')
$summary.Add('| Folder | Directories | Files | Logical size | Images | Videos | >=100 MB | Cloud placeholders |')
$summary.Add('|---|---:|---:|---:|---:|---:|---:|---:|')
foreach ($record in $topLevel) {
    $summary.Add("| $($record.RelativePath.Replace('|','\|')) | $($record.RecursiveDirectoryCount.ToString('N0')) | $($record.RecursiveFileCount.ToString('N0')) | $(Format-LogicalSize $record.RecursiveBytes) | $($record.RecursiveImageFileCount.ToString('N0')) | $($record.RecursiveVideoFileCount.ToString('N0')) | $($record.RecursiveLargeFileCount100MB.ToString('N0')) | $($record.RecursiveCloudPlaceholderFileCount.ToString('N0')) |")
}

$summary.Add('')
$summary.Add('## Photos')
$summary.Add('')
if ($null -eq $photosRecord) {
    $summary.Add('`Photos` is not present locally.')
}
else {
    $summary.Add("- Directories: $((1 + $photosRecord.RecursiveDirectoryCount).ToString('N0'))")
    $summary.Add("- Files: $($photosRecord.RecursiveFileCount.ToString('N0'))")
    $summary.Add("- Logical size: $(Format-LogicalSize $photosRecord.RecursiveBytes)")
    $summary.Add("- Images: $($photosRecord.RecursiveImageFileCount.ToString('N0')) ($(Format-LogicalSize $photosRecord.RecursiveImageBytes))")
    $summary.Add("- Videos: $($photosRecord.RecursiveVideoFileCount.ToString('N0')) ($(Format-LogicalSize $photosRecord.RecursiveVideoBytes))")
    $summary.Add("- Files at least 100 MB: $($photosRecord.RecursiveLargeFileCount100MB.ToString('N0')) ($(Format-LogicalSize $photosRecord.RecursiveLargeFileBytes100MB))")
    $summary.Add('')
    $summary.Add('### First-level Photos branches')
    $summary.Add('')
    $summary.Add('| Folder | Directories | Files | Logical size | Images | Videos | >=100 MB | Cloud placeholders |')
    $summary.Add('|---|---:|---:|---:|---:|---:|---:|---:|')
    foreach ($record in $photoFirstLevel) {
        $leaf = Split-Path -Leaf $record.RelativePath
        $summary.Add("| $($leaf.Replace('|','\|')) | $($record.RecursiveDirectoryCount.ToString('N0')) | $($record.RecursiveFileCount.ToString('N0')) | $(Format-LogicalSize $record.RecursiveBytes) | $($record.RecursiveImageFileCount.ToString('N0')) | $($record.RecursiveVideoFileCount.ToString('N0')) | $($record.RecursiveLargeFileCount100MB.ToString('N0')) | $($record.RecursiveCloudPlaceholderFileCount.ToString('N0')) |")
    }
    $summary.Add('')
    $summary.Add('### 100 largest locally present Photos directories')
    $summary.Add('')
    $summary.Add('| Path | Files | Logical size | Images | Videos | >=100 MB |')
    $summary.Add('|---|---:|---:|---:|---:|---:|')
    foreach ($record in $largestPhotoBranches) {
        $summary.Add("| $($record.RelativePath.Replace('|','\|')) | $($record.RecursiveFileCount.ToString('N0')) | $(Format-LogicalSize $record.RecursiveBytes) | $($record.RecursiveImageFileCount.ToString('N0')) | $($record.RecursiveVideoFileCount.ToString('N0')) | $($record.RecursiveLargeFileCount100MB.ToString('N0')) |")
    }
}

$summary.Add('')
$summary.Add('## Output files')
$summary.Add('')
$summary.Add(('- Full directory CSV: `{0}`' -f $allCsvPath))
$summary.Add(('- Full readable tree: `{0}`' -f $allTextPath))
$summary.Add(('- Photos directory CSV: `{0}`' -f $photosCsvPath))
$summary.Add(('- Photos readable tree: `{0}`' -f $photosTextPath))
if ($errors.Count -gt 0) {
    $summary.Add(('- Enumeration errors: `{0}`' -f $errorsPath))
}
$summary | Set-Content -LiteralPath $summaryPath -Encoding UTF8

if ($errors.Count -gt 0) {
    $errors | Export-Csv -LiteralPath $errorsPath -NoTypeInformation -Encoding UTF8
}

[pscustomobject]@{
    GeneratedAt = (Get-Date).ToString('o')
    DropboxRoot = $DropboxRoot
    DirectoryCount = $records.Count
    FileCount = $rootRecord.RecursiveFileCount
    LogicalBytes = $rootRecord.RecursiveBytes
    PhotosDirectoryCount = if ($null -ne $photosRecord) { 1 + $photosRecord.RecursiveDirectoryCount } else { 0 }
    PhotosFileCount = if ($null -ne $photosRecord) { $photosRecord.RecursiveFileCount } else { 0 }
    PhotosLogicalBytes = if ($null -ne $photosRecord) { $photosRecord.RecursiveBytes } else { 0 }
    ErrorCount = $errors.Count
    SummaryPath = $summaryPath
    FullCsvPath = $allCsvPath
    FullTreePath = $allTextPath
    PhotosCsvPath = $photosCsvPath
    PhotosTreePath = $photosTextPath
    ErrorsPath = if ($errors.Count -gt 0) { $errorsPath } else { '' }
}
