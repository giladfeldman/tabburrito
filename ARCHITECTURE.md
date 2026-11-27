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

The workspace is a fixed set of services:

- WhatsApp
- Messenger
- LinkedIn
- Bluesky
- X (added 2026-11-04; starts switched off)
- Google Calendar

Signal is deliberately absent: it has no official web client, only Signal
Desktop (Electron), so it cannot be hosted in a webview tab.

The user can reorder the sidebar (drag, or right-click → Move up/down) and
switch any tab off (right-click → Turn off). A switched-off tab's webview is
destroyed (`unload_service`), so it costs no memory; one click on its dimmed
icon recreates and opens it. Order and off-state live in the sidebar's
localStorage; the sidebar asks Rust to warm WhatsApp/Messenger at startup via
`preload_services` because only it knows which tabs are off.

Default service temperature:

- hot: WhatsApp, Messenger (their unread counts must stay live in every notify mode), Google Calendar
- cold after inactivity: LinkedIn, Bluesky, X

Cold services are hidden normally during short switches. After the inactivity grace period, they are navigated to `about:blank` to release memory. When selected again, the controller navigates them back to their service URL automatically.

## WebView2 Shell Responsibilities

The WebView2 shell owns:

- sidebar service switching
- URL/address bar
- refresh/open controls
- per-service navigation
- LinkedIn ad/noise filtering
- cookie/consent banner suppression on every service tab
- external-link handoff to the system default browser
- portable WebView2 storage location
- single-instance behavior
- window/tray behavior where supported by Tauri

### Feed filters (LinkedIn, X, Bluesky)

- `LINKEDIN_ADBLOCK_JS` hides promoted posts by their visible label. Labels
  come in compound forms ("with 4 others • Promoted", "Promoted • Partnership
  with X"), so the label is split on the bullet before matching.
- `LINKEDIN_FEED_SORT_JS` drives LinkedIn's "Select feed view: Most recent
  first / Most relevant first" menu (renamed from "Sort by" in 2026-11); the
  feed type is also readable from item `componentkey` suffixes
  (`MAIN_FEED_RECENT` / `MAIN_FEED_RELEVANCE`). At most 3 attempts a minute.
- `LINKEDIN_FEED_FOCUS_JS` (Settings > LinkedIn > "Hide posts from strangers", default on) hides, on the home feed only, posts from people you do not follow that no contact liked or reposted, and "Followed by" posts. It has a circuit breaker that stops hiding if the page markup stops matching, re-checks recycled feed elements, and matches "follows" per line. Offline test: `node tests/linkedin-focus.test.js` (fake DOM, reads the const from `src-tauri/src/main.rs`).
- `X_CLEANUP_JS` (on page load, gated by the AdBlock toggle) hides promoted
  posts (`placementTracking`, "Ad" label), timeline modules such as "Who to
  follow", the right column except search, and Grok/Premium nav entries; it
  opens the chronological "Following" tab once per load.
- `FOREIGN_FILTER_JS` (document start; toggled from the URL bar's
  "All languages / English only" button, no reload) hides non-English posts
  using each site's own language signal: LinkedIn's translatable-commentary
  wrapper (only present when LinkedIn offers "Show translation"), the `langs`
  each Bluesky post record declares (read from feed API responses via a fetch
  wrapper), and X's `lang` attribute on tweet text. No model is involved.

### Tracking prevention and AI entry points

- Tracking prevention is STRICT in normal use and drops to BALANCED while any
  tab is on a login/verification URL (`is_login_url`). STRICT alone broke X's
  login: it treats X's CDN (abs.twimg.com) as a tracker. The level belongs to
  the shared profile, so it cannot differ per tab.
- `AI_HIDE_CSS` hides AI entry points verified on the live sites (WhatsApp's
  "Meta AI" button); X's Grok entries are in `X_CLEANUP_JS`.

### User agent

Service webviews send a Chrome-shaped UA carrying the real WebView2 major
version (`chrome_ua()`). A pinned older version disagreed with the Sec-CH-UA
client hints, and X refused the login as automated.

### Cookie / consent banners

`COOKIE_CONSENT_JS` (`src-tauri/src/main.rs`) is injected into every service
tab at document start, in every frame. On each sweep it locates containers
whose own text carries a cookie/consent phrase, clicks an unambiguous
reject/decline control, then hides the container so it never shows even if the
site ignores the click.

Three guards bound the blast radius, each verified against a live LinkedIn page
and synthetic DOMs on 2026-08-12:

- a reject-shaped button is never clicked unless its container also carries
  consent copy AND an accept control — Messenger message requests and LinkedIn
  invitations have "Decline"/"Ignore" buttons that must not be pressed;
- a container is never hidden if doing so leaves under 400 characters of other
  page text. That shape is a full-page consent gate (Google's "Before you
  continue"), and hiding it would leave a blank tab;
- containers holding a password field are skipped, and scroll-lock is only
  released for containers that actually looked modal.

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
