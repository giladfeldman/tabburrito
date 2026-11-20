## Firefox Lite Controller Limits

- `tabburrito-lite.exe` is the controller.
- `tabburrito-browser.exe` is only the browser runtime.
- Launching the browser runtime directly bypasses tray behavior and Tabburrito startup management.
- Because Firefox owns the visible window, true minimize-to-tray and complete in-page link interception are not cleanly available without a Firefox extension/native bridge or window-hooking layer.
