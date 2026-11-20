## Portable Runtime Data

- Runtime state must live beside the portable exe, not in a developer-specific user profile.
- WebView2 data belongs under `<exe-folder>\TabburritoWebViewData\main` for service webviews and `\shell` for the sidebar/urlbar UI.
- Firefox Lite data belongs under `<exe-folder>\TabburritoLite\profile`.
- Replacing the exe should not wipe cookies or sessions as long as the sibling runtime data folder is preserved.
- Old WebView2 data may exist under framework-default paths such as `AppData\Local\<app-id>\EBWebView`; migration is possible by copying the full `EBWebView` folder, but service sessions may still expire or reject the changed app identity.
