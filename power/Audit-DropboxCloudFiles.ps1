[CmdletBinding()]
param(
    [ValidateRange(1, 1048576)]
    [int]$LargeThresholdMiB = 100,

    [string]$Database,

    [string]$VideoExtensions,

    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

$vibeRoot = if ($env:VIBE_ROOT) {
    $env:VIBE_ROOT
} else {
    Join-Path $HOME 'Vibe'
}

if (-not (Test-Path -LiteralPath $vibeRoot -PathType Container)) {
    throw "Vibe root does not exist: $vibeRoot. Set VIBE_ROOT to the correct location."
}

$scriptPath = Join-Path $vibeRoot 'WindowsTuneUp\power\Audit-DropboxCloudFiles.py'
$outputDirectory = Join-Path $vibeRoot 'WindowsTuneUp\recovery-manifests'
$bundledPython = Join-Path $HOME '.cache\codex-runtimes\codex-primary-runtime\dependencies\python\python.exe'

if (-not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) {
    throw "Audit program not found: $scriptPath"
}

$python = if (Test-Path -LiteralPath $bundledPython -PathType Leaf) {
    $bundledPython
} else {
    $command = Get-Command python -ErrorAction Stop
    $command.Source
}

$arguments = @(
    $scriptPath
)

if ($SelfTest) {
    $arguments += '--self-test'
} else {
    $arguments += @(
        '--output-directory'
        $outputDirectory
        '--large-threshold-mib'
        $LargeThresholdMiB
    )
}

if (-not $SelfTest -and $Database) {
    $arguments += @('--database', $Database)
}

if (-not $SelfTest -and $VideoExtensions) {
    $arguments += @('--video-extensions', $VideoExtensions)
}

if (-not $SelfTest) {
    Write-Host 'Dropbox audit safety boundary:' -ForegroundColor Cyan
    Write-Host '  - Metadata only; file contents are not downloaded.'
    Write-Host '  - The program contains no upload, move, rename, or delete operation.'
    Write-Host '  - Use a temporary app token with ONLY files.metadata.read.'
    Write-Host "  - Large-file threshold: $LargeThresholdMiB MiB."
    Write-Host ''
}

& $python @arguments
exit $LASTEXITCODE
