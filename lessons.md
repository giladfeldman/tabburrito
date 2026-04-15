# Lessons

## WebView2 Is Main Again After Optimization

- The WebView2 model gives Tabburrito direct ownership of the visible window, which enables shell UX that Firefox Lite cannot cleanly provide.
- The original WebView2 memory problem was made worse by separate user-data folders per service.
- A shared WebView2 user-data folder is a better default for this app because it avoids multiplying browser/runtime process overhead.
- The current main product should be treated as WebView2 Portable, with Firefox Lite kept as an alternate experiment.

## Portable Runtime Data

- Runtime state must live beside the portable exe, not in a developer-specific user profile.
- WebView2 data belongs under `<exe-folder>\TabburritoWebViewData\main`.
- Firefox Lite data belongs under `<exe-folder>\TabburritoLite\profile`.
- Replacing the exe should not wipe cookies or sessions as long as the sibling runtime data folder is preserved.
- Old WebView2 data may exist under framework-default paths such as `AppData\Local\<app-id>\EBWebView`; migration is possible by copying the full `EBWebView` folder, but service sessions may still expire or reject the changed app identity.

## WebView2 Memory Work

- Keeping every service hot all the time is convenient but expensive.
- A service temperature model is the practical compromise.
- WhatsApp and Google Calendar are currently hot services.
- Messenger, LinkedIn, and Bluesky are cold services.
- Cold services should not unload immediately on tab switch because that breaks normal use and causes blank restores.
- A grace-period unload is better: short switches remain instant, longer inactive periods can release memory.

## Cold Restore Bug

- A cold service must not be marked as loaded before it has actually been navigated back from `about:blank`.
- The bug caused Messenger, LinkedIn, and Bluesky to show blank views after switching away and back.
- Fix: on selection, show/focus the WebView and, if it is marked unloaded, navigate to the service URL and only then mark it loaded.
- Refresh must also navigate to the service URL rather than blindly reloading the current document, because the current document may be `about:blank`.

## WebView2 Session Migration

- Chromium/WebView2 session files include `Default\Network\Cookies`, `Default\Login Data`, `Default\Preferences`, `Default\Secure Preferences`, `Default\History`, and `Default\Web Data`.
- Migrating only individual files is fragile; migrating the full `EBWebView` directory is safer.
- Migration from Firefox profiles to WebView2 is not directly compatible.
- Migration from WebView2 to Firefox is not directly compatible.

## LinkedIn Blocking

- LinkedIn blocking in WebView2 uses script-based page filtering.
- LinkedIn blocking in Firefox Lite uses the isolated profile/uBlock-oriented approach.
- Blocking should default to LinkedIn only unless a user explicitly enables it elsewhere.

## Firefox Lite Identity

- Changing only the Tauri shell name/icon is not enough to distinguish a Firefox-based product from normal Firefox in Task Manager, Alt-Tab, or the taskbar.
- Windows mostly identifies the browser by the browser executable itself.
- The practical fix was packaging a project-local Firefox runtime and renaming it to `tabburrito-browser.exe`.
- Patching Windows metadata like `FileDescription`, `ProductName`, and `OriginalFilename` matters for visibility and clarity.

## Firefox Lite Controller Limits

- `tabburrito-lite.exe` is the controller.
- `tabburrito-browser.exe` is only the browser runtime.
- Launching the browser runtime directly bypasses tray behavior and Tabburrito startup management.
- Because Firefox owns the visible window, true minimize-to-tray and complete in-page link interception are not cleanly available without a Firefox extension/native bridge or window-hooking layer.

## Startup And Tab Management

- Relying on browser session restore produced unstable results.
- Tabburrito should deterministically create or restore its managed service workspace.
- One service should correspond to one managed service view.
- Duplicate tabs/views usually indicate that startup or service-switch logic is opening instead of focusing/restoring.

## Hidden Console Windows

- Background PowerShell helpers can cause visible terminal flicker on Windows even when the main app is built as a windowed app.
- Periodic shell polling is especially noticeable and should be avoided.
- Helper commands should use hidden-window creation flags when they are unavoidable.

## Public Repo Hygiene

- Build artifacts, `target/`, generated schemas, runtime profiles, cookies, login databases, and personal migration backups must not be committed.
- Public docs should use relative paths, not developer-machine absolute paths.
- Scripts should not reference a specific user profile, email address, or local machine path.
