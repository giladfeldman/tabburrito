[CmdletBinding()]
param(
    [string]$TaskName = "WindowsTuneUp Smart Timeout"
)

$ErrorActionPreference = "Continue"

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "Removed scheduled task '$TaskName'."
} else {
    Write-Host "Scheduled task '$TaskName' was not installed."
}

$startupCmd = Join-Path ([Environment]::GetFolderPath("Startup")) "WindowsTuneUpSmartTimeout.cmd"
if (Test-Path -LiteralPath $startupCmd) {
    Remove-Item -LiteralPath $startupCmd -Force
    Write-Host "Removed Startup folder launcher."
}

$matches = Get-CimInstance Win32_Process |
    Where-Object {
        $_.Name -match "powershell|pwsh" -and
        $_.CommandLine -match "SmartTimeout\.ps1"
    }

foreach ($proc in $matches) {
    Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue
    Write-Host "Stopped SmartTimeout process $($proc.ProcessId)."
}
