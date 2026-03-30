# Architecture

## Overview

Tabburrito is a Tauri v2 desktop application that uses a single native window with multiple child WebView2 instances to provide a lightweight multi-service web dock.

```
+----------------------------------------------------------+
|  Window (main)                                           |
|  +--------+---------------------------------------------+
|  |Sidebar |  URL Bar (urlbar webview)                    |
|  |webview |---------------------------------------------+|
|  |        |                                             ||
|  | [WA]   |  Service WebView (whatsapp/messenger/etc)   ||
|  | [MSG]  |                                             ||
|  | [LI]   |  Each service is a separate WebView2        ||
|  | [BS]   |  instance sharing the same renderer.        ||
|  | [CAL]  |  Only one is visible at a time.             ||
|  |        |                                             ||
|  | [mute] |                                             ||
|  | [ref]  |                                             ||
|  | [auto] |                                             ||
|  | [dark] |                                             ||
|  +--------+---------------------------------------------+
+----------------------------------------------------------+
```

## Technology Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| Window & Process | Tauri v2 (Rust) | Native window, tray icon, IPC, plugins |
| Rendering | WebView2 (Edge Chromium) | Web content rendering |
| Sidebar UI | Vanilla HTML/CSS/JS | Service icons, controls |
| URL Bar | Vanilla HTML/CSS/JS | URL display, zoom, adblock indicator |
| Service Content | External web pages | WhatsApp, Messenger, LinkedIn, etc. |

## File Structure

```
tabburrito/
├── ui/                          # Frontend (served as Tauri app pages)
│   ├── index.html               # Sidebar HTML
│   ├── app.js                   # Sidebar logic (service switching, state)
│   ├── styles.css               # Sidebar styles
│   ├── urlbar.html              # URL bar HTML
│   └── urlbar.js                # URL bar logic (zoom, navigation, adblock)
├── src-tauri/                   # Rust backend
│   ├── Cargo.toml               # Rust dependencies
│   ├── tauri.conf.json          # Tauri configuration
│   ├── build.rs                 # Tauri build script
│   ├── src/
│   │   └── main.rs              # App entry point, window setup, IPC commands
│   ├── capabilities/
│   │   └── default.json         # Tauri v2 security permissions
│   └── icons/                   # App icons (PNG, ICO)
├── package.json                 # Node.js deps (@tauri-apps/cli, @tauri-apps/api)
├── generate_icons.js            # Generates burrito icons programmatically
├── start_app.bat                # Dev helper: kill + restart
└── .gitignore
```

## Key Design Decisions

### Multi-webview in a single window (unstable API)

Tauri v2's `unstable` feature enables `Window::add_child()` to place multiple WebView2 instances inside one native window. This avoids the Electron pattern of one window per service.

- **Sidebar**: child webview at (0, 0), width 56px
- **URL bar**: child webview at (56, 0), height 32px
- **Services**: child webviews at (56, 32), filling remaining space
- All use `auto_resize()` with ratios computed from the monitor work area

### Service pre-creation

All 5 service webviews are created at startup (hidden). Switching services just shows/hides them via `Webview::show()`/`Webview::hide()`. This preserves login state and avoids reload delays.

### LinkedIn ad blocker

JavaScript injected via both `initialization_script` and `on_page_load` → `eval()`:
1. **CSS rules** hide known ad elements (`.ad-banner-container`, etc.)
2. **TreeWalker** scans all text nodes for "Promoted" / "Promoted by" labels (< 40 chars)
3. **Element scan** checks short `<p>` and `<span>` elements for keywords
4. **MutationObserver** (debounced, self-pausing) catches new content from infinite scroll
5. Container detection walks up to `div[componentkey]` with `h2 "Feed post"` or `div.relative`

### Google Calendar authentication

Google blocks OAuth in embedded webviews. Workaround: load `accounts.google.com/ServiceLogin` with Calendar as the redirect target, forcing the standard login flow.

## Tauri Plugins

| Plugin | Purpose |
|--------|---------|
| `tauri-plugin-single-instance` | Prevents duplicate processes |
| `tauri-plugin-window-state` | Persists window position/size |
| `tauri-plugin-autostart` | Optional Windows startup launch |
| `tauri-plugin-shell` | Shell integration |

## IPC Commands

| Command | Description |
|---------|-------------|
| `show_service(label)` | Show a service webview, hide others |
| `refresh_service(label)` | Reload a service to its default URL |
| `navigate_service(label, url)` | Navigate a service to a custom URL |
| `zoom_service(label, zoom)` | Set zoom level for a service |
| `get_autostart_enabled()` | Check if autostart is enabled |
| `set_autostart_enabled(enabled)` | Toggle autostart |

## State Management

- **Sidebar state** (`localStorage: tabburrito`): active service, mute, dark mode, notification service list
- **URL bar state** (`localStorage: tabburrito_urlbar`): per-service zoom levels, custom URLs, adblock toggle
- **Window state**: managed by `tauri-plugin-window-state` (position, size, maximized)
- **Login sessions**: WebView2 persists cookies/localStorage in `%LOCALAPPDATA%\com.tabburrito.app\`
