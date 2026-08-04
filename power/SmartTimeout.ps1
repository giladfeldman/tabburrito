[CmdletBinding()]
param(
    [int]$AcIdleMinutes = 0,
    [int]$BatteryIdleMinutes = 30,
    [int]$PollSeconds = 60,
    [int]$WorkGraceMinutes = 45,
    [int]$NewProcessGraceMinutes = 20,
    [double]$ProtectedCpuSecondsPerPoll = 1.0,
    [int]$SystemBusyPercent = 25,
    [string[]]$ProtectedProcessNames = @(
        "codex",
        "Codex",
        "claude",
        "node",
        "node_repl",
        "npm",
        "pnpm",
        "bun",
        "python",
        "python3",
        "cargo",
        "rustc",
        "git",
        "gh",
        "powershell",
        "pwsh"
    ),
    [string]$LogPath = "$env:LOCALAPPDATA\WindowsTuneUp\smart-timeout.log",
    [switch]$DryRun
)

$ErrorActionPreference = "Continue"

# Single-instance guard: only one SmartTimeout monitor may run at a time.
# Without this, a second launcher (e.g. a Startup-folder copy running alongside
# the scheduled task) starts a duplicate monitor; both append to the same log
# and collide on the file, producing repeated console errors at logon
# ("used by another process" / "Stream was not readable").
$singleInstanceMutex = New-Object System.Threading.Mutex($false, "WindowsTuneUpSmartTimeout_SingleInstance")
$haveInstanceLock = $false
try {
    $haveInstanceLock = $singleInstanceMutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
    # Previous monitor was killed (e.g. at shutdown) without releasing the lock;
    # the lock is now ours.
    $haveInstanceLock = $true
}
if (-not $haveInstanceLock) {
    # Another monitor already owns the lock; this copy is redundant. Exit quietly
    # so a stray second launcher can never spam errors or fight over the log.
    exit 0
}

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param([string]$Message)

    $line = "{0:s} {1}" -f (Get-Date), $Message
    # Retry briefly on transient file contention and never surface a console
    # error from logging. The monitor must keep running no matter what, and a
    # logging hiccup must never spam the user's screen.
    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            Add-Content -LiteralPath $LogPath -Value $line -ErrorAction Stop
            return
        } catch {
            Start-Sleep -Milliseconds 50
        }
    }
}

$nativeSource = @"
using System;
using System.Runtime.InteropServices;

public static class SmartTimeoutNative {
    [StructLayout(LayoutKind.Sequential)]
    public struct LASTINPUTINFO {
        public uint cbSize;
        public uint dwTime;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus;
        public byte BatteryFlag;
        public byte BatteryLifePercent;
        public byte SystemStatusFlag;
        public int BatteryLifeTime;
        public int BatteryFullLifeTime;
    }

    [DllImport("user32.dll")]
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);

    [DllImport("kernel32.dll")]
    public static extern ulong GetTickCount64();

    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint esFlags);

    [DllImport("kernel32.dll")]
    public static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS lpSystemPowerStatus);
}
"@

if (-not ([System.Management.Automation.PSTypeName]"SmartTimeoutNative").Type) {
    Add-Type -TypeDefinition $nativeSource
}

$ES_CONTINUOUS = [Convert]::ToUInt32("80000000", 16)
$ES_SYSTEM_REQUIRED = [Convert]::ToUInt32("00000001", 16)

function Get-UserIdleSeconds {
    $info = New-Object SmartTimeoutNative+LASTINPUTINFO
    $info.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($info)

    if (-not [SmartTimeoutNative]::GetLastInputInfo([ref]$info)) {
        return 0
    }

    $tickNow = [SmartTimeoutNative]::GetTickCount64()
    return [math]::Max(0, ($tickNow - [uint64]$info.dwTime) / 1000)
}

function Get-OnBattery {
    $status = New-Object SmartTimeoutNative+SYSTEM_POWER_STATUS
    if ([SmartTimeoutNative]::GetSystemPowerStatus([ref]$status)) {
        return ($status.ACLineStatus -eq 0)
    }

    return $false
}

function Set-SystemAwake {
    param([bool]$Enabled)

    if ($Enabled) {
        [SmartTimeoutNative]::SetThreadExecutionState([uint32]($ES_CONTINUOUS -bor $ES_SYSTEM_REQUIRED)) | Out-Null
    } else {
        [SmartTimeoutNative]::SetThreadExecutionState($ES_CONTINUOUS) | Out-Null
    }
}

function Get-SystemCpuPercent {
    try {
        $processors = Get-CimInstance Win32_Processor
        return [int](($processors | Measure-Object -Property LoadPercentage -Average).Average)
    } catch {
        Write-Log "WARN: Could not read system CPU load: $($_.Exception.Message)"
        return 0
    }
}

function Get-ProtectedProcesses {
    $nameSet = @{}
    foreach ($name in $ProtectedProcessNames) {
        $nameSet[$name.ToLowerInvariant()] = $true
    }

    Get-Process |
        Where-Object {
            $_.Id -ne $PID -and
            $null -ne $_.CPU -and
            $nameSet.ContainsKey($_.ProcessName.ToLowerInvariant())
        } |
        Select-Object Id, ProcessName, CPU, StartTime
}

$previousCpu = @{}
$lastWorkActivity = Get-Date
$lastState = ""
$lastHeartbeat = Get-Date

$acIdleLabel = if ($AcIdleMinutes -gt 0) { "${AcIdleMinutes}m" } else { "disabled" }
$batteryIdleLabel = if ($BatteryIdleMinutes -gt 0) { "${BatteryIdleMinutes}m" } else { "disabled" }
Write-Log "START: SmartTimeout monitor started. AC idle $acIdleLabel, battery idle $batteryIdleLabel, work grace ${WorkGraceMinutes}m, poll ${PollSeconds}s, dry-run=$DryRun."

try {
    while ($true) {
        $now = Get-Date
        $onBattery = Get-OnBattery
        $idleLimitMinutes = if ($onBattery) { $BatteryIdleMinutes } else { $AcIdleMinutes }
        $hibernateAllowed = $idleLimitMinutes -gt 0
        $idleLimitLabel = if ($hibernateAllowed) { "${idleLimitMinutes}m" } else { "disabled" }
        $userIdleMinutes = [math]::Round((Get-UserIdleSeconds / 60), 1)
        $systemCpu = Get-SystemCpuPercent
        $protected = @(Get-ProtectedProcesses)
        $protectedCpuDelta = 0.0
        $newProtected = $false

        foreach ($proc in $protected) {
            $key = [string]$proc.Id
            if ($previousCpu.ContainsKey($key)) {
                $delta = [double]$proc.CPU - [double]$previousCpu[$key]
                if ($delta -gt 0) {
                    $protectedCpuDelta += $delta
                }
            } elseif ($proc.StartTime -and (($now - $proc.StartTime).TotalMinutes -lt $NewProcessGraceMinutes)) {
                $newProtected = $true
            }
        }

        $currentCpu = @{}
        foreach ($proc in $protected) {
            $currentCpu[[string]$proc.Id] = [double]$proc.CPU
        }
        $previousCpu = $currentCpu

        $protectedBusy = ($protectedCpuDelta -ge $ProtectedCpuSecondsPerPoll) -or $newProtected
        $systemBusy = ($systemCpu -ge $SystemBusyPercent)

        if ($protectedBusy -or $systemBusy) {
            $lastWorkActivity = $now
        }

        $workRecentlyActive = (($now - $lastWorkActivity).TotalMinutes -lt $WorkGraceMinutes)
        Set-SystemAwake -Enabled $workRecentlyActive

        $state = "power={0}; idle={1}m/{2}; protected={3}; protectedCpuDelta={4:n1}s; systemCpu={5}%; workRecent={6}" -f `
            ($(if ($onBattery) { "battery" } else { "ac" })),
            $userIdleMinutes,
            $idleLimitLabel,
            $protected.Count,
            $protectedCpuDelta,
            $systemCpu,
            $workRecentlyActive

        if ($state -ne $lastState -or (($now - $lastHeartbeat).TotalMinutes -ge 15)) {
            Write-Log "STATE: $state"
            $lastState = $state
            $lastHeartbeat = $now
        }

        if ($hibernateAllowed -and $userIdleMinutes -ge $idleLimitMinutes -and -not $workRecentlyActive) {
            if ($DryRun) {
                Write-Log "DRYRUN: Would hibernate now. $state"
                $lastWorkActivity = $now
            } else {
                Write-Log "ACTION: Hibernating. $state"
                Set-SystemAwake -Enabled $false
                Start-Process -FilePath "$env:WINDIR\System32\shutdown.exe" -ArgumentList "/h" -WindowStyle Hidden
                Start-Sleep -Seconds 300
            }
        }

        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    Set-SystemAwake -Enabled $false
    Write-Log "STOP: SmartTimeout monitor stopped."
    if ($haveInstanceLock) {
        try { $singleInstanceMutex.ReleaseMutex() } catch { }
        $singleInstanceMutex.Dispose()
    }
}
