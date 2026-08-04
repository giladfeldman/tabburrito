#Requires -RunAsAdministrator

[CmdletBinding()]
param()

$ErrorActionPreference = "Continue"

Write-Host "Setting AC hibernate strategy..."
powercfg /change hibernate-timeout-ac 0
powercfg /change standby-timeout-ac 0
Write-Host "  AC hibernate disabled. Battery hibernate remains controlled by the active power plan and SmartTimeout."

Write-Host ""
Write-Host "Disabling device wake sources..."
$devices = @(
    "Intel(R) Wi-Fi 6E AX211 160MHz",
    "USB4 Root Router (1.0)",
    "USB4 Root Router (1.0) (001)"
)

foreach ($device in $devices) {
    Write-Host "  $device"
    powercfg /devicedisablewake $device
}

Write-Host ""
Write-Host "Disabling Wi-Fi wake-on-network triggers..."
foreach ($prop in @("Wake on Magic Packet", "Wake on Pattern Match")) {
    try {
        Set-NetAdapterAdvancedProperty -Name "Wi-Fi" -DisplayName $prop -DisplayValue "Disabled" -NoRestart -ErrorAction Stop
        Write-Host "  Disabled $prop"
    } catch {
        Write-Warning "Could not disable $prop`: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Disabling HP Print Scan Doctor wake-to-run tasks..."
$taskPath = "\HP\HP Print Scan Doctor\"
foreach ($name in @("Printer Health Monitor", "Printer Health Monitor Logon")) {
    try {
        $task = Get-ScheduledTask -TaskPath $taskPath -TaskName $name -ErrorAction Stop
        $task.Settings.WakeToRun = $false
        Set-ScheduledTask -InputObject $task -ErrorAction Stop | Out-Null
        Write-Host "  Disabled WakeToRun for $taskPath$name"
    } catch {
        Write-Warning "Could not update $taskPath$name`: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Host "Wake-armed devices after cleanup:"
powercfg /devicequery wake_armed

Write-Host ""
Write-Host "Active wake timers:"
powercfg /waketimers
