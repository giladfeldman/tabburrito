## WebView2 Session Migration

- Chromium/WebView2 session files include `Default\Network\Cookies`, `Default\Login Data`, `Default\Preferences`, `Default\Secure Preferences`, `Default\History`, and `Default\Web Data`.
- Migrating only individual files is fragile; migrating the full `EBWebView` directory is safer.
- Migration from Firefox profiles to WebView2 is not directly compatible.
- Migration from WebView2 to Firefox is not directly compatible.
