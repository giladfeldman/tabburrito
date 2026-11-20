<#
.SYNOPSIS
    Builds, signs and (with -Publish) publishes a Tabburrito release to GitHub.

.DESCRIPTION
    Everything runs on this machine. No GitHub Actions are involved.

      1. Reads the version from src-tauri\tauri.conf.json and refuses to go on
         if src-tauri\Cargo.toml or package.json disagree.
      2. Builds the per-user NSIS installer with `npx tauri build`. The Tauri CLI
         signs the installer with the updater's private minisign key
         (default %USERPROFILE%\.tauri\tabburrito-updater.key, outside the repo)
         and writes <installer>.sig next to it.
      3. Copies the installer and its .sig into the output folder and writes
         latest.json, the file every installed copy reads to find updates.
      4. With -Publish only: checks that the release commit is on origin/main
         and that the tag does not exist yet, then uploads the three files with
         `gh release create` and reads latest.json back from the public URL.

    Without -Publish nothing leaves this machine (a dry run that still builds
    and signs everything).

    The private key has no password, so a build needs no prompt. Anyone who
    holds that file can sign an update every installed Tabburrito will accept;
    keep it out of the repo and keep a backup (install\README.md).

.PARAMETER Publish
    Upload the release to GitHub. Without it the script stops after building.

.PARAMETER Notes
    Release notes (shown on GitHub and stored in latest.json).

.PARAMETER KeyPath
    Private updater key. Default: %USERPROFILE%\.tauri\tabburrito-updater.key

.PARAMETER OutDir
    Where the installer, .sig and latest.json are collected.
    Default: tmp\release\v<version> in the repo (gitignored).

.PARAMETER ConfigOverride
    TESTS ONLY. A JSON file merged over tauri.conf.json (`tauri build --config`).
    The end-to-end test uses it for a separate product name, a test key and a
    local endpoint. Refused together with -Publish.

.PARAMETER VersionOverride
    TESTS ONLY. Build this version instead of the one in tauri.conf.json.
    Refused together with -Publish.

.PARAMETER BaseUrl
    Download folder written into latest.json. Default: the GitHub release
    download URL for this version.

.PARAMETER CargoTargetDir
    Cargo build folder. Default: %LOCALAPPDATA%\TabburritoBuild\cargo-target.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Publish-TabburritoRelease.ps1
    powershell -ExecutionPolicy Bypass -File .\install\Publish-TabburritoRelease.ps1 -Publish -Notes "Fixes X."
#>
[CmdletBinding()]
param(
    [switch]$Publish,
    [string]$Notes = '',
    [string]$KeyPath = (Join-Path $env:USERPROFILE '.tauri\tabburrito-updater.key'),
    [string]$OutDir = '',
    [string]$ConfigOverride = '',
    [string]$VersionOverride = '',
    [string]$BaseUrl = '',
    [string]$CargoTargetDir = (Join-Path $env:LOCALAPPDATA 'TabburritoBuild\cargo-target')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Repo     = 'giladfeldman/tabburrito'
$RepoRoot = Split-Path -Parent $PSScriptRoot
$TauriDir = Join-Path $RepoRoot 'src-tauri'

function Fail([string]$msg) {
    Write-Host "FAILED: $msg" -ForegroundColor Red
    exit 1
}

# Runs a native command with stderr allowed. In Windows PowerShell 5.1, with
# $ErrorActionPreference = 'Stop', a single stderr line from a native exe (cargo
# and the Tauri CLI print progress there) becomes a terminating error even when
# the exe succeeds. Relax the preference for the call only; judge by exit code.
function Invoke-Native([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

# The Tauri CLI runs `cargo`; a shell started without the user's profile
# (a scheduled task, a queue runner) may not have Rust on PATH.
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (Test-Path -LiteralPath (Join-Path $cargoBin 'cargo.exe')) { $env:PATH = "$cargoBin;$env:PATH" }
    else { Fail 'cargo not found. Install Rust (https://rustup.rs) to build a release.' }
}

if ($Publish -and ($ConfigOverride -or $VersionOverride)) {
    Fail '-ConfigOverride / -VersionOverride are for tests and cannot be published.'
}

# --- 1. Version ---------------------------------------------------------------
$conf = Get-Content -Raw -LiteralPath (Join-Path $TauriDir 'tauri.conf.json') | ConvertFrom-Json
$version = $conf.version
$cargoVersion = (Select-String -LiteralPath (Join-Path $TauriDir 'Cargo.toml') -Pattern '^version\s*=\s*"([^"]+)"' |
    Select-Object -First 1).Matches[0].Groups[1].Value
$pkgVersion = (Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'package.json') | ConvertFrom-Json).version
if ($cargoVersion -ne $version -or $pkgVersion -ne $version) {
    Fail "Version mismatch: tauri.conf.json $version, Cargo.toml $cargoVersion, package.json $pkgVersion. Set all three to the same version."
}
if ($VersionOverride) { $version = $VersionOverride }
if ($version -notmatch '^\d+\.\d+\.\d+$') { Fail "Version '$version' is not MAJOR.MINOR.PATCH." }
$tag = "v$version"
Write-Host "Tabburrito $version" -ForegroundColor Cyan

if (-not $OutDir)  { $OutDir  = Join-Path $RepoRoot "tmp\release\$tag" }
if (-not $BaseUrl) { $BaseUrl = "https://github.com/$Repo/releases/download/$tag" }

# --- 2. Publish pre-checks (before the slow build) -------------------------
$headSha = (& git -C $RepoRoot rev-parse HEAD).Trim()
if ($Publish) {
    # Everything that goes into the build must be committed, so the tag points
    # at exactly the code in the installer. Unrelated files elsewhere may stay.
    $buildInputs = @('src-tauri', 'ui', 'package.json', 'package-lock.json')
    $dirty = & git -C $RepoRoot status --porcelain -- @buildInputs
    if ($dirty) { Fail "Uncommitted changes in build inputs:`n$($dirty -join "`n")" }

    Invoke-Native { git -C $RepoRoot fetch --quiet origin } | Out-Null
    & git -C $RepoRoot merge-base --is-ancestor $headSha origin/main
    if ($LASTEXITCODE -ne 0) { Fail "HEAD $($headSha.Substring(0,7)) is not on origin/main. Push first (through /ship)." }

    Invoke-Native { gh release view $tag --repo $Repo } | Out-Null
    if ($LASTEXITCODE -eq 0) { Fail "Release $tag already exists on GitHub. Bump the version." }
}

# --- 3. Build and sign ---------------------------------------------------
if (-not (Test-Path -LiteralPath $KeyPath)) {
    Fail "Updater private key not found: $KeyPath (install\README.md, 'Signing key')."
}

$nsisDir = Join-Path $CargoTargetDir 'release\bundle\nsis'
if (Test-Path -LiteralPath $nsisDir) { Remove-Item -LiteralPath $nsisDir -Recurse -Force }

$cliArgs = @('tauri', 'build', '--bundles', 'nsis')
$mergedConfig = $null
if ($ConfigOverride -or $VersionOverride) {
    $override = if ($ConfigOverride) { Get-Content -Raw -LiteralPath $ConfigOverride | ConvertFrom-Json } else { New-Object psobject }
    if ($VersionOverride) { $override | Add-Member -NotePropertyName version -NotePropertyValue $VersionOverride -Force }
    $mergedConfig = Join-Path $env:TEMP "tabburrito-build-override-$PID.json"
    Write-Utf8NoBom $mergedConfig ($override | ConvertTo-Json -Depth 20)
    $cliArgs += @('--config', $mergedConfig)
}

$saved = @{}
foreach ($name in 'TAURI_SIGNING_PRIVATE_KEY', 'TAURI_SIGNING_PRIVATE_KEY_PASSWORD', 'CARGO_TARGET_DIR', 'CI') {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $env:TAURI_SIGNING_PRIVATE_KEY = (Get-Content -Raw -LiteralPath $KeyPath).Trim()
    # The key has no password. Setting an empty variable removes it in
    # PowerShell, so CI=true is what stops the CLI from prompting for one.
    $env:CI = 'true'
    $env:CARGO_TARGET_DIR = $CargoTargetDir
    Write-Host "Building (cargo target: $CargoTargetDir)..." -ForegroundColor Cyan
    Push-Location $RepoRoot
    try {
        $buildLog = Invoke-Native { npx.cmd @cliArgs }
        $buildExit = $LASTEXITCODE
    } finally { Pop-Location }
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    if ($mergedConfig) { Remove-Item -LiteralPath $mergedConfig -Force -ErrorAction SilentlyContinue }
}
if ($buildExit -ne 0) {
    $buildLog | Select-Object -Last 40 | ForEach-Object { Write-Host $_ }
    Fail "tauri build exited $buildExit."
}

$setup = @(Get-ChildItem -LiteralPath $nsisDir -Filter "*_${version}_x64-setup.exe")
if ($setup.Count -ne 1) { Fail "Expected one *_${version}_x64-setup.exe in $nsisDir, found $($setup.Count)." }
$setup = $setup[0]
$sigPath = "$($setup.FullName).sig"
if (-not (Test-Path -LiteralPath $sigPath)) { Fail "No signature next to the installer ($sigPath). Was the signing key picked up?" }

# --- 4. Collect files and write latest.json -------------------------------
if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
Copy-Item -LiteralPath $setup.FullName -Destination $OutDir
Copy-Item -LiteralPath $sigPath -Destination $OutDir
$signature = (Get-Content -Raw -LiteralPath $sigPath).Trim()

$manifest = [ordered]@{
    version   = $version
    notes     = $Notes
    pub_date  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    platforms = [ordered]@{
        'windows-x86_64' = [ordered]@{
            signature = $signature
            url       = "$($BaseUrl.TrimEnd('/'))/$($setup.Name)"
        }
    }
}
$latestPath = Join-Path $OutDir 'latest.json'
Write-Utf8NoBom $latestPath ($manifest | ConvertTo-Json -Depth 5)

$sha256 = (Get-FileHash -LiteralPath $setup.FullName -Algorithm SHA256).Hash
Write-Host "Built and signed: $($setup.Name) ($([math]::Round($setup.Length / 1MB, 1)) MB, SHA-256 $sha256)" -ForegroundColor Green
Write-Host "Output: $OutDir"

if (-not $Publish) {
    Write-Host 'Dry run: nothing uploaded. Add -Publish to create the GitHub release.' -ForegroundColor Yellow
    exit 0
}

# --- 5. Publish ---------------------------------------------------------------
$notesText = if ($Notes) { $Notes } else { "Tabburrito $version" }
$files = @((Join-Path $OutDir $setup.Name), (Join-Path $OutDir "$($setup.Name).sig"), $latestPath)
$out = Invoke-Native { gh release create $tag @files --repo $Repo --target $headSha --title "Tabburrito $version" --notes $notesText --latest }
if ($LASTEXITCODE -ne 0) { Fail "gh release create failed: $($out -join ' ')" }
Write-Host "Published: https://github.com/$Repo/releases/tag/$tag" -ForegroundColor Green

# Read back what installed copies will actually see.
$liveUrl = "https://github.com/$Repo/releases/latest/download/latest.json"
$live = Invoke-RestMethod -Uri $liveUrl -UseBasicParsing
if ($live.version -ne $version) { Fail "$liveUrl reports version '$($live.version)', expected $version." }
$asset = Invoke-WebRequest -Uri $live.platforms.'windows-x86_64'.url -Method Head -UseBasicParsing -MaximumRedirection 5
Write-Host "Verified: latest.json reports $version; installer URL answers $($asset.StatusCode)." -ForegroundColor Green
exit 0
