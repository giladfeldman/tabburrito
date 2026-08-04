# WindowsTuneUp Smart Timeout

This folder contains a process-aware hibernation guard for Windows.

The monitor lets the display turn off and lets the system hibernate when it has
been truly idle, but calls the Windows power API to keep the system awake while
local work appears active. It treats recent CPU activity from Codex, Claude,
Node, Python, Cargo/Rust, Git/GitHub CLI, and PowerShell as work.

## Install

Run from PowerShell:

```powershell
.\power\Install-SmartTimeout.ps1
```

This first tries to install a current-user scheduled task named
`WindowsTuneUp Smart Timeout`. If Task Scheduler is blocked by policy or
permissions, it falls back to a current-user Startup folder launcher. Either
way, it starts the monitor immediately.

Defaults:

- AC idle hibernate threshold: disabled
- Battery idle hibernate threshold: 30 minutes
- Work grace period: 45 minutes after protected work was last busy
- Poll interval: 60 seconds

## Uninstall

```powershell
.\power\Uninstall-SmartTimeout.ps1
```

## Admin Wake Cleanup

Some wake sources require an elevated PowerShell session to change:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HOME\Vibe\WindowsTuneUp\power\Admin-WakeCleanup.ps1`""
```

This disables wake permission for the current Wi-Fi adapter and USB4 root
routers, turns off Wi-Fi magic-packet/pattern wake, and disables HP Print Scan
Doctor tasks that are allowed to wake the machine.

## Claude Desktop Update Lock

Claude Desktop's WindowsApps/MSIX updater can get stuck with
"another program is using this file" while `CoworkVMService` or an orphaned
package process is still alive. Clear the lock without restarting Windows:

```powershell
.\power\Fix-ClaudeDesktopUpdateLock.ps1
```

Update Claude manually after doing that cleanup:

```powershell
.\power\Fix-ClaudeDesktopUpdateLock.ps1 -Upgrade -Launch
```

To avoid the repeating auto-update crash loop, disable Claude Desktop
auto-updates for the current Windows user and keep updates manual:

```powershell
.\power\Fix-ClaudeDesktopUpdateLock.ps1 -DisableAutoUpdates
```

If Windows has locked the policy registry path, run the same action elevated:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HOME\Vibe\WindowsTuneUp\power\Fix-ClaudeDesktopUpdateLock.ps1`" -DisableAutoUpdates -StatusOnly"
```

Turn automatic updates back on:

```powershell
.\power\Fix-ClaudeDesktopUpdateLock.ps1 -EnableAutoUpdates
```

## Claude Code Latency

If Claude Code or Claude Desktop waits a long time before even showing that it
is thinking, clear stale hook processes and apply the low-latency Claude Code
profile:

```powershell
.\power\Fix-ClaudeLatency.ps1
```

The script backs up `%USERPROFILE%\.claude\settings.json`, disables Claude Code
custom hooks, turns off always-thinking by default, disables the Claude Code
auto-updater, switches updates to the stable channel, and reduces retry/connect
timeouts so network failures do not sit silently for minutes.

Run a tiny prompt smoke test too:

```powershell
.\power\Fix-ClaudeLatency.ps1 -PromptSmokeTest
```

## Disable Claude Cowork

If you use Claude Desktop only for chat/Claude Code and do not use Cowork,
disable its VM features and service:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$HOME\Vibe\WindowsTuneUp\power\Disable-ClaudeCowork.ps1`""
```

Check status:

```powershell
.\power\Disable-ClaudeCowork.ps1 -StatusOnly
```

## Log

The monitor writes to:

```text
%LOCALAPPDATA%\WindowsTuneUp\smart-timeout.log
```

## Tuning

The installer passes parameters through to `SmartTimeout.ps1`.

Examples:

```powershell
.\power\Install-SmartTimeout.ps1 -AcIdleMinutes 120 -BatteryIdleMinutes 45
.\power\Install-SmartTimeout.ps1 -AcIdleMinutes 0
.\power\Install-SmartTimeout.ps1 -DryRunMonitor
```

Dry run mode logs when it would hibernate, but does not actually hibernate.
Use `-AcIdleMinutes 0` to keep AC hibernation disabled.
