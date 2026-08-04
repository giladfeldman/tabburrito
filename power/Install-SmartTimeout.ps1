[CmdletBinding()]
param(
    [string]$TaskName = "WindowsTuneUp Smart Timeout",
    [string]$MonitorPath = "",
    [int]$AcIdleMinutes = 0,
    [int]$BatteryIdleMinutes = 30,
    [int]$WorkGraceMinutes = 45,
    [int]$PollSeconds = 60,
    [switch]$DryRunMonitor
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($MonitorPath)) {
    $MonitorPath = Join-Path $PSScriptRoot "SmartTimeout.ps1"
}

$resolvedMonitor = (Resolve-Path -LiteralPath $MonitorPath).Path
$powerShell = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

$existing = Get-CimInstance Win32_Process |
    Where-Object {
        $_.ProcessId -ne $PID -and
        $_.Name -match "powershell|pwsh" -and
        $_.CommandLine -match '(?i)-File\s+"?[^"]*SmartTimeout\.ps1"?'
    }

foreach ($proc in $existing) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
}

$arguments = @(
    "-NoProfile",
    "-ExecutionPolicy", "Bypass",
    "-WindowStyle", "Hidden",
    "-File", "`"$resolvedMonitor`"",
    "-AcIdleMinutes", $AcIdleMinutes,
    "-BatteryIdleMinutes", $BatteryIdleMinutes,
    "-WorkGraceMinutes", $WorkGraceMinutes,
    "-PollSeconds", $PollSeconds
)

if ($DryRunMonitor) {
    $arguments += "-DryRun"
}

$action = New-ScheduledTaskAction -Execute $powerShell -Argument ($arguments -join " ")
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit ([TimeSpan]::Zero)

$installedVia = $null

try {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $action `
        -Trigger $trigger `
        -Settings $settings `
        -Description "Process-aware hibernation guard for Codex, Claude, and long local jobs." `
        -Force `
        -ErrorAction Stop | Out-Null

    Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $installedVia = "scheduled task"
} catch {
    Write-Warning "Scheduled Task install failed: $($_.Exception.Message)"
    Write-Warning "Falling back to the current user's Startup folder."

    $startupDir = [Environment]::GetFolderPath("Startup")
    if (-not (Test-Path -LiteralPath $startupDir)) {
        New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
    }

    $startupCmd = Join-Path $startupDir "WindowsTuneUpSmartTimeout.cmd"
    $cmd = "@echo off`r`nstart `"`" `"$powerShell`" $($arguments -join " ")`r`n"
    Set-Content -LiteralPath $startupCmd -Value $cmd -Encoding ASCII

    Start-Process -FilePath $powerShell -ArgumentList ($arguments -join " ") -WindowStyle Hidden
    $installedVia = "Startup folder"
}

Write-Host "Installed and started '$TaskName' via $installedVia."
Write-Host "Monitor: $resolvedMonitor"
Write-Host "Log: $env:LOCALAPPDATA\WindowsTuneUp\smart-timeout.log"
