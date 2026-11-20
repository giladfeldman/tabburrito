## Cold Restore Bug

- A cold service must not be marked as loaded before it has actually been navigated back from `about:blank`.
- The bug caused Messenger, LinkedIn, and Bluesky to show blank views after switching away and back.
- Fix: on selection, show/focus the WebView and, if it is marked unloaded, navigate to the service URL and only then mark it loaded.
- Refresh must also navigate to the service URL rather than blindly reloading the current document, because the current document may be `about:blank`.
