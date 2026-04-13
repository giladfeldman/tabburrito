# Architecture

## Current Shape

The repo currently contains two product lines:

- Firefox Lite: the mainline product
- WebView2: a legacy/reference implementation

The architecture that matters most now is Firefox Lite.

## Firefox Lite Overview

Firefox Lite is split into two runtime parts:

1. `tabburrito-lite.exe`
   The Tauri controller. It owns tray behavior, shortcuts, startup, restart, quit, profile bootstrap, and diagnostics.

2. `tabburrito-browser.exe`
   The rebranded packaged Firefox runtime used only by the Lite controller.

The controller launches the browser runtime against a dedicated profile:

- `--profile <exe-folder>\TabburritoLite\profile`
- `--no-remote`

That gives Tabburrito an isolated browser world while still allowing the user’s normal Firefox to continue separately.

## Firefox Lite Responsibilities

### Controller

Implemented in:

- [tabburrito-lite/src-tauri/src/main.rs](/C:/Users/filin/Dropbox/Vibe/WindowsTuneUp/tabburrito-lite/src-tauri/src/main.rs)

Responsibilities:

- tray icon and tray menu
- global shortcuts
- startup and reopen behavior
- theme toggling
- refresh, mute, close-tab helpers
- profile reset and status output
- packaged runtime discovery
- shutdown ownership

### Browser Runtime

Packaged into:

- `build\cargo-target-firefox-lite\release\TabburritoFirefox\`

Important file:

- `tabburrito-browser.exe`

This runtime exists primarily so Windows surfaces can identify Tabburrito separately from normal Firefox.

### Profile Bootstrap

Profile assets come from:

- [tabburrito-lite/user.js](/C:/Users/filin/Dropbox/Vibe/WindowsTuneUp/tabburrito-lite/user.js)
- generated `userChrome.css`

Responsibilities:

- memory/performance prefs
- Firefox UI shaping
- title prefix and distinctive chrome
- LinkedIn filter file generation
- uBlock placement in the isolated profile

## Managed Services

The Lite workspace is defined around 5 services:

- WhatsApp
- Messenger
- LinkedIn
- Bluesky
- Google Calendar

The intended model is a fixed workspace, not an open-ended browser session.

## Build and Packaging

### Build isolation

Rust tooling and outputs are intentionally local to the project:

- `build\cargo-home\`
- `build\rustup-home\`
- `build\tools\`
- `build\cargo-target-firefox-lite\`
- `build\cargo-target-webview2\`

### Release packaging

`release.bat lite` does two things:

1. builds `tabburrito-lite.exe`
2. prepares `TabburritoFirefox\` by copying the local Firefox runtime, renaming the browser executable, and patching Windows-visible metadata

The runtime preparation step is:

- [prepare_firefox_runtime.bat](/C:/Users/filin/Dropbox/Vibe/WindowsTuneUp/prepare_firefox_runtime.bat)

## WebView2 Status

The root `src-tauri/` + `ui/` app is still in the repo as a reference implementation, but it is no longer the primary architectural direction for daily use.

It remains useful as:

- a source of UI ideas
- a record of embedded-shell behavior
- a fallback experiment track
