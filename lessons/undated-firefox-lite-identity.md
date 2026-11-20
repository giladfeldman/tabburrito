## Firefox Lite Identity

- Changing only the Tauri shell name/icon is not enough to distinguish a Firefox-based product from normal Firefox in Task Manager, Alt-Tab, or the taskbar.
- Windows mostly identifies the browser by the browser executable itself.
- The practical fix was packaging a project-local Firefox runtime and renaming it to `tabburrito-browser.exe`.
- Patching Windows metadata like `FileDescription`, `ProductName`, and `OriginalFilename` matters for visibility and clarity.
