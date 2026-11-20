## Testing Against The Live Sites (2026-11-04)

- `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=0` (the app
  appends its own flags) gives each WebView2 browser process its own port;
  read it from `DevToolsActivePort` in `TabburritoWebViewData\main\EBWebView`
  (services) or `...\shell\EBWebView` (sidebar/URL bar). Port 9222 for both
  collides: only the first process gets it.
- Never test messaging services from a COPY of the profile: WhatsApp and
  Messenger keep end-to-end session state, and a copy that receives messages
  can leave the real app missing them.
- Hidden tabs throttle timers to near-zero; bring a tab to the front
  (`showService`) before any test that awaits a `setTimeout`.
- LinkedIn's feed scrolls inside `main#workspace`, not the window.
- Do not leave the debug port on for a login: X refused the login as
  automated (alongside a pinned old UA version). Restart without it.
