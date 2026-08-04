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

Installed exe:

- `%LOCALAPPDATA%\Programs\Tabburrito\tabburrito.exe`

Runtime data:

- `%LOCALAPPDATA%\Tabburrito\TabburritoWebViewData\main\`

Program and user data are deliberately kept apart, so updating or reinstalling never
touches your sessions. See [`install/README.md`](install/README.md) for install,
auto-update, backup, and uninstall.

> **Never put the exe (or its data) inside a build output directory.** Sessions used to
> live next to an exe in `build\cargo-target-webview2\release\`; a build-cache cleanup
> deleted the whole directory on 2026-08-04 and every login was lost with no possible
> recovery. See `lessons.md`.

Portable mode (data beside the exe, for USB sticks) is opt-in: create an empty
`portable.txt` next to the exe. Only use it for an exe in a stable folder.

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

## Runtime Data Rules

**User data must never live inside a build output directory.** Anything under a cargo
target dir is disposable by definition and can be deleted by any tool at any time.

- WebView2 sessions: `%LOCALAPPDATA%\Tabburrito\TabburritoWebViewData\`
- Session backups: `%LOCALAPPDATA%\Tabburrito\Backups\`
- Build output: `%LOCALAPPDATA%\TabburritoBuild\` (outside the repo, safe to delete)
- Rust toolchain/cache wrappers for the legacy portable build: `build\`
- Firefox Lite data lives next to `tabburrito-lite.exe` under `TabburritoLite\`
- packaged Firefox runtime lives under `TabburritoFirefox\`

Back up sessions before any risky operation:

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Backup-TabburritoSessions.ps1
```

Do not commit runtime profiles, cookies, session stores, build outputs, or personal data.

## Development Notes

- `archive/` is ignored and may contain local experiments, old exes, migration backups, or cleanup snapshots.
- `node_modules/`, `build/`, `target/`, and runtime data folders are ignored.
- `lessons.md` records the major implementation discoveries and regressions fixed during development.

## Docs

- [ARCHITECTURE.md](ARCHITECTURE.md)
- [lessons.md](lessons.md)
- [tabburrito-lite/README.md](tabburrito-lite/README.md)
