## Never Store User Data Inside A Build Output Directory

**2026-08-04 — total session loss. The defining incident for this project.**

The release exe lived at `build\cargo-target-webview2\release\tabburrito.exe`, and
`webview_data_dir()` resolved to `<exe-dir>\TabburritoWebViewData`. That put every
logged-in session **inside a cargo target directory**. A build-cache cleanup deleted
`release\` and all sessions with it (WhatsApp, Messenger, LinkedIn, Bluesky, Calendar).

Recovery was impossible — every avenue failed at once:

- `TabburritoWebViewData/` **and** `build/` are both gitignored → never in version control
- File History service: **Stopped**
- No system restore points
- Nothing in the Recycle Bin (deleted programmatically, not via shell)

The earlier lesson here said "do not clean/delete the data folder" — a *procedural*
rule guarding a *structurally unsafe* layout. It failed, because a cargo target
directory is disposable by definition and every tool that touches it is entitled to
delete it. Discipline cannot protect data stored somewhere designed to be erased.

Rules now enforced in code and installer:

- User data belongs in `%LOCALAPPDATA%\Tabburrito\TabburritoWebViewData` — see
  `data_root()` in `src-tauri/src/main.rs`.
- The installed exe belongs in `%LOCALAPPDATA%\Programs\Tabburrito` (per-user, so
  updates need no elevation).
- Build output goes to `%LOCALAPPDATA%\TabburritoBuild`, **outside the repo**, so
  cleaning it can never reach user data.
- Portable mode (data next to the exe) is now **opt-in** via a `portable.txt` marker,
  never the default, and must never be enabled for an exe inside a build directory.
- `migrate_legacy_data_dir()` adopts any legacy exe-adjacent folder once, and only
  when the new root does not exist, so it can never clobber live sessions.
- Uninstall keeps sessions unless `-PurgeData` is passed explicitly.

Generalized: **irreplaceable state must never live under a path any tool treats as a
cache.** Ask "what happens if something deletes this whole directory?" — if the answer
is "we lose data", the layout is wrong, not the tooling. And an unbacked-up folder is
one command away from gone: `install\Backup-TabburritoSessions.ps1` exists because
nothing here was recoverable.
