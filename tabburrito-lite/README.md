# Tabburrito Lite

Firefox-based version of Tabburrito. Uses a dedicated Firefox profile with optimized settings instead of WebView2.

## Memory comparison

| Version | RAM usage | Engine |
|---------|-----------|--------|
| Tabburrito (Tauri/WebView2) | ~2.7 GB | 18 WebView2 processes |
| **Tabburrito Lite (Firefox)** | **~500-800 MB** | 1 Firefox instance, shared processes |
| Ferdium (Electron) | ~3.2 GB | 14 Chromium processes |

## Setup

1. **Run `setup.bat`** — creates the profile, downloads uBlock Origin, opens Firefox with your 5 services
2. **Pin each tab** — right-click each tab → "Pin Tab" (this makes them permanent)
3. **Close and relaunch** with `start.bat` — session restore brings back all pinned tabs

## What's included

- **Optimized `user.js`** — limits content processes to 4, disables telemetry/Pocket/crash reporter, enables dark theme, compact UI, Hebrew+English spellcheck
- **uBlock Origin** — auto-downloaded from official Mozilla addons (blocks LinkedIn ads with custom filters)
- **Compact userChrome.css** — smaller tabs, hidden Firefox View button, hidden Pocket button

## Services

- WhatsApp Web
- Facebook Messenger
- LinkedIn
- Bluesky
- Google Calendar (English, via accounts.google.com login flow)

## Daily use

Run `start.bat` to launch. Firefox restores your pinned tabs from the previous session.

## LinkedIn ad blocking

After uBlock Origin installs, add these custom filters:

```
www.linkedin.com##span:has-text(Promoted):upward(6)
www.linkedin.com##span:has-text(Suggested):upward(6)
www.linkedin.com##p:has-text(/^Promoted/):upward(6)
www.linkedin.com##span:has-text(Recommended for you):upward(6)
```

## Files

- `setup.bat` — first-time setup (creates profile, downloads uBlock, opens Firefox)
- `start.bat` — daily launcher (opens Firefox with existing profile)
- `user.js` — Firefox performance/privacy preferences
