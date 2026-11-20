## External Link Opening

- Blanket `whatsapp.com` on the in-webview allowlist trapped chat links on redirect/wrapper pages; those pages often fail silently in WebView2 and feel "unclickable." Keep only operational hosts (`web.whatsapp.com`, `whatsapp.net`) in-webview; open `wa.me`, `chat.whatsapp.com`, and other `*.whatsapp.com` pages in the system browser.
- Native `on_navigation` + `on_new_window` cover most link paths, but WhatsApp/Messenger React UIs sometimes miss them. A tiny document-start click interceptor (`initialization_script_for_all_frames`) that routes disallowed hosts through `window.open` is the reliable fallback.
- Redirect wrappers (LinkedIn `/safety/go`, Facebook `/l.php?u=`, WhatsApp `/secure/link`) must be unwrapped in `normalize_external_url` and treated as external in `navigation_decision`.
- `on_new_window` should mirror `on_navigation`: internal URLs navigate the existing service webview; external URLs go to `rundll32 url.dll,FileProtocolHandler` on Windows (avoids shell-plugin `&` truncation).
- URL-bar navigation must use the same host policy; only `about:blank` close-tab bypasses it.
