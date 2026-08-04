# Architecture

## Current Shape

The repo contains two product tracks:

- WebView2 Portable: current main product
- Firefox Lite: alternate isolated-Firefox experiment

The WebView2 app is now the main direction because it gives Tabburrito ownership of the visible window and shell controls while staying reasonably memory-conscious after optimization.

## WebView2 Portable

Implemented in:

- `src-tauri/src/main.rs`
- `ui/`

Runtime entrypoint:

- `tabburrito.exe`

Data folder (resolved by `data_root()` in `src-tauri/src/main.rs`):

- Installed (default): `%LOCALAPPDATA%\Tabburrito\TabburritoWebViewData\main\`
- Portable (opt-in, requires a `portable.txt` marker next to the exe):
  `<exe-folder>\TabburritoWebViewData\main\`

The app uses one shared WebView2 user-data folder rather than one folder per service. This reduces process/runtime overhead.

Data is separated from the exe so installing, updating, or reinstalling never disturbs sessions. Portable mode is opt-in because the default-portable layout caused total session loss on 2026-08-04: the exe lived in a cargo target directory, and cleaning the build cache deleted the sessions stored beside it. `migrate_legacy_data_dir()` adopts a legacy exe-adjacent folder once, only when the new root does not already exist.

## Managed Services

The workspace is intentionally fixed:

- WhatsApp
- Messenger
- LinkedIn
- Bluesky
- Google Calendar

Default service temperature:

- hot: WhatsApp, Google Calendar
- cold after inactivity: Messenger, LinkedIn, Bluesky

Cold services are hidden normally during short switches. After the inactivity grace period, they are navigated to `about:blank` to release memory. When selected again, the controller navigates them back to their service URL automatically.

## WebView2 Shell Responsibilities

The WebView2 shell owns:

- sidebar service switching
- URL/address bar
- refresh/open controls
- per-service navigation
- LinkedIn ad/noise filtering
- external-link handoff to the system default browser
- portable WebView2 storage location
- single-instance behavior
- window/tray behavior where supported by Tauri

## Firefox Lite

Implemented in:

- `tabburrito-lite/src-tauri/src/main.rs`
- `tabburrito-lite/user.js`

Runtime entrypoints:

- `tabburrito-lite.exe`: controller
- `tabburrito-browser.exe`: rebranded local Firefox runtime

Firefox Lite launches the browser runtime with:

- `--profile <exe-folder>\TabburritoLite\profile`
- `--no-remote`

This isolates it from the user’s normal Firefox profile. It remains useful, but the controller does not own the visible Firefox window, so behaviors like true minimize-to-tray and intercepting all in-page link behavior are limited without deeper Firefox extension/native integration.

## Build Isolation

Build tooling and outputs are intentionally local:

- `build\cargo-home\`
- `build\rustup-home\`
- `build\tools\`
- `build\cargo-target-webview2\`
- `build\cargo-target-firefox-lite\`

The wrapper `build_local.bat` copies `cargo.exe` and `rustup.exe` from `PATH` into `build\tools\` when needed, then uses local Cargo/Rustup home directories.

## Release Helper

`release.bat` supports:

- `webview2`
- `lite`
- `all`

Examples:

```powershell
.\release.bat webview2
.\release.bat lite
.\release.bat all
```

## Public Repo Hygiene

Do not commit:

- `target/`
- `build/`
- `node_modules/`
- runtime profiles
- `TabburritoWebViewData/`
- `TabburritoLite/`
- cookies, login databases, session stores, or migration backups
