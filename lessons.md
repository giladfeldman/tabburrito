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

## Notifications, DND, And Palette

- Per-service notify modes (`off` / `badge` / `full`) + global DND/snooze belong in shell localStorage and must gate tray/native notification fan-out.
- Ctrl+K command palette is the right home for low-frequency ops (profiles, resource modes, backup/restore) so the sidebar stays lean.
- Tray tooltip should summarize DM unread totals so the dock stays useful when the window is hidden.

## Profiles And Resource Modes

- Work / Personal / Focus profiles are shell presets over notify + unload policy — not separate WebView2 user-data trees (that would multiply memory cost).
- Lean / Balanced / Instant map to unload aggressiveness; Instant keeps more services hot.

## Portable Backup / Restore

- `backup_portable_state` / `restore_portable_state` must copy shell prefs + document which runtime folders matter; never treat wiping `TabburritoWebViewData` as part of a normal rebuild.

## Never Store User Data Inside A Build Output Directory

**2026-08-04 — total session loss. The defining incident for this project.**

The release exe lived at `build\cargo-target-webview2\release\tabburrito.exe`, and
`webview_data_dir()` resolved to `<exe-dir>\TabburritoWebViewData`. That put every
logged-in session **inside a cargo target directory**. A build-cache cleanup deleted
`release\` and all sessions with it (WhatsApp, Messenger, LinkedIn, Bluesky, Calendar).

Recovery was impossible — every avenue failed at once:

- `TabburritoWebViewData/` **and** `build/` are both gitignored → never in version control
- File History service: **Stopped**
- No system restore points
- Nothing in the Recycle Bin (deleted programmatically, not via shell)

The earlier lesson here said "do not clean/delete the data folder" — a *procedural*
rule guarding a *structurally unsafe* layout. It failed, because a cargo target
directory is disposable by definition and every tool that touches it is entitled to
delete it. Discipline cannot protect data stored somewhere designed to be erased.

Rules now enforced in code and installer:

- User data belongs in `%LOCALAPPDATA%\Tabburrito\TabburritoWebViewData` — see
  `data_root()` in `src-tauri/src/main.rs`.
- The installed exe belongs in `%LOCALAPPDATA%\Programs\Tabburrito` (per-user, so
  updates need no elevation).
- Build output goes to `%LOCALAPPDATA%\TabburritoBuild`, **outside the repo**, so
  cleaning it can never reach user data.
- Portable mode (data next to the exe) is now **opt-in** via a `portable.txt` marker,
  never the default, and must never be enabled for an exe inside a build directory.
- `migrate_legacy_data_dir()` adopts any legacy exe-adjacent folder once, and only
  when the new root does not exist, so it can never clobber live sessions.
- Uninstall keeps sessions unless `-PurgeData` is passed explicitly.

Generalized: **irreplaceable state must never live under a path any tool treats as a
cache.** Ask "what happens if something deletes this whole directory?" — if the answer
is "we lose data", the layout is wrong, not the tooling. And an unbacked-up folder is
one command away from gone: `install\Backup-TabburritoSessions.ps1` exists because
nothing here was recoverable.

## LinkedIn Blocking

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
