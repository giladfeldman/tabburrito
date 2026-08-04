# Dropbox Vibe sync policy

`DropboxVibeSyncPolicy.ps1` audits all of Dropbox for common reproducible dependency and cache directories. It does nothing by default:

```powershell
& "$HOME\Vibe\WindowsTuneUp\power\DropboxVibeSyncPolicy.ps1"
```

Review the list, then apply the policy:

```powershell
& "$HOME\Vibe\WindowsTuneUp\power\DropboxVibeSyncPolicy.ps1" -Apply
```

The root `rules.dropboxignore` file handles new dependency/cache folders immediately. This script is the remediation and periodic audit for pre-existing folders. It intentionally does not include generic names such as `build`, `dist`, `out`, or `target`, because those can be real research or course content outside code projects.
