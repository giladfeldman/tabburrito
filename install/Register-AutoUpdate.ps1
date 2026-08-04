<#
.SYNOPSIS
    Registers (or removes) the scheduled task that keeps Tabburrito updated.

.DESCRIPTION
    Creates a per-user scheduled task that runs Update-Tabburrito.ps1, which
    checks GitHub for new commits and rebuilds/reinstalls when it finds them.

    Runs hidden, at logon (delayed 5 minutes so it never competes with boot)
    and daily thereafter. No elevation required because the install lives
    under %LOCALAPPDATA%\Programs.

    The updater never touches sessions, and a failed build leaves the working
    installed exe in place.

.PARAMETER Interval
    How often to check after logon. Default Daily.

.PARAMETER Remove
    Unregister the task instead of creating it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Register-AutoUpdate.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Daily', 'Weekly', 'AtLogonOnly')]
    [string]$Interval = 'Daily',
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName   = 'Tabburrito Auto-Update'
$UpdateScript = Join-Path $PSScriptRoot 'Update-Tabburrito.ps1'

if ($Remove) {
    & schtasks /Delete /TN $TaskName /F 2>&1 | Out-Null
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    return
}

if (-not (Test-Path -LiteralPath $UpdateScript)) {
    Write-Error "Update script not found: $UpdateScript"
}

# Registered via schtasks + task XML rather than Register-ScheduledTask.
# Register-ScheduledTask fails with "Access is denied" on this machine even for a
# per-user task; schtasks /Create /XML registers the same task without elevation.

$calendarTrigger = switch ($Interval) {
    'Daily'  { '<CalendarTrigger><StartBoundary>2026-01-01T13:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>' }
    'Weekly' { '<CalendarTrigger><StartBoundary>2026-01-01T13:00:00</StartBoundary><Enabled>true</Enabled><ScheduleByWeek><DaysOfWeek><Monday /></DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek></CalendarTrigger>' }
    default  { '' }
}

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Checks GitHub for new Tabburrito commits, rebuilds, and reinstalls. Never touches saved sessions.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <Delay>PT5M</Delay>
      <UserId>$env:USERDOMAIN\$env:USERNAME</UserId>
    </LogonTrigger>
    $calendarTrigger
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$env:USERDOMAIN\$env:USERNAME</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <ExecutionTimeLimit>PT1H</ExecutionTimeLimit>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>powershell.exe</Command>
      <Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$UpdateScript" -Quiet</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP 'TabburritoAutoUpdate.xml'
# Task XML must be UTF-16 to match the declared encoding.
[System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)

try {
    $output = & schtasks /Create /TN $TaskName /XML $xmlPath /F 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Error "schtasks failed: $output"
    }
} finally {
    Remove-Item -LiteralPath $xmlPath -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Registered scheduled task '$TaskName'." -ForegroundColor Green
Write-Host "  Triggers : at logon (+5 min delay), $Interval"
Write-Host "  Log      : $env:LOCALAPPDATA\TabburritoBuild\update.log"
Write-Host ''
Write-Host 'Check for updates now with:' -ForegroundColor DarkGray
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$UpdateScript`"" -ForegroundColor DarkGray
Write-Host ''
