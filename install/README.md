# Tabburrito — Windows install

Installs Tabburrito as a real Windows application, with sessions stored where
Windows expects user data and an updater that tracks GitHub.

## Why this exists

Before this, the "release" exe lived at
`build\cargo-target-webview2\release\tabburrito.exe` — **inside the cargo build
output directory** — with the WebView2 session folder sitting next to it.

Cargo target directories are disposable by definition. On **2026-08-04** a
build-cache cleanup deleted that directory, taking every logged-in session with
it. Recovery was impossible: the folder was gitignored (never in version
control), File History was off, there were no restore points, and nothing was in
the Recycle Bin.

The fix is structural, not procedural — program files and user data now live in
locations no build tool will ever touch:

| What | Where | Survives rebuild? |
|---|---|---|
| Program | `%LOCALAPPDATA%\Programs\Tabburrito\` | yes |
| Sessions / logins | `%LOCALAPPDATA%\Tabburrito\TabburritoWebViewData\` | yes |
| Backups | `%LOCALAPPDATA%\Tabburrito\Backups\` | yes |
| Build output | `%LOCALAPPDATA%\TabburritoBuild\` | disposable by design |

Per-user (`%LOCALAPPDATA%\Programs`) rather than `Program Files` is deliberate:
it is the same convention VS Code, Slack, and Discord use, and it means the
updater can replace the exe **without an elevation prompt**.

## Install

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Install-Tabburrito.ps1
```

Builds must exist first. To build from source:

```powershell
$env:CARGO_TARGET_DIR="$env:LOCALAPPDATA\TabburritoBuild\cargo-target"
cargo build --release --manifest-path .\src-tauri\Cargo.toml
```

## Auto-update from GitHub

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Register-AutoUpdate.ps1
```

Registers a hidden scheduled task that runs at logon (+5 min) and daily. Each
run fetches the tracked remote branch; if there are new commits it fast-forwards,
rebuilds, and reinstalls.

Safety properties:

- **A failed build never replaces a working install** — the installed exe is
  only swapped after a successful compile.
- **Uncommitted local changes block the pull** rather than being clobbered.
- **Diverged branches abort** instead of force-merging.
- Sessions are never touched at any point.

Check manually / force a rebuild:

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Update-Tabburrito.ps1 -Force
```

Log: `%LOCALAPPDATA%\TabburritoBuild\update.log`

## Back up sessions

Re-logging in to five services is tedious; back them up.

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Backup-TabburritoSessions.ps1
```

**Close Tabburrito first.** WebView2 keeps its databases open while running, so a
hot backup can capture a torn snapshot — the script refuses to run unless the app
is closed (override with `-Force`, accepting that risk). Keeps the 10 most recent
backups and errors out rather than writing an implausibly small archive.

Restore the newest backup:

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Backup-TabburritoSessions.ps1 -Restore
```

Restore moves the current folder aside as `...replaced-<timestamp>` before
overwriting, so a restore is itself reversible.

### Automatic weekly backups

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Register-SessionBackup.ps1
```

Runs weekly (Sunday 13:00 by default; `-Day`/`-At` to change, `-Remove` to
unregister). The task passes `-SkipIfRunning`, so a week where Tabburrito
happens to be open is **skipped and exits 0** rather than reporting a failure
or capturing a torn snapshot. Manual runs still refuse outright.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Uninstall-Tabburrito.ps1
```

**Sessions are kept by default.** Removing the program is not consent to delete
your logins. Pass `-PurgeData` to delete them too — that is irreversible.

## Portable mode

To run from a USB stick, create an empty `portable.txt` next to the exe. Data
then lives in `<exe-dir>\TabburritoWebViewData` as before.

Only do this when the exe sits in a stable folder. **Never enable portable mode
for an exe inside a build output directory** — that is the exact configuration
that caused the 2026-08-04 loss.
