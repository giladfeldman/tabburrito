## WebView2 Mute

- Sidebar mute must call WebView2 `ICoreWebView2_8::SetIsMuted` via `webview.with_webview` — UI/localStorage alone is a no-op for audio.
- Re-apply mute when creating or restoring service webviews.
