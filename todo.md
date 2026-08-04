# todo

## From cross-project review (2026-08-03)

- [x] R-0061 | WindowsTuneUp | bug | P1 | phase:1 | status:done:2026-08-04 | first:2026-08-03 | New-DropboxRecoveryManifest.ps1 defaults OutputDirectory to the pre-move Dropbox path (now nonexiste (see project-review ledger R-0061) *(Resolved 2026-08-04: OutputDirectory now defaults via VIBE_ROOT/$HOME\Vibe resolution with a fail-loud check; also fixed dead Dropbox\Vibe paths in power/README.md, power/README-DropboxVibeSyncPolicy.md, and the disabled startup cmd template)*
- [x] R-0062 | WindowsTuneUp | bug | P2 | phase:2 | status:done:2026-08-04 | first:2026-08-03 | set_notify_service reloads WhatsApp/Messenger with the hardcoded default URL, bypassing saved servic (see project-review ledger R-0062) *(Resolved 2026-08-04 in 315b4f5: set_notify_service now routes through resolve_service_url, honoring per-service overrides. Verified at src-tauri/src/main.rs:1842)*

## Tabburrito sync / profile (deferred 2026-08-04)

Context: raised after the 2026-08-04 session loss. Settings are already a single
compact JSON blob (~0.8 KB on disk), so settings sync is genuinely small work.
Session sync is the risky part and is deliberately NOT bundled with it.

- [ ] SYNC-1 | feature | P2 | status:deferred | Google OAuth + Drive `appDataFolder` **settings** sync.
  Scope: the `tabburrito` localStorage blob (`ui/app.js:40`) - muted, dark, notifyServices,
  notifyModes, unloadSeconds, dndUntil, resourceMode, profiles - plus `PortableStatePayload`
  (`src-tauri/src/main.rs:1081`: unload_seconds, service_urls, linkedin_sort, notify_tracked).
  Any future per-service on/off toggle lands in the same blob and syncs for free.
  Design notes:
  - Desktop OAuth loopback flow (`http://127.0.0.1:<port>`); do NOT embed a client secret
    as if it were secret - desktop clients are public by definition.
  - `drive.appdata` scope only. `appDataFolder` is hidden per-app storage: invisible in the
    user's Drive UI and unreadable by other apps. Never request full `drive` scope.
  - Refresh token belongs in Windows Credential Manager (DPAPI), never in the repo,
    never in the synced blob itself.
  - Needs a merge rule for two machines editing concurrently. Last-write-wins on a
    whole-blob timestamp is acceptable here and much simpler than per-key merging.
  - Must degrade cleanly offline: sync failure is never allowed to block app start.

- [ ] SYNC-2 | feature | P3 | status:deferred | Upload the encrypted session backup zip to Drive.
  Middle option discussed 2026-08-04: protects against another accidental deletion by putting
  `install/Backup-TabburritoSessions.ps1` output in Drive. Restores only on THIS machine -
  WebView2 cookies are DPAPI-bound to the Windows account - so it is disaster recovery,
  not cross-machine login. ~14 MB per snapshot; needs retention/pruning to avoid Drive bloat.

- [ ] SYNC-3 | feature | P4 | status:rejected-unless-revisited | Portable cross-machine sessions.
  Would require decrypting WebView2 `Cookies`/`Login Data` and re-encrypting them for cloud
  storage. **Advised against 2026-08-04.** Anyone obtaining the blob plus key gets full
  authenticated access to WhatsApp/Messenger/LinkedIn/Bluesky/Calendar, bypassing 2FA.
  Also ~14 MB of constantly-changing binary SQLite. Only revisit with a hardware-backed key
  and an explicit threat-model decision.

## Install / robustness follow-ups (2026-08-04)

- [ ] INST-1 | chore | P2 | status:open | Verify the auto-update task end-to-end against a real
  remote commit. Detection, the dirty-tree guard, and build-failure safety were each tested
  2026-08-04, but a full fetch->rebuild->reinstall cycle has never run from an actually-newer
  origin/main. Do this once after the next push lands.

- [ ] INST-2 | chore | P3 | status:open | Schedule automatic session backups (weekly), reusing the
  `Register-AutoUpdate.ps1` schtasks/XML approach. `Register-ScheduledTask` fails with
  "Access is denied" on this machine even for per-user tasks - use schtasks /Create /XML.
  Must skip the run when Tabburrito is open rather than taking a torn snapshot.

- [ ] INST-3 | chore | P3 | status:open | Code-sign `tabburrito.exe`. Unsigned builds trip Smart App
  Control (os error 4551) on some machines and show a SmartScreen warning on first run.

- [ ] INST-4 | chore | P4 | status:open | Consider a real MSI/NSIS bundle via `tauri build`.
  `tauri.conf.json` already sets `bundle.targets: "all"`, but the current flow ships a bare exe
  plus PowerShell installer. Only worth doing if Tabburrito is distributed beyond this machine;
  any bundle MUST keep user data in %LOCALAPPDATA%\Tabburrito, never beside the exe.

- [ ] INST-5 | chore | P4 | status:open | Recovery avenue never checked: Volume Shadow Copies
  (`vssadmin list shadows`) needs elevation. Attempted 2026-08-04 for the lost sessions and
  blocked. With File History Stopped and no restore points it is very unlikely to hold
  anything, but it is the one stone left unturned from that incident.
