# Lessons

## Firefox Lite Identity

- Changing only the Tauri shell name/icon is not enough to distinguish Tabburrito from normal Firefox in Task Manager, Alt-Tab, or the taskbar.
- Windows mostly identifies the browser by the browser executable itself.
- The practical fix was packaging a project-local Firefox runtime and renaming it to `tabburrito-browser.exe`.
- Patching Windows metadata like `FileDescription`, `ProductName`, and `OriginalFilename` matters for visibility and clarity.

## Controller Versus Runtime

- `tabburrito-lite.exe` is the controller.
- `tabburrito-browser.exe` is only the browser runtime.
- If the browser runtime is launched directly, tray behavior and Tabburrito-specific lifecycle control are bypassed.
- Documentation and scripts must make this distinction explicit.

## Startup Behavior

- Relying on Firefox session restore produced unstable results after the runtime was rebranded.
- Generic Firefox welcome/reset flows can leak back in if startup is left to Firefox defaults.
- Tabburrito Lite needs deterministic startup behavior controlled by the controller, not vague browser session assumptions.

## Tab Management

- A lightweight Ctrl+1..5 tab-switching model is workable only if the managed workspace remains stable.
- If the controller also opens new tabs opportunistically, duplication appears quickly.
- The intended product behavior is one fixed managed workspace, not a drifting browser session.
- When the product goal is “one service = one tab”, the controller must behave conservatively and avoid repeatedly creating new tabs.

## Tray Ownership

- The tray/controller must own quit behavior, not just the initial browser launch.
- Killing only the original launcher child is not enough because Firefox can outlive or detach from the immediate child process.
- Shutdown needs profile-scoped or runtime-scoped process cleanup so quitting Tabburrito actually quits Tabburrito.

## Hidden Console Windows

- Background PowerShell helpers can cause visible terminal flicker on Windows even when the main app is built as a windowed app.
- Periodic background polling that shells out every few seconds is especially noticeable and unacceptable for a tray utility.
- Helper commands should use hidden-window creation flags on Windows.
- Avoid frequent shell polling unless it is absolutely necessary.

## Runtime Locality

- Keeping all build outputs, toolchains, profiles, and runtime data inside the project directory makes iteration much safer.
- It also makes the portable distribution story much cleaner and much easier to debug.
- This rule should continue to be enforced for Rust, Firefox Lite, and any legacy WebView2 artifacts.

## Product Direction

- Firefox Lite is now the primary daily-driver direction.
- WebView2 remains useful as a reference implementation but should not drive the main architecture anymore.
- Memory savings alone are not enough; operational clarity matters too.
- A product that is lightweight but confusing to identify or control is still not good enough.
