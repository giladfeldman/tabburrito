## Hidden Console Windows

- Background PowerShell helpers can cause visible terminal flicker on Windows even when the main app is built as a windowed app.
- Periodic shell polling is especially noticeable and should be avoided.
- Helper commands should use hidden-window creation flags when they are unavoidable.
