# Tabburrito

Tabburrito is a portable Windows dock for a small fixed set of web services:

- WhatsApp
- Messenger
- LinkedIn
- Bluesky
- Google Calendar

The current main product is the WebView2 build. It provides a native Tauri shell with a sidebar, address bar, refresh/open controls, LinkedIn ad filtering, external-link handoff, and a memory-conscious hot/cold service model.

## Product Tracks

### Main: WebView2 Portable

Source:

- `src-tauri/`
- `ui/`

Release exe:

- `build\cargo-target-webview2\release\tabburrito.exe`

Runtime data:

- `TabburritoWebViewData\main\` next to the running exe

That means a portable copy can carry its own sessions, cookies, local storage, and cache with it. Replacing the exe should not force re-login as long as the sibling `TabburritoWebViewData` folder is kept.

### Alternate: Firefox Lite

Source:

- `tabburrito-lite/`

Release exe:

- `build\cargo-target-firefox-lite\release\tabburrito-lite.exe`

Firefox Lite uses an isolated Firefox profile and a rebranded local Firefox runtime. It remains useful as an alternate low-memory direction, but it has practical limitations because the visible browser window is still Firefox-owned rather than shell-owned.

## WebView2 Behavior

The WebView2 app is optimized around a small service workspace:

- always loaded: WhatsApp and Google Calendar
- cold-load after inactivity: Messenger, LinkedIn, and Bluesky
- cold services are restored automatically when selected
- LinkedIn ad/noise blocking is enabled by default
- new windows are opened in the system default browser
- app data is stored relative to the portable exe

The cold-load model is a memory tradeoff. It saves RAM by navigating inactive cold services to `about:blank` after a grace period, then reloading them automatically when selected.

## Build

Use the project-local build wrapper:

```powershell
.\build_local.bat build --release --manifest-path src-tauri\Cargo.toml
```

Or use the release helper:

```powershell
.\release.bat webview2
```

Build both maintained tracks:

```powershell
.\release.bat all
```

Build outputs are intentionally ignored by git and live under `build\`.

## Portable Runtime Rules

Tabburrito is designed so project/runtime data is local to the portable folder:

- Rust toolchain/cache wrappers live under `build\`
- WebView2 data lives next to `tabburrito.exe` under `TabburritoWebViewData\`
- Firefox Lite data lives next to `tabburrito-lite.exe` under `TabburritoLite\`
- packaged Firefox runtime lives under `TabburritoFirefox\`

Do not commit runtime profiles, cookies, session stores, build outputs, or personal data.

## Development Notes

- `archive/` is ignored and may contain local experiments, old exes, migration backups, or cleanup snapshots.
- `node_modules/`, `build/`, `target/`, and runtime data folders are ignored.
- `lessons.md` records the major implementation discoveries and regressions fixed during development.

## Docs

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [lessons.md](lessons.md)
- [tabburrito-lite/README.md](tabburrito-lite/README.md)
