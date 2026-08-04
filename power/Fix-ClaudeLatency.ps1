[CmdletBinding()]
param(
    [switch]$PromptSmokeTest
)

$ErrorActionPreference = "Continue"

$SettingsPath = Join-Path $env:USERPROFILE ".claude\settings.json"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Stop-MatchingProcessTree {
    param([string]$Pattern)

    $matches = Get-CimInstance Win32_Process | Where-Object {
        $_.CommandLine -match $Pattern -and $_.ProcessId -ne $PID
    }

    if (-not $matches) {
        Write-Host "No matching processes for $Pattern"
        return
    }

    $matchIds = @($matches | Select-Object -ExpandProperty ProcessId)
    $roots = $matches | Where-Object { $_.ParentProcessId -notin $matchIds }

    foreach ($process in $roots) {
        Write-Host "Stopping process tree $($process.ProcessId) $($process.Name)"
        taskkill /PID $process.ProcessId /T /F | Out-String | Write-Host
    }
}

function Get-ClaudeCodeVersion {
    $versionText = $null
    try {
        $versionText = (& claude --version 2>$null) -join "`n"
    } catch {
        return $null
    }

    if ($versionText -match "([0-9]+\.[0-9]+\.[0-9]+)") {
        return $Matches[1]
    }

    return $null
}

if (-not (Test-Path -LiteralPath $SettingsPath)) {
    throw "Claude Code settings file not found: $SettingsPath"
}

$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupPath = "$SettingsPath.bak-$stamp"
Copy-Item -LiteralPath $SettingsPath -Destination $backupPath
Write-Step "Backed up settings to $backupPath"

$settings = Get-Content -LiteralPath $SettingsPath -Raw | ConvertFrom-Json

if (-not $settings.env) {
    $settings | Add-Member -NotePropertyName "env" -NotePropertyValue ([pscustomobject]@{})
}

$settings.env | Add-Member -NotePropertyName "CLAUDE_CODE_MAX_RETRIES" -NotePropertyValue "3" -Force
$settings.env | Add-Member -NotePropertyName "API_TIMEOUT_MS" -NotePropertyValue "120000" -Force
$settings.env | Add-Member -NotePropertyName "CLAUDE_CODE_CONNECT_TIMEOUT_MS" -NotePropertyValue "30000" -Force
$settings.env | Add-Member -NotePropertyName "DISABLE_AUTOUPDATER" -NotePropertyValue "1" -Force

$settings | Add-Member -NotePropertyName "disableAllHooks" -NotePropertyValue $true -Force
$settings | Add-Member -NotePropertyName "alwaysThinkingEnabled" -NotePropertyValue $false -Force
$settings | Add-Member -NotePropertyName "autoUpdatesChannel" -NotePropertyValue "stable" -Force

$version = Get-ClaudeCodeVersion
if ($version) {
    $settings | Add-Member -NotePropertyName "minimumVersion" -NotePropertyValue $version -Force
}

$settings |
    ConvertTo-Json -Depth 20 |
    Set-Content -LiteralPath $SettingsPath -Encoding UTF8

Write-Step "Applied low-latency Claude Code settings"

Write-Step "Clearing stale Claude Code hook and doctor process trees"
Stop-MatchingProcessTree "onboard-scan\.sh|run-bash-hook\.ps1"
Stop-MatchingProcessTree "claude\.exe.*doctor"

Write-Step "Timing local Claude Code startup"
Measure-Command { claude --version | Out-String | Out-Null } |
    Select-Object TotalSeconds |
    Format-List

if ($PromptSmokeTest) {
    Write-Step "Timing one tiny prompt"
    Measure-Command { claude -p "Reply with exactly OK" | Out-String | Out-Null } |
        Select-Object TotalSeconds |
        Format-List
}
