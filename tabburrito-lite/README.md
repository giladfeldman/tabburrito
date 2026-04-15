# Tabburrito Firefox Lite

Firefox Lite is the alternate Tabburrito runtime. It is kept in the repo as an isolated-Firefox experiment and fallback direction, while the optimized WebView2 app is currently the main product.

## What It Provides

- a small Tauri tray/controller app
- a dedicated Firefox profile under `<exe-folder>\TabburritoLite\profile`
- a rebranded local Firefox runtime under `TabburritoFirefox\`
- isolation from the user’s normal/default Firefox profile
- service launch/open/focus helpers
- dark/light profile chrome
- LinkedIn blocking support inside the isolated profile

## Entry Points

Use:

- `tabburrito-lite.exe`

Do not normally launch:

- `TabburritoFirefox\tabburrito-browser.exe`

The browser executable is only the managed Firefox runtime. Launching it directly bypasses the Tabburrito controller and tray behavior.

## Isolation

Firefox Lite launches with:

```text
--profile <exe-folder>\TabburritoLite\profile
--no-remote
```

That keeps cookies, logins, extensions, browser chrome, and session data separate from a user’s regular Firefox.

## Known Limits

Firefox Lite does not own the visible browser window. That means some shell behaviors are limited compared with WebView2:

- true minimize-to-tray for the browser window is not cleanly available
- intercepting all in-page links and forcing them to the system browser needs deeper extension/native integration
- taskbar/window identity requires a packaged/rebranded Firefox runtime

## Build

From the repo root:

```powershell
.\release.bat lite
```

Outputs:

- `build\cargo-target-firefox-lite\release\tabburrito-lite.exe`
- `build\cargo-target-firefox-lite\release\TabburritoFirefox\tabburrito-browser.exe`

## Runtime Data

Do not commit runtime data. The portable profile is created beside the exe:

- `TabburritoLite\profile\`
- `TabburritoLite\config.json`
- `TabburritoLite\status.json`

These files are user/session data and are intentionally ignored by git.
