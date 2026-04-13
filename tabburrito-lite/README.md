# Tabburrito Lite

Tabburrito Lite is the main maintained Tabburrito product. It is a lightweight Tauri controller that manages an isolated Firefox-based workspace.

## How It Runs

There are two important executables in the Lite build:

- `tabburrito-lite.exe`: the controller and tray app
- `TabburritoFirefox\tabburrito-browser.exe`: the rebranded browser runtime

Use `tabburrito-lite.exe` for normal usage.

The controller launches Firefox with:

- `--profile <exe-folder>\TabburritoLite\profile`
- `--no-remote`

This isolates Tabburrito from your normal Firefox profile.

## Why The Browser Has A Different Name

Windows surfaces like Task Manager, Alt-Tab, and the taskbar mostly identify the browser by the browser executable itself, not the tray shell.

To make Tabburrito clearly distinguishable from normal Firefox, Lite packages a local runtime:

- `TabburritoFirefox\tabburrito-browser.exe`

That runtime is intentionally separate from the normal installed `firefox.exe`.

## Managed Workspace

Tabburrito Lite treats these 5 services as the fixed workspace:

- WhatsApp
- Messenger
- LinkedIn
- Bluesky
- Google Calendar

Current default behavior:

- all 5 services are part of the managed workspace
- the controller is responsible for opening the managed service set
- the tray/controller should be the thing you quit, restart, and relaunch

## Tray Actions

- `Open Tabburrito`
- `Open All Services`
- `Open <service>`
- `Refresh Current Tab`
- `Mute/Unmute Current Tab`
- `Close Current Tab`
- `Toggle Dark/Light Theme`
- `Toggle Autostart`
- `Restart Tabburrito Firefox`
- `Write Status Report`
- `Open Profile Folder`
- `Reset Isolated Profile`
- `Quit`

## Global Shortcuts

- `Ctrl+Alt+1` WhatsApp
- `Ctrl+Alt+2` Messenger
- `Ctrl+Alt+3` LinkedIn
- `Ctrl+Alt+4` Bluesky
- `Ctrl+Alt+5` Calendar
- `Ctrl+Alt+R` refresh current tab
- `Ctrl+Alt+M` mute/unmute current tab
- `Ctrl+Alt+W` close current tab
- `Ctrl+Alt+O` reopen Tabburrito Firefox
- `Ctrl+Alt+D` toggle dark/light theme

## LinkedIn Ad Blocking

Lite keeps LinkedIn blocking in the isolated Firefox profile rather than in a brittle embedded-webview injection model.

The controller writes:

- `TabburritoLite\profile\linkedin-filters.txt`

uBlock Origin is also placed into the isolated profile when needed.

## Runtime Layout

Relative to the built Lite exe:

- `TabburritoLite\profile\` - isolated Firefox profile
- `TabburritoLite\config.json` - controller config
- `TabburritoLite\status.json` - diagnostic status output
- `TabburritoFirefox\` - rebranded packaged browser runtime

## Build

Build with the project-local Rust wrapper:

```powershell
..\build_local.bat build --manifest-path src-tauri\Cargo.toml
```

Or package the release form:

```powershell
..\release.bat lite
```

Outputs:

- `..\build\cargo-target-firefox-lite\release\tabburrito-lite.exe`
- `..\build\cargo-target-firefox-lite\release\TabburritoFirefox\tabburrito-browser.exe`

## Important Operational Notes

- Launch `tabburrito-lite.exe`, not `tabburrito-browser.exe`
- the tray/controller is the owner of startup, restart, and quit behavior
- if Windows caches an old taskbar icon, unpin the stale entry and pin the new Tabburrito one after launching the Lite controller
