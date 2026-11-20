"""Render probe for the end-to-end updater test.

Reads what the Settings panel of a running Tabburrito test copy actually SHOWS,
through WebView2's DevTools port (the app must have been started with
WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=0, which writes
DevToolsActivePort into the WebView2 user-data folder).

Usage: python cdp_settings_probe.py <data-root> [--timeout SECONDS]
Prints one JSON object: {"ok": bool, "version": str, "meta": str, "status": str,
"autoChecked": bool, "autoDisabled": bool, "error": str}. Exit 0 when the panel
was read, 1 otherwise. It never drives a real service page.
"""
import asyncio
import json
import pathlib
import sys
import time
import urllib.request

import websockets


def ports(root: pathlib.Path):
    found = []
    for f in root.rglob("DevToolsActivePort"):
        try:
            found.append(int(f.read_text().splitlines()[0]))
        except (OSError, ValueError, IndexError):
            pass
    return sorted(set(found))


def targets(port: int):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/json", timeout=3) as r:
            return json.load(r)
    except OSError:
        return []


async def evaluate(ws_url: str, expr: str):
    async with websockets.connect(ws_url, max_size=None) as ws:
        await ws.send(json.dumps({"id": 1, "method": "Runtime.evaluate",
                                  "params": {"expression": expr, "awaitPromise": True,
                                             "returnByValue": True}}))
        while True:
            msg = json.loads(await ws.recv())
            if msg.get("id") == 1:
                return msg.get("result", {}).get("result", {}).get("value")


def find(root, pred):
    for p in ports(root):
        for t in targets(p):
            if t.get("type") == "page" and pred(t.get("url", "")):
                return t
    return None


READ = """(async () => {
  const deadline = Date.now() + 15000;
  const $ = id => document.getElementById(id);
  while (Date.now() < deadline) {
    if ($('update-version') && $('update-version').textContent.trim() !== '—'
        && $('update-meta').textContent.trim() !== 'Reading…') break;
    await new Promise(r => setTimeout(r, 250));
  }
  return { version: $('update-version').textContent.trim(),
           meta: $('update-meta').textContent.trim(),
           status: $('update-status').textContent.trim(),
           autoChecked: $('set-auto-update').checked,
           autoDisabled: $('set-auto-update').disabled };
})()"""


async def main():
    root = pathlib.Path(sys.argv[1])
    timeout = float(sys.argv[sys.argv.index("--timeout") + 1]) if "--timeout" in sys.argv else 60
    deadline = time.time() + timeout
    out = {"ok": False, "error": ""}
    settings = None
    while time.time() < deadline and settings is None:
        settings = find(root, lambda u: "settings.html" in u)
        if settings is None:
            shell = find(root, lambda u: "tauri.localhost" in u or u.startswith("tauri://"))
            if shell is not None:
                await evaluate(shell["webSocketDebuggerUrl"],
                               "window.__TAURI__.core.invoke('toggle_settings', {show: true}).then(() => 1)")
            time.sleep(1)
    if settings is None:
        out["error"] = f"settings page not found (DevTools ports: {ports(root)})"
    else:
        try:
            out.update(await evaluate(settings["webSocketDebuggerUrl"], READ) or {})
            out["ok"] = bool(out.get("version"))
        except Exception as exc:  # report, never crash the harness
            out["error"] = repr(exc)
    print(json.dumps(out))
    return 0 if out["ok"] else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
