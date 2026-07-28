# Lessons

## WebView2 Is Main Again After Optimization

- The WebView2 model gives Tabburrito direct ownership of the visible window, which enables shell UX that Firefox Lite cannot cleanly provide.
- The original WebView2 memory problem was made worse by separate user-data folders per service.
- A shared WebView2 user-data folder is a better default for this app because it avoids multiplying browser/runtime process overhead.
- The current main product should be treated as WebView2 Portable, with Firefox Lite kept as an alternate experiment.

## Portable Runtime Data

- Runtime state must live beside the portable exe, not in a developer-specific user profile.
- WebView2 data belongs under `<exe-folder>\TabburritoWebViewData\main` for service webviews and `\shell` for the sidebar/urlbar UI.
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

## LinkedIn Feed Sort

- LinkedIn home feed has no reliable public URL param for Top vs Recent (unlike jobs `sortBy=DD`).
- Enforce sort by injecting a semantic UI clicker (Sort by → Recent/Top) and re-applying if LinkedIn resets.
- Persist preference in shell urlbar localStorage + Rust `LinkedInSortState`; default Recent.

## WebView2 Mute

- Sidebar mute must call WebView2 `ICoreWebView2_8::SetIsMuted` via `webview.with_webview` — UI/localStorage alone is a no-op for audio.
- Re-apply mute when creating or restoring service webviews.

## Unread DM Badges

- Title-total badges cannot separate 1:1 vs groups. Inject a DOM scraper and report via a title marker (`\u{2063}TB{n}\u{2063}`), then `on_document_title_changed` → sidebar event.
- Keep notify-tracked Messenger hot so cold-unload to `about:blank` does not zero badges.

- LinkedIn blocking in Firefox Lite uses the isolated profile/uBlock-oriented approach.
- Blocking should default to LinkedIn only unless a user explicitly enables it elsewhere.
- LinkedIn periodically ships an obfuscated-class feed redesign (hashed names like `._297bc8a0`, posts wrapped in `div[componentkey][role="listitem"]`). NEVER anchor the blocker on those hashed class names — they change. Anchor only on stable semantic attributes: `componentkey*="FeedType"` (one per post), `[role="listitem"]`, and legacy `urn:li:activity` ids.
- The blocker must be blast-radius-bounded so a single bad match can never blank the whole feed: resolve each marker to the *nearest single post* (never climb to a multi-post ancestor; refuse a candidate wrapping ≥2 posts), and apply a circuit breaker that stops hiding once >60% of loaded posts are gone. A 2026-06-18 regression hid the entire feed because the fallback climb resolved markers to a container spanning the whole stream.
- WebView2 cannot run full uBlock Origin (Chromium MV2 deprecation) — only uBO Lite (MV3), and extension loading isn't wired through wry/Tauri. "Real uBlock with max filters" belongs in the Firefox Lite variant, not WebView2.

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

## External Link Handoff

- Blanket `whatsapp.com` on the in-webview allowlist trapped chat links on redirect/wrapper pages; those pages often fail silently in WebView2 and feel "unclickable." Keep only operational hosts (`web.whatsapp.com`, `whatsapp.net`) in-webview; open `wa.me`, `chat.whatsapp.com`, and other `*.whatsapp.com` pages in the system browser.
- Native `on_navigation` + `on_new_window` cover most link paths, but WhatsApp/Messenger React UIs sometimes miss them. A tiny document-start click interceptor (`initialization_script_for_all_frames`) that routes disallowed hosts through `window.open` is the reliable fallback.
- Redirect wrappers (LinkedIn `/safety/go`, Facebook `/l.php?u=`, WhatsApp `/secure/link`) must be unwrapped in `normalize_external_url` and treated as external in `navigation_decision`.
- `on_new_window` should mirror `on_navigation`: internal URLs navigate the existing service webview; external URLs go to `rundll32 url.dll,FileProtocolHandler` on Windows (avoids shell-plugin `&` truncation).
- URL-bar navigation must use the same host policy; only `about:blank` close-tab bypasses it.

## Public Repo Hygiene

- Build artifacts, `target/`, generated schemas, runtime profiles, cookies, login databases, and personal migration backups must not be committed.
- Public docs should use relative paths, not developer-machine absolute paths.
- Scripts should not reference a specific user profile, email address, or local machine path.
