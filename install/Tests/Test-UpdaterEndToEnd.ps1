<#
.SYNOPSIS
    End-to-end test of the release updater, entirely on this machine.

.DESCRIPTION
    Builds two copies of a SEPARATE test product ("TabburritoE2E", its own
    identifier, its own throwaway signing key, a local http endpoint), so the
    real installed Tabburrito, its sessions and its registry entries are never
    involved. Then:

      1. Installs test version A (0.2.0) silently into tmp\e2e\install, in
         portable mode, with a seeded fake "sessions" folder.
      2. REFUSED cases - serves a latest.json announcing version B (0.2.1)
         whose installer is (a) tampered (one byte appended) and (b) signed
         with a different key. Launches A each time and requires the update
         log to say REFUSED and the installed exe to still be version A.
      3. GOOD case - serves the genuine, correctly signed B. Launches A and
         requires: the log says "signature verified" and "Installing", the exe
         on disk becomes version B, the relaunched app logs "Up to date
         (version 0.2.1)", and the seeded sessions are byte-for-byte unchanged.
      4. Uninstalls the test product and stops the local server.

    Takes two release builds (several minutes each on a warm cache). Shows
    the test app's window while it runs.

.PARAMETER KeepArtifacts
    Leave tmp\e2e in place for inspection.
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$CargoTargetDir = (Join-Path $env:LOCALAPPDATA 'TabburritoBuild\cargo-target'),
    [switch]$KeepArtifacts,
    # Reuse tmp\e2e's keys and builds from an earlier -KeepArtifacts run.
    [switch]$SkipBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot   = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Publisher  = Join-Path $RepoRoot 'install\Publish-TabburritoRelease.ps1'
$Work       = Join-Path $RepoRoot 'tmp\e2e'
# Installed WITHOUT /D, so the patched default install folder of the template
# (src-tauri\windows\installer.nsi) is what is exercised.
$InstallDir = Join-Path $env:LOCALAPPDATA "Programs\TabburritoE2E"
$Serve      = Join-Path $Work 'serve'
$Product    = 'TabburritoE2E'
$VersionA   = '0.2.0'
$VersionB   = '0.2.1'
$Exe        = Join-Path $InstallDir "$Product.exe"
$Log        = Join-Path $InstallDir 'update.log'
$Attempt    = Join-Path $InstallDir 'update-attempt.json'
$Sessions   = Join-Path $InstallDir 'TabburritoWebViewData'
$TargetDir  = $CargoTargetDir

$results = New-Object System.Collections.Generic.List[string]
$failed  = $false
function Check([string]$name, [bool]$ok, [string]$detail = '') {
    $line = '{0} {1}{2}' -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { " - $detail" } else { '' })
    $script:results.Add($line)
    Write-Host $line -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    if (-not $ok) { $script:failed = $true }
}

function Invoke-Native([scriptblock]$Command) {
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $Command 2>&1 | ForEach-Object { "$_" } } finally { $ErrorActionPreference = $prev }
}

function Write-Utf8NoBom([string]$Path, [string]$Text) {
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Get-ExeVersion { if (Test-Path -LiteralPath $Exe) { (Get-Item -LiteralPath $Exe).VersionInfo.ProductVersion } else { '' } }
# The exe's embedded version comes from Cargo.toml, which -VersionOverride does
# not change, so 'was the exe replaced' is judged by its SHA-256 instead.
function Get-ExeHash { try { (Get-FileHash -LiteralPath $Exe -Algorithm SHA256 -ErrorAction Stop).Hash } catch { '' } }  # '' while missing or locked mid-install
function Get-LogText { if (Test-Path -LiteralPath $Log) { Get-Content -Raw -LiteralPath $Log } else { '' } }
# The test product MUST have its own exe name (mainBinaryName below). Tauri's
# installer closes every running process with the installer's exe name, in
# silent and passive mode without asking - with the default name the test's
# installs closed the user's real Tabburrito (2026-11-19). Matching by path as
# well keeps the test from ever touching another copy.
function Get-TestApp {
    Get-Process -Name $Product -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.StartsWith($InstallDir, [StringComparison]::OrdinalIgnoreCase) }
}
function Stop-TestApp {
    Get-TestApp | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 800
}
function Wait-Until([scriptblock]$Condition, [int]$Seconds) {
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return [bool](& $Condition)
}
function Set-Served([string]$InstallerName, [string]$Signature, [string]$Version = $VersionB) {
    $manifest = [ordered]@{
        version   = $Version
        notes     = 'e2e'
        pub_date  = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        platforms = [ordered]@{
            'windows-x86_64' = [ordered]@{ signature = $Signature; url = "http://127.0.0.1:$Port/$InstallerName" }
        }
    }
    Write-Utf8NoBom (Join-Path $Serve 'latest.json') ($manifest | ConvertTo-Json -Depth 5)
}

$server = $null
try {
    # --- Setup: throwaway keys and test config --------------------------------
    Stop-TestApp
    $oldUninstaller = Join-Path $InstallDir 'uninstall.exe'
    if (Test-Path -LiteralPath $oldUninstaller) { Start-Process -FilePath $oldUninstaller -ArgumentList '/S' -Wait }
    if (Test-Path -LiteralPath $InstallDir) { Remove-Item -LiteralPath $InstallDir -Recurse -Force }
    # A remembered install folder from an earlier run would override the default.
    Remove-Item -LiteralPath "HKCU:\Software\tabburrito\$Product" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Work) {
        if ($SkipBuild) {
            if (Test-Path -LiteralPath $Serve) { Remove-Item -LiteralPath $Serve -Recurse -Force }
        } else {
            Remove-Item -LiteralPath $Work -Recurse -Force
        }
    }
    New-Item -ItemType Directory -Path $Work, $Serve -Force | Out-Null
    $keyGood  = Join-Path $Work 'e2e.key'
    $keyOther = Join-Path $Work 'other.key'
    # The "other" key carries a password: `tauri signer sign` prompts for one
    # when the key has none (and hangs unattended), and PowerShell 5.1 cannot
    # pass an empty -p argument. The build key stays passwordless, as in
    # production; `tauri build` honours CI=true instead of prompting.
    $otherPassword = 'e2e-other-key'
    if (-not $SkipBuild) {
        Push-Location $RepoRoot
        try {
            Invoke-Native { npx.cmd tauri signer generate --ci -f -w $keyGood } | Out-Null
            if ($LASTEXITCODE -ne 0) { throw 'signer generate failed (build key)' }
        } finally { Pop-Location }
    }
    # Always fresh: a key from an older run may have no password.
    Push-Location $RepoRoot
    try {
        Invoke-Native { npx.cmd tauri signer generate --ci -f -p $otherPassword -w $keyOther } | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'signer generate failed (other key)' }
    } finally { Pop-Location }

    $conf = [ordered]@{
        productName = $Product
        mainBinaryName = $Product
        identifier  = 'com.tabburrito.e2etest'
        plugins     = [ordered]@{
            updater = [ordered]@{
                pubkey    = (Get-Content -Raw -LiteralPath "$keyGood.pub").Trim()
                endpoints = @("http://127.0.0.1:$Port/latest.json")
                dangerousInsecureTransportProtocol = $true
            }
        }
    }
    $confPath = Join-Path $Work 'e2e.conf.json'
    Write-Utf8NoBom $confPath ($conf | ConvertTo-Json -Depth 10)

    # --- Build A and B ------------------------------------------------------
    foreach ($v in $VersionA, $VersionB) {
        if ($SkipBuild) { break }
        & powershell -NoProfile -ExecutionPolicy Bypass -File $Publisher -ConfigOverride $confPath `
            -VersionOverride $v -KeyPath $keyGood -OutDir (Join-Path $Work "build-$v") -CargoTargetDir $TargetDir `
            -BaseUrl "http://127.0.0.1:$Port"
        if ($LASTEXITCODE -ne 0) { throw "Build of $v failed." }
    }
    $setupA = Join-Path $Work "build-$VersionA\${Product}_${VersionA}_x64-setup.exe"
    $setupB = Join-Path $Work "build-$VersionB\${Product}_${VersionB}_x64-setup.exe"
    $sigA   = (Get-Content -Raw -LiteralPath "$setupA.sig").Trim()
    $sigB   = (Get-Content -Raw -LiteralPath "$setupB.sig").Trim()

    # Served files: genuine B, tampered B (one extra byte), B signed by another key.
    $nameB = Split-Path -Leaf $setupB
    Copy-Item -LiteralPath $setupB -Destination (Join-Path $Serve $nameB)
    $nameA = Split-Path -Leaf $setupA
    Copy-Item -LiteralPath $setupA -Destination (Join-Path $Serve $nameA)
    $tampered = Join-Path $Serve "tampered-$nameB"
    Copy-Item -LiteralPath $setupB -Destination $tampered
    $fs = [System.IO.File]::Open($tampered, 'Append'); $fs.WriteByte(0); $fs.Close()
    $otherSigned = Join-Path $Serve "other-$nameB"
    Copy-Item -LiteralPath $setupB -Destination $otherSigned
    Push-Location $RepoRoot
    try {
        $env:CI = 'true'
        Invoke-Native { npx.cmd tauri signer sign -f $keyOther -p $otherPassword $otherSigned } | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'signer sign (other key) failed' }
    } finally { Remove-Item Env:\CI -ErrorAction SilentlyContinue; Pop-Location }
    $sigOther = (Get-Content -Raw -LiteralPath "$otherSigned.sig").Trim()

    # --- Install A ----------------------------------------------------------
    Start-Process -FilePath $setupA -ArgumentList '/S', '/NS' -Wait
    Check 'install A into %LOCALAPPDATA%\Programs\<product> (patched default, not the sessions folder)' (
        (Get-ExeVersion) -eq $VersionA -and -not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA "$Product\$Product.exe"))
    ) "exe version '$(Get-ExeVersion)' at $Exe"
    $hashA = Get-ExeHash
    Check 'installed by setup (uninstall.exe present)' (Test-Path -LiteralPath (Join-Path $InstallDir 'uninstall.exe'))
    New-Item -ItemType File -Path (Join-Path $InstallDir 'portable.txt') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $Sessions 'main\Default') -Force | Out-Null
    Write-Utf8NoBom (Join-Path $Sessions 'main\Default\e2e-cookie-marker.txt') ([guid]::NewGuid().ToString())
    $fakeDb = New-Object byte[] 65536; (New-Object Random 7).NextBytes($fakeDb)
    [System.IO.File]::WriteAllBytes((Join-Path $Sessions 'main\Default\e2e-fake.db'), $fakeDb)
    $markerFiles = @('main\Default\e2e-cookie-marker.txt', 'main\Default\e2e-fake.db')
    $markerHash = ($markerFiles | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $Sessions $_)).Hash }) -join ','

    # --- Local server -------------------------------------------------------
    $python = (Get-Command python -ErrorAction Stop).Source
    $server = Start-Process -FilePath $python -ArgumentList '-m', 'http.server', $Port, '--bind', '127.0.0.1', '--directory', $Serve `
        -WindowStyle Hidden -PassThru
    Check 'local server up' (Wait-Until { try { (Invoke-WebRequest "http://127.0.0.1:$Port/" -UseBasicParsing -TimeoutSec 2).StatusCode -eq 200 } catch { $false } } 15)

    # --- REFUSED cases ------------------------------------------------------
    foreach ($case in @(
            @{ Name = 'tampered installer'; File = (Split-Path -Leaf $tampered); Sig = $sigB },
            @{ Name = 'signed with another key'; File = (Split-Path -Leaf $otherSigned); Sig = $sigOther })) {
        Set-Served $case.File $case.Sig
        $before = (Get-LogText).Length
        Start-Process -FilePath $Exe
        # 'REFUSED - signature check failed' is written only for signature errors;
        # a 404 or a dead server logs 'Downloading ... failed' instead.
        $refused = Wait-Until { (Get-LogText).Substring([Math]::Min($before, (Get-LogText).Length)) -match 'REFUSED - signature check failed' } 90
        $newLog = (Get-LogText).Substring([Math]::Min($before, (Get-LogText).Length)).Trim()
        # The version-binding refusal shares the prefix; these cases must be refused by the signature itself.
        Check "refuse $($case.Name)" ($refused -and $newLog -notmatch 'signed for version') ($newLog -replace "`r?`n", ' | ')
        Start-Sleep -Seconds 2
        Check "installed copy untouched after $($case.Name)" ((Get-ExeHash) -eq $hashA) 'exe SHA-256 unchanged'
        Check "app still running after $($case.Name)" ([bool](Get-TestApp))
        Stop-TestApp
    }

    # --- A version that failed to install before is NOT auto-installed -------
    Set-Served $nameB $sigB
    Write-Utf8NoBom $Attempt ('{"version":"' + $VersionB + '","failed":true}')
    $before = (Get-LogText).Length
    Start-Process -FilePath $Exe
    $staged = Wait-Until { (Get-LogText).Substring([Math]::Min($before, (Get-LogText).Length)) -match "Version $([regex]::Escape($VersionB)) is ready" } 90
    Start-Sleep -Seconds 3
    Check 'earlier failed version is staged, not auto-installed' ($staged -and (Get-ExeHash) -eq $hashA -and [bool](Get-TestApp))
    Stop-TestApp
    Remove-Item -LiteralPath $Attempt -Force

    # --- GOOD case ----------------------------------------------------------
    # DevTools port for the render probe; the installer passes this env on to the relaunched app.
    $env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = '--remote-debugging-port=0'
    $before = (Get-LogText).Length
    Start-Process -FilePath $Exe
    $installed = Wait-Until { $h = Get-ExeHash; $h -and $h -ne $hashA } 180
    Check 'genuine update replaced the exe' $installed 'exe SHA-256 changed'
    $relaunched = Wait-Until { (Get-LogText) -match "Up to date \(version $([regex]::Escape($VersionB))\)" } 90
    $newLog = (Get-LogText).Substring([Math]::Min($before, (Get-LogText).Length)).Trim()
    Check 'log shows verify -> install -> relaunched and up to date' (
        $relaunched -and $newLog -match 'signature verified' -and $newLog -match "Installing $([regex]::Escape($VersionB))" -and
        $newLog -match "Updated to version $([regex]::Escape($VersionB))"
    ) ($newLog -replace "`r?`n", ' | ')
    $markerAfter = ($markerFiles | ForEach-Object { (Get-FileHash -LiteralPath (Join-Path $Sessions $_)).Hash }) -join ','
    Check 'seeded session files unchanged' ($markerAfter -eq $markerHash)
    # The relaunched update must RENDER: open Settings and read what it shows.
    $probeOut = & $python (Join-Path $PSScriptRoot 'cdp_settings_probe.py') $Sessions --timeout 60 | Select-Object -Last 1
    $probe = try { $probeOut | ConvertFrom-Json } catch { $null }
    Check 'updated app renders Settings with the new version and updates enabled' (
        $probe -and $probe.ok -and $probe.version -eq $VersionB -and $probe.meta -eq 'Installed release' -and -not $probe.autoDisabled
    ) "$probeOut"
    Stop-TestApp
    $hashB = Get-ExeHash

    # --- Rollback: genuine OLD installer announced as a newer version --------
    # plus a pretend unfinished install of a version that never arrived.
    Set-Served $nameA $sigA '0.2.2'
    Write-Utf8NoBom $Attempt '{"version":"0.3.0","failed":false}'
    $before = (Get-LogText).Length
    Start-Process -FilePath $Exe
    $rolled = Wait-Until { (Get-LogText).Substring([Math]::Min($before, (Get-LogText).Length)) -match 'REFUSED' } 90
    $newLog = (Get-LogText).Substring([Math]::Min($before, (Get-LogText).Length)).Trim()
    Start-Sleep -Seconds 2
    Check 'old genuine installer served as 0.2.2 is refused (version bound to signature)' (
        $rolled -and $newLog -match "signed for version $([regex]::Escape($VersionA)), not 0\.2\.2" -and (Get-ExeHash) -eq $hashB
    ) ($newLog -replace "`r?`n", ' | ')
    $att = try { Get-Content -Raw -LiteralPath $Attempt | ConvertFrom-Json } catch { $null }
    Check 'unfinished install is detected and remembered' (
        $newLog -match 'Installing 0\.3\.0 did not finish' -and $att -and $att.failed -eq $true
    )
    Stop-TestApp
} catch {
    Check 'test harness' $false $_.Exception.Message
} finally {
    Remove-Item Env:\WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
    Stop-TestApp
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    $uninstaller = Join-Path $InstallDir 'uninstall.exe'
    if (Test-Path -LiteralPath $uninstaller) {
        Start-Process -FilePath $uninstaller -ArgumentList '/S' -Wait
        $left = Test-Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$Product"
        Check 'test product uninstalled (registry entry gone)' (-not $left)
        Check 'uninstall leaves the sessions folder in place' (Test-Path -LiteralPath (Join-Path $Sessions 'main\Default\e2e-fake.db'))
        # A silent uninstall keeps the remembered install folder and the window
        # state (they go only with "delete app data"); remove the test's own.
        Remove-Item -LiteralPath "HKCU:\Software\tabburrito\$Product" -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path 'HKCU:\Software\tabburrito') {
            if (-not (Get-ChildItem 'HKCU:\Software\tabburrito') -and -not (Get-ItemProperty 'HKCU:\Software\tabburrito').PSObject.Properties.Where({ $_.Name -notlike 'PS*' })) {
                Remove-Item -LiteralPath 'HKCU:\Software\tabburrito' -Force -ErrorAction SilentlyContinue
            }
        }
        Remove-Item -LiteralPath (Join-Path $env:APPDATA 'com.tabburrito.e2etest') -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA 'com.tabburrito.e2etest') -Recurse -Force -ErrorAction SilentlyContinue
    }
    # The uninstaller leaves the (portable) sessions and logs; this folder is
    # the test product's own, so remove it.
    if ((Split-Path -Leaf $InstallDir) -eq $Product -and (Test-Path -LiteralPath $InstallDir)) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $Work)) {
        Remove-Item -LiteralPath $Work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ''
Write-Host ('RESULT: {0} ({1} checks)' -f $(if ($failed) { 'FAIL' } else { 'PASS' }), $results.Count) -ForegroundColor $(if ($failed) { 'Red' } else { 'Green' })
exit $(if ($failed) { 1 } else { 0 })
