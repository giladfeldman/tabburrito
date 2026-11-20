## Release-Based Updates (2026-11-19)

- Updates come from signed GitHub releases (Tauri updater plugin), not from `git pull` + a local rebuild. The old path needed Rust on every machine and was never verified end to end from a newer origin.
- Tauri's stock per-user NSIS installer defaults to `%LOCALAPPDATA%\<productName>` — for Tabburrito that is the sessions folder. The repo carries the 2.10.1 template with one line changed to `%LOCALAPPDATA%\Programs\<productName>`; the CLI is pinned so the template and CLI cannot drift apart.
- `Update::download` verifies the minisign signature over the bytes in memory before anything is written; only then does `install` write the installer and exit. Refusals are logged with the word `REFUSED`.
- The updater's own trust is the minisign key, separate from Authenticode. The local self-signed Authenticode cert must never sign a public release (it is trusted only on this machine and looks worse than unsigned elsewhere), so the release-era scripts dropped it.
- Test the updater with a separate product name, identifier and throwaway key, so the real install, its registry entries and its sessions are never part of the test.
- The signature does not cover the version in `latest.json`, so an old genuine installer can be served as "newer". Bind the version yourself: read it from the signed trusted comment (`file:Tabburrito_X_x64-setup.exe`) after `download()` and refuse a mismatch. The publish script checks the comment yields the version, so a CLI change that alters the format fails at publish, not on every client.
- The installer reports nothing back and closes the app first. Write `update-attempt.json` before installing and reconcile it at the next start; a version that did not finish is staged, never auto-installed again.
- A status shown to the user comes from a status file written by the check, never from "the last log line" (a toggle or an "Installing..." line then posed as the result).
