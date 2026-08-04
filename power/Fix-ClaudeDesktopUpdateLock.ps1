[CmdletBinding()]
param(
    [switch]$Upgrade,
    [switch]$Launch,
    [switch]$DisableAutoUpdates,
    [switch]$EnableAutoUpdates,
    [switch]$StatusOnly
)

$ErrorActionPreference = "Continue"

$PackageFamilyName = "Claude_pzs8sxrjxfjjc"
$PackageAppId = "$PackageFamilyName!Claude"
$CoworkServiceName = "CoworkVMService"
$CurrentUserPolicyPath = "HKCU:\SOFTWARE\Policies\Claude"
$MachinePolicyPath = "HKLM:\SOFTWARE\Policies\Claude"

function Write-Step {
    param([string]$Message)
    Write-Host "==> $Message"
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-ClaudeDesktopProcess {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $name = $_.ProcessName
        $path = $null

        try {
            $path = $_.Path
        } catch {
            $path = $null
        }

        if ($name -ieq "cowork-svc") {
            return $true
        }

        if ($name -match "Claude|Anthropic") {
            if ($path -and (
                $path -like "*\WindowsApps\Claude_*" -or
                $path -like "*\AppData\Local\Packages\$PackageFamilyName*" -or
                $path -like "*\AppData\Local\Programs\Claude*"
            )) {
                return $true
            }
        }

        return $false
    }
}

function Show-ClaudeDesktopStatus {
    Write-Step "Claude package"
    $package = Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue
    if ($package) {
        $package | Select-Object Name, Version, PackageFullName, InstallLocation | Format-List
    } else {
        Write-Host "No MSIX/AppX Claude package found for the current user."
    }

    Write-Step "Cowork service"
    $service = Get-Service -Name $CoworkServiceName -ErrorAction SilentlyContinue
    if ($service) {
        $service | Select-Object Name, DisplayName, Status, StartType | Format-List
    } else {
        Write-Host "CoworkVMService was not found."
    }

    Write-Step "Claude Desktop-related processes"
    $processes = Get-ClaudeDesktopProcess
    if ($processes) {
        $processes | Select-Object Id, ProcessName, Path, StartTime | Format-List
    } else {
        Write-Host "No Claude Desktop package processes found."
    }

    Write-Step "Current-user auto-update policy"
    $policy = Get-ItemProperty -Path $CurrentUserPolicyPath -ErrorAction SilentlyContinue
    if ($null -ne $policy.disableAutoUpdates) {
        Write-Host "disableAutoUpdates=$($policy.disableAutoUpdates)"
    } else {
        Write-Host "disableAutoUpdates is not set in HKCU."
    }

    Write-Step "Machine auto-update policy"
    $machinePolicy = Get-ItemProperty -Path $MachinePolicyPath -ErrorAction SilentlyContinue
    if ($null -ne $machinePolicy.disableAutoUpdates) {
        Write-Host "disableAutoUpdates=$($machinePolicy.disableAutoUpdates)"
    } else {
        Write-Host "disableAutoUpdates is not set in HKLM."
    }
}

function Stop-ClaudeDesktopForUpdate {
    Write-Step "Stopping Claude Desktop service"
    $service = Get-Service -Name $CoworkServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Stop-Service -Name $CoworkServiceName -Force -ErrorAction Continue
        Start-Sleep -Seconds 2
    } else {
        Write-Host "CoworkVMService was not found."
    }

    Write-Step "Stopping orphaned Claude Desktop package processes"
    $processes = Get-ClaudeDesktopProcess
    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            Write-Host "Stopped $($process.ProcessName) [$($process.Id)]"
        } catch {
            Write-Warning "Could not stop $($process.ProcessName) [$($process.Id)]: $($_.Exception.Message)"
        }
    }
}

function Set-ClaudeAutoUpdatePolicy {
    param([bool]$Disabled)

    $value = 0
    if ($Disabled) {
        $value = 1
    }

    try {
        New-Item -Path $CurrentUserPolicyPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty `
            -Path $CurrentUserPolicyPath `
            -Name "disableAutoUpdates" `
            -Value $value `
            -PropertyType DWord `
            -Force `
            -ErrorAction Stop | Out-Null
        $scope = "current user"
    } catch {
        if (-not (Test-IsAdministrator)) {
            Write-Warning "Could not write ${CurrentUserPolicyPath}: $($_.Exception.Message)"
            Write-Warning "Run this script from an elevated PowerShell window to set the machine-level Claude policy."
            return $false
        }

        New-Item -Path $MachinePolicyPath -Force -ErrorAction Stop | Out-Null
        New-ItemProperty `
            -Path $MachinePolicyPath `
            -Name "disableAutoUpdates" `
            -Value $value `
            -PropertyType DWord `
            -Force `
            -ErrorAction Stop | Out-Null
        $scope = "machine"
    }

    if ($Disabled) {
        Write-Step "Disabled Claude Desktop auto-updates at $scope scope"
    } else {
        Write-Step "Enabled Claude Desktop auto-updates at $scope scope"
    }

    return $true
}

if ($DisableAutoUpdates -and $EnableAutoUpdates) {
    throw "Use either -DisableAutoUpdates or -EnableAutoUpdates, not both."
}

if ($DisableAutoUpdates) {
    [void](Set-ClaudeAutoUpdatePolicy -Disabled $true)
}

if ($EnableAutoUpdates) {
    [void](Set-ClaudeAutoUpdatePolicy -Disabled $false)
}

if ($StatusOnly) {
    Show-ClaudeDesktopStatus
    exit 0
}

Stop-ClaudeDesktopForUpdate

if ($Upgrade) {
    Write-Step "Running winget upgrade for Claude"
    winget upgrade --id Anthropic.Claude --accept-source-agreements --accept-package-agreements
}

if ($Launch) {
    Write-Step "Launching Claude Desktop"
    Start-Process "shell:AppsFolder\$PackageAppId"
}

Show-ClaudeDesktopStatus
