# Tabburrito — Windows install and updates

Tabburrito is installed from a release on GitHub and keeps itself up to date
from later releases. No Rust, no source checkout and no build tools are needed
on the machine that runs it.

## Where things live

| What | Where | Touched by install / update / uninstall? |
|---|---|---|
| Program | `%LOCALAPPDATA%\Programs\Tabburrito\` | yes — replaced on every update |
| Sessions / logins | `%LOCALAPPDATA%\Tabburrito\TabburritoWebViewData\` | **never** |
| Backups | `%LOCALAPPDATA%\Tabburrito\Backups\` | never |
| Update log and on/off setting | `%LOCALAPPDATA%\Tabburrito\update.log`, `update-prefs.json` | never |

Program and logins are deliberately in different folders. On **2026-08-04** a
build-cache cleanup deleted an exe folder that also held the sessions, and every
login was lost with no way to recover it. Tauri's stock per-user installer
would install into `%LOCALAPPDATA%\Tabburrito` — the sessions folder — so
Tabburrito ships a copy of the Tauri installer template with that one line
changed (`src-tauri/windows/installer.nsi`, marked `TABBURRITO CHANGE`).

Per-user (`%LOCALAPPDATA%\Programs`) rather than `Program Files` is the same
convention VS Code, Slack and Discord use: updates need no administrator prompt.

## Install

Download `Tabburrito_<version>_x64-setup.exe` from
<https://github.com/giladfeldman/tabburrito/releases/latest> and run it.

Moving from the old script-installed copy (before 0.2.0) needs nothing extra:
the setup program installs over it in the same folder, and the logins in
`%LOCALAPPDATA%\Tabburrito` carry over. On its first start the new version
deletes the old `Tabburrito Auto-Update` scheduled task (which rebuilt from
source) and the old `install-manifest.json`.

One wrinkle: the old copy's entry in Windows "Apps" points at the old
uninstall script, which no longer exists. If the setup program offers
**Uninstall before installing**, choose **Do not uninstall** instead (or it
reports "unable to uninstall" and returns to that page). To avoid the question,
remove the stale entry first - this deletes only that registry entry, and only
if it is the old script's:

```powershell
$k = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Tabburrito'; if ((Get-ItemProperty $k -ErrorAction SilentlyContinue).UninstallString -like '*Uninstall-Tabburrito.ps1*') { Remove-Item $k }
```

The installer is not Authenticode-signed (no paid certificate), so Windows
SmartScreen may ask "Windows protected your PC" on first install: choose
**More info → Run anyway**. Updates are protected by a different signature,
described below.

## Automatic updates

Settings → **Updates**:

- **Update automatically** (on by default): a few seconds after Tabburrito
  starts it asks GitHub for the newest release; if there is one, it downloads
  it, checks the signature, installs it (a small progress window) and reopens.
  While Tabburrito keeps running it checks again once a day; an update found
  then is downloaded and checked, and waits for **Restart and install** so an
  open conversation is never cut off.
- **Check now** does the same check on demand.

How an update is checked:

1. Tabburrito reads
   `https://github.com/giladfeldman/tabburrito/releases/latest/download/latest.json`
   (version, installer URL, signature).
2. If the version is newer, it downloads the installer **into memory** and
   verifies its minisign signature against the public key compiled into the
   app (`plugins.updater.pubkey` in `src-tauri/tauri.conf.json`).
3. It also checks that the signature was made **for that version**: the signed
   comment names the installer file (`Tabburrito_<version>_x64-setup.exe`), so
   an old genuine installer served as a "newer" release (a rollback) is refused.
4. Only a file that passes is written to a temp folder and run. A modified
   file, a file signed with any other key, or one signed for another version is
   **refused** (`REFUSED - signature check failed` in the log) and the
   installed copy is left exactly as it was. A network or server problem is
   logged as `Downloading ... failed` and retried an hour later.

The installer reports nothing back, so the next start compares the running
version with the one it tried to install. If the install did not finish, that
version is **not installed again automatically** (a broken installer cannot
close Tabburrito on every start); Settings says so, and **Check now** then
**Restart and install** retries it.

Updates run only in a copy installed by the setup program (there is an
`uninstall.exe` beside the exe). A development build or a bare copied exe says
so in Settings and never tries to update.

Log: `%LOCALAPPDATA%\Tabburrito\update.log` (newest last). The "Last check"
line in Settings comes from `update-status.json` beside it, written only by
checks; `update-attempt.json` exists only between an install and the next
start.

## Uninstall

Windows Settings → Apps → Tabburrito → Uninstall.

**Sessions are kept.** The uninstaller removes only the program files; its
"delete app data" option removes `%LOCALAPPDATA%\com.tabburrito.app`, not the
logins. To delete the logins as well, delete `%LOCALAPPDATA%\Tabburrito`
yourself afterwards — that cannot be undone.

## Publishing a release (maintainer)

Releases are built and signed **on the maintainer's machine** and uploaded with
`gh`. No GitHub Actions are used.

1. Set the same new version in `src-tauri/tauri.conf.json`,
   `src-tauri/Cargo.toml` and `package.json`. Installed copies update only to a
   **higher** version.
2. Commit and push through `/ship`.
3. Build, sign and upload:

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install\Publish-TabburritoRelease.ps1 -Publish -Notes "What changed."
   ```

   Without `-Publish` it is a dry run: it builds and signs into
   `tmp\release\v<version>\` and uploads nothing. With `-Publish` it refuses
   to run unless the build inputs are committed, the commit is on
   `origin/main` (after a fetch that must succeed), neither the release nor
   the tag exists yet, and the version is higher than the current latest
   release; it re-checks HEAD and the build inputs after the build. Every run
   checks that the installed Tauri CLI is the pinned one and that the
   installer is signed with the key whose public half the app trusts. After
   uploading it reads `latest.json` back from the public URL and compares the
   version and the signature.

The release has three files: the installer, its `.sig`, and `latest.json`.

### Signing key

- Private key: `%USERPROFILE%\.tauri\tabburrito-updater.key` — **outside the
  repo, never committed.** It has no password so a build needs no prompt;
  anyone holding the file can publish an update every installed copy accepts.
- Public key: `%USERPROFILE%\.tauri\tabburrito-updater.key.pub`, and the same
  text in `src-tauri/tauri.conf.json` → `plugins.updater.pubkey`.
- **Keep a backup of the private key** (for example in a password manager).
  If it is lost, installed copies can never verify another update and every
  user has to reinstall by hand from a release built with a new key.
- New key (only if the old one is lost or leaked):
  `npx tauri signer generate --ci -w "$env:USERPROFILE\.tauri\tabburrito-updater.key"`,
  then paste the new `.pub` text into `tauri.conf.json`. Copies installed with
  the old key cannot update to releases signed with the new one.

### Testing the updater

```powershell
powershell -ExecutionPolicy Bypass -File .\install\Tests\Test-UpdaterEndToEnd.ps1
```

Builds a separate test product (`TabburritoE2E`, its own exe name, identifier
and throwaway key, a local `http://127.0.0.1` endpoint) in two versions,
installs the older one with the setup program's default folder
(`%LOCALAPPDATA%\Programs\TabburritoE2E`, which exercises the patched
template), and checks:

- a tampered installer and one signed with another key are refused as
  signature failures, with the installed copy unchanged and still running;
- a version remembered as a failed install is staged, not auto-installed;
- the genuine update installs, relaunches, logs "Updated to version", and the
  relaunched copy renders Settings with the new version (read through
  WebView2's DevTools port by `install/Tests/cdp_settings_probe.py`);
- seeded session files are unchanged;
- an old genuine installer served as a newer version is refused, and an
  unfinished install is detected and remembered;
- uninstall removes the program and leaves the sessions folder.

Limits: the test copy runs in portable mode (its data beside its exe), so the
real `%LOCALAPPDATA%\Tabburrito` layout, the retiring of the old scheduled task
and an upgrade over an old script install are not exercised; the real
release's signing key is checked by the publish script instead. The real
Tabburrito install and its sessions are not involved. The test shows its
app's window while it runs and takes two release builds.

### Upgrading the Tauri CLI

`@tauri-apps/cli` is pinned to an exact version in `package.json` because
`src-tauri/windows/installer.nsi` is a copy of that version's template. To
upgrade: fetch `crates/tauri-bundler/src/bundle/windows/nsis/installer.nsi`
from the `tauri-cli-v<new version>` tag of `tauri-apps/tauri`, re-apply the
`TABBURRITO CHANGE` line, update the header, and run the end-to-end test.

## Reusing this in another Tauri app

The pattern is app-agnostic: `src-tauri/src/updates.rs` (check at start +
daily, verify-then-install, log, Settings commands), the `bundle` and
`plugins.updater` blocks of `tauri.conf.json`, `Publish-TabburritoRelease.ps1`
and the end-to-end test. Change the repo name, product name, key path, and —
if the app keeps user data in `%LOCALAPPDATA%\<ProductName>` — keep the
installer-template change.

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

## Portable mode

To run from a USB stick, create an empty `portable.txt` next to the exe (a
copied exe like this does not update itself; replace it by hand). Data
then lives in `<exe-dir>\TabburritoWebViewData` as before.

Only do this when the exe sits in a stable folder. **Never enable portable mode
for an exe inside a build output directory** — that is the exact configuration
that caused the 2026-08-04 loss.
