[CmdletBinding()]
param(
    [switch]$StatusOnly
)

$ErrorActionPreference = "Continue"

$ServiceName = "CoworkVMService"
$PolicyPath = "HKLM:\SOFTWARE\Policies\Claude"
$LogPath = Join-Path $env:LOCALAPPDATA "WindowsTuneUp\claude-cowork-disable.log"

function Write-Log {
    param([string]$Message)
    $dir = Split-Path -Parent $LogPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $line = "$(Get-Date -Format s) $Message"
    Write-Host $line
    Add-Content -LiteralPath $LogPath -Value $line
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Show-Status {
    Write-Log "Claude Cowork policy/service status:"

    $policy = Get-ItemProperty -Path $PolicyPath -ErrorAction SilentlyContinue
    if ($null -ne $policy.secureVmFeaturesEnabled) {
        Write-Log "HKLM secureVmFeaturesEnabled=$($policy.secureVmFeaturesEnabled)"
    } else {
        Write-Log "HKLM secureVmFeaturesEnabled is not set"
    }

    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($service) {
        Write-Log "Service $ServiceName status=$($service.Status) startType=$($service.StartType)"
    } else {
        Write-Log "Service $ServiceName was not found"
    }
}

if ($StatusOnly) {
    Show-Status
    exit 0
}

if (-not (Test-IsAdministrator)) {
    Write-Log "Administrator rights are required to disable $ServiceName."
    Write-Log "Run this elevated:"
    Write-Log "Start-Process powershell -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""$PSCommandPath""'"
    Show-Status
    exit 1
}

Write-Log "Disabling Claude Cowork VM features by policy"
New-Item -Path $PolicyPath -Force | Out-Null
New-ItemProperty `
    -Path $PolicyPath `
    -Name "secureVmFeaturesEnabled" `
    -Value 0 `
    -PropertyType DWord `
    -Force | Out-Null

Write-Log "Stopping $ServiceName"
Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue

Write-Log "Disabling $ServiceName startup"
Set-Service -Name $ServiceName -StartupType Disabled -ErrorAction Stop

Get-Process -Name cowork-svc -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue

Show-Status
