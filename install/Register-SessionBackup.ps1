<#
.SYNOPSIS
    Registers (or removes) the scheduled task that backs up Tabburrito sessions.

.DESCRIPTION
    Creates a per-user scheduled task running Backup-TabburritoSessions.ps1
    weekly. Re-logging in to five services is tedious, and on 2026-08-04 the
    entire session folder was destroyed with no backup of any kind.

    The task passes -SkipIfRunning: WebView2 holds its databases open while
    Tabburrito runs, so a backup taken then can be torn. Skipping is the
    correct outcome, and the run exits 0 rather than reporting a weekly
    failure the user would learn to ignore.

    Backups land in %LOCALAPPDATA%\Tabburrito\Backups and the script already
    prunes to the 10 most recent, so this will not grow without bound.

    Registered via schtasks + task XML rather than Register-ScheduledTask,
    which fails with "Access is denied" on this machine even for a per-user
    task (same constraint as Register-AutoUpdate.ps1).

.PARAMETER Day
    Day of week to run. Default Sunday.

.PARAMETER At
    Time of day, HH:mm. Default 13:00.

.PARAMETER Remove
    Unregister the task instead of creating it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install\Register-SessionBackup.ps1
#>
[CmdletBinding()]
param(
    [ValidateSet('Monday','Tuesday','Wednesday','Thursday','Friday','Saturday','Sunday')]
    [string]$Day = 'Sunday',
    [ValidatePattern('^\d{2}:\d{2}$')]
    [string]$At = '13:00',
    [switch]$Remove
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$TaskName     = 'Tabburrito Session Backup'
$BackupScript = Join-Path $PSScriptRoot 'Backup-TabburritoSessions.ps1'

if ($Remove) {
    & schtasks /Delete /TN $TaskName /F 2>&1 | Out-Null
    Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    return
}

if (-not (Test-Path -LiteralPath $BackupScript)) {
    Write-Error "Backup script not found: $BackupScript"
}

$xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Backs up Tabburrito WebView2 sessions/logins weekly. Skips the run when Tabburrito is open, to avoid a torn snapshot.</Description>
  </RegistrationInfo>
  <Triggers>
    <CalendarTrigger>
      <StartBoundary>2026-01-01T$At`:00</StartBoundary>
      <Enabled>true</Enabled>
      <ScheduleByWeek>
        <DaysOfWeek><$Day /></DaysOfWeek>
        <WeeksInterval>1</WeeksInterval>
      </ScheduleByWeek>
    </CalendarTrigger>
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
      <Arguments>-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "$BackupScript" -SkipIfRunning</Arguments>
    </Exec>
  </Actions>
</Task>
"@

$xmlPath = Join-Path $env:TEMP 'TabburritoSessionBackup.xml'
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
Write-Host "  Runs    : $Day at $At (skipped when Tabburrito is open)"
Write-Host "  Backups : $env:LOCALAPPDATA\Tabburrito\Backups (10 most recent kept)"
Write-Host ''
Write-Host 'Back up now with:' -ForegroundColor DarkGray
Write-Host "  powershell -ExecutionPolicy Bypass -File `"$BackupScript`"" -ForegroundColor DarkGray
Write-Host ''
