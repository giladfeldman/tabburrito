# Tabburrito

Tabburrito currently has two tracks:

- `tabburrito-lite/`: the main Firefox-based product direction
- root `src-tauri/` + `ui/`: the older WebView2 experiment kept as reference

The default recommendation is `Firefox Lite`.

## Current Product Direction

Firefox Lite is built around:

- a project-local Tauri controller: `tabburrito-lite.exe`
- a project-local isolated Firefox profile under `TabburritoLite\profile`
- a rebranded project-local Firefox runtime: `TabburritoFirefox\tabburrito-browser.exe`

This keeps Tabburrito separate from your normal Firefox usage while also making it visually distinct in Task Manager, Alt-Tab, and the taskbar.

## Important Entry Points

For Firefox Lite, launch:

- `build\cargo-target-firefox-lite\release\tabburrito-lite.exe`

Do not launch the browser runtime directly unless you are debugging packaging:

- `build\cargo-target-firefox-lite\release\TabburritoFirefox\tabburrito-browser.exe`

The tray/controller logic lives in `tabburrito-lite.exe`. Launching the browser runtime directly bypasses tray behavior and Tabburrito startup management.

## Runtime Storage Rules

Everything is kept inside this project directory:

- Rust toolchains and caches live under `build\`
- Firefox Lite runtime data lives next to the Lite exe under `TabburritoLite\`
- rebranded Firefox runtime lives under `build\cargo-target-firefox-lite\release\TabburritoFirefox\`
- WebView2 runtime data lives next to the WebView2 exe under `TabburritoWebViewData\`

No intentional runtime storage should be left behind in the user profile for this project.

## Firefox Lite Highlights

- isolated Firefox profile launched with `--profile` and `--no-remote`
- rebranded runtime name: `tabburrito-browser.exe`
- tray shell for open, refresh, mute, close-tab, restart, autostart, reset, and diagnostics
- all 5 managed services are treated as the fixed Tabburrito workspace:
  - WhatsApp
  - Messenger
  - LinkedIn
  - Bluesky
  - Google Calendar
- LinkedIn ad blocking is handled in the isolated Firefox profile
- dark/light custom browser chrome

## Build

Use the project-local Rust toolchain wrapper:

```powershell
.\build_local.bat build --manifest-path tabburrito-lite\src-tauri\Cargo.toml
```

Or build packaged outputs with:

```powershell
.\release.bat lite
```

That produces:

- `build\cargo-target-firefox-lite\release\tabburrito-lite.exe`
- `build\cargo-target-firefox-lite\release\TabburritoFirefox\tabburrito-browser.exe`

## Other Docs

- [tabburrito-lite/README.md](tabburrito-lite/README.md)
- [ARCHITECTURE.md](ARCHITECTURE.md)
- [lessons.md](lessons.md)
