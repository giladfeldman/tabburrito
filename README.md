# Tabburrito

A lightweight multi-service web app dock built with [Tauri](https://tauri.app). Replaces Electron-based apps like Ferdium with a native, memory-efficient alternative.

**Memory usage**: ~35 MB base + ~100-150 MB per active service (shared WebView2 renderer)
compared to Ferdium's 3+ GB for the same services.

## Services

- WhatsApp Web
- Facebook Messenger
- LinkedIn (with built-in ad blocker)
- Bluesky
- Google Calendar

## Features

- **Single window** — sidebar with service icons, content area with native WebView2
- **URL bar** — view and edit the current URL per service
- **Zoom controls** — per-service zoom level, remembered across restarts
- **System tray** — minimize to tray, double-click to restore, right-click for menu
- **Close to tray** — closing the window hides it instead of quitting
- **Single instance** — launching again focuses the existing window
- **Remember last service** — restores your last active tab on startup
- **Window state** — remembers position and size across restarts
- **Autostart** — optional, toggle from the sidebar (power icon)
- **Dark mode** — toggle from the sidebar (moon icon)
- **LinkedIn ad blocker** — hides Promoted posts, Suggested content, sidebar ads. Uses JavaScript injection mimicking uBlock Origin filter rules. Toggle from the URL bar indicator.
- **Google sign-in** — works via accounts.google.com redirect flow (Google blocks embedded webview OAuth)
- **Keyboard shortcuts**:
  - `Ctrl+1-5` — switch between services
  - `Ctrl+R` — refresh current service
  - `Ctrl+M` — mute/unmute
  - `Ctrl+D` — toggle dark mode
  - `Ctrl+=`/`Ctrl+-` — zoom in/out

## Requirements

- Windows 10 (1803+) or Windows 11
- WebView2 Runtime (pre-installed on Windows 11)

## Quick Start

Download `tabburrito.exe` from the [Releases](https://github.com/giladfeldman/tabburrito/releases) page and run it. No installation needed.

## Building from Source

### Prerequisites

- [Rust](https://rustup.rs/) (1.70+)
- [Node.js](https://nodejs.org/) (18+)
- WebView2 Runtime

### Build

```bash
npm install
cargo build --release --manifest-path src-tauri/Cargo.toml
```

The release binary is at `src-tauri/target/release/tabburrito.exe` (12 MB).

### Development

```bash
npm install
npx tauri dev
```

### Generate Icons

```bash
node generate_icons.js
```

## License

MIT
