//! Release-based self-update.
//!
//! Tabburrito updates itself from the signed releases published at
//! https://github.com/giladfeldman/tabburrito/releases, using Tauri's official
//! updater plugin. No Rust toolchain or source checkout is needed on the
//! user's machine.
//!
//! * The endpoint and the minisign PUBLIC key live in tauri.conf.json
//!   (`plugins.updater`). The private key never enters the repository.
//! * `Update::download` checks the signature over the downloaded bytes in
//!   memory BEFORE anything is written or run. A failed download, a tampered
//!   file or an unsigned file is refused and the installed copy is untouched.
//! * `Update::install` writes the verified installer to a temp folder, runs it
//!   (`/P /UPDATE`, a small progress window) and exits. The installer replaces
//!   only the program files in `%LOCALAPPDATA%\Programs\Tabburrito` and starts
//!   the app again. Logins in `%LOCALAPPDATA%\Tabburrito` are never touched.
//!
//! Schedule: one check a few seconds after start, which installs straight away
//! if a newer release exists (an update costs one short restart at launch);
//! then one check every 24 hours while running, which downloads and verifies
//! but waits for "Restart and install" so an open session is never cut off.
//!
//! Updates run only in a copy installed by the Tabburrito setup program
//! (`uninstall.exe` next to the exe). A dev build or a bare copied exe has no
//! install for the installer to update.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_updater::{Update, UpdaterExt};

const START_DELAY: Duration = Duration::from_secs(5);
const CHECK_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);
/// The scheduled task of the old "git pull + rebuild" updater (before 0.2.0).
const LEGACY_TASK_NAME: &str = "Tabburrito Auto-Update";
const LOG_MAX_BYTES: u64 = 64 * 1024;

#[derive(Default)]
pub struct UpdateState {
    /// A downloaded, signature-verified update waiting for "Restart and install".
    pending: Mutex<Option<(Update, Vec<u8>)>>,
    /// Keeps the daily timer and the "Check now" button from downloading twice.
    busy: AtomicBool,
}

struct BusyGuard<'a>(&'a AtomicBool);

impl<'a> BusyGuard<'a> {
    fn acquire(flag: &'a AtomicBool) -> Option<Self> {
        flag.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
            .ok()
            .map(|_| BusyGuard(flag))
    }
}

impl Drop for BusyGuard<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

// --- Paths and preferences -------------------------------------------------

/// `%LOCALAPPDATA%\Tabburrito` (or the exe folder in portable mode): the
/// parent of the sessions folder. The log and the on/off preference live here
/// so they survive reinstalls, beside — never inside — the sessions.
fn state_dir() -> PathBuf {
    let data = crate::data_root();
    data.parent().map(|p| p.to_path_buf()).unwrap_or(data)
}

fn log_path() -> PathBuf {
    state_dir().join("update.log")
}

fn prefs_path() -> PathBuf {
    state_dir().join("update-prefs.json")
}

/// True when this exe was installed by the Tabburrito setup program.
fn is_setup_install() -> bool {
    crate::exe_dir().join("uninstall.exe").is_file()
}

fn is_portable() -> bool {
    crate::exe_dir().join("portable.txt").exists()
}

/// Automatic updates default to ON; only an explicit `{"auto": false}` turns
/// them off.
fn auto_enabled() -> bool {
    fs::read_to_string(prefs_path())
        .ok()
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok())
        .and_then(|v| v.get("auto").and_then(|a| a.as_bool()))
        .unwrap_or(true)
}

fn write_auto_enabled(enabled: bool) -> Result<(), String> {
    fs::create_dir_all(state_dir()).map_err(|e| e.to_string())?;
    let body = serde_json::json!({ "auto": enabled }).to_string();
    fs::write(prefs_path(), body).map_err(|e| e.to_string())?;
    // Read back rather than trusting the write.
    if auto_enabled() != enabled {
        return Err("The update preference did not save.".to_string());
    }
    Ok(())
}

// --- Log -------------------------------------------------------------------

/// Days since 1970-01-01 -> (year, month, day), proleptic Gregorian.
/// (Howard Hinnant's civil_from_days; avoids a date-library dependency.)
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = (z - era * 146_097) as u64;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe as i64 + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// UTC timestamp, ISO 8601 ("2026-11-19T14:05:09Z"), which the UI converts to
/// local time.
fn utc_timestamp(secs: u64) -> String {
    let (y, m, d) = civil_from_days((secs / 86_400) as i64);
    let rem = secs % 86_400;
    format!(
        "{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z",
        rem / 3600,
        (rem % 3600) / 60,
        rem % 60
    )
}

fn now_utc() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    utc_timestamp(secs)
}

/// Appends one line, "[timestamp] message". Keeps the newest half when the
/// file passes LOG_MAX_BYTES. Logging must never break an update, so every
/// error here is ignored.
fn log(msg: &str) {
    let path = log_path();
    let _ = fs::create_dir_all(state_dir());
    if fs::metadata(&path).map(|m| m.len() > LOG_MAX_BYTES).unwrap_or(false) {
        if let Ok(text) = fs::read_to_string(&path) {
            let lines: Vec<&str> = text.lines().collect();
            let keep = lines[lines.len() / 2..].join("\n");
            let _ = fs::write(&path, keep + "\n");
        }
    }
    if let Ok(mut f) = fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "[{}] {}", now_utc(), msg);
    }
}

/// Splits the last log line into (timestamp, message).
fn parse_last_log_line(text: &str) -> (Option<String>, Option<String>) {
    let Some(line) = text.lines().filter(|l| !l.trim().is_empty()).next_back() else {
        return (None, None);
    };
    match line.strip_prefix('[').and_then(|r| r.split_once("] ")) {
        Some((ts, msg)) => (Some(ts.to_string()), Some(msg.to_string())),
        None => (None, Some(line.to_string())),
    }
}

// --- Retiring the old source-rebuild updater --------------------------------

/// Before 0.2.0 a scheduled task ran `install\Update-Tabburrito.ps1` (git pull
/// + cargo build + copy the exe over the install). Left in place it would
/// overwrite the installed release with a local build, so remove it once.
/// Also removes `install-manifest.json`, which only that updater read and
/// which would stop the uninstaller from removing the program folder.
fn retire_legacy_updater() {
    let mut query = std::process::Command::new("schtasks");
    query.args(["/Query", "/TN", LEGACY_TASK_NAME]);
    hide_console(&mut query);
    let exists = query.output().map(|o| o.status.success()).unwrap_or(false);
    if exists {
        let mut del = std::process::Command::new("schtasks");
        del.args(["/Delete", "/TN", LEGACY_TASK_NAME, "/F"]);
        hide_console(&mut del);
        let ok = del.output().map(|o| o.status.success()).unwrap_or(false);
        log(&if ok {
            format!("Removed the old source-rebuild task '{LEGACY_TASK_NAME}'.")
        } else {
            format!("Could not remove the old task '{LEGACY_TASK_NAME}'; delete it in Task Scheduler.")
        });
    }

    let manifest = crate::exe_dir().join("install-manifest.json");
    if manifest.is_file() && fs::remove_file(&manifest).is_ok() {
        log("Removed install-manifest.json left by the old script installer.");
    }
}

fn hide_console(cmd: &mut std::process::Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(crate::CREATE_NO_WINDOW);
    }
    #[cfg(not(windows))]
    let _ = cmd;
}

// --- Check / download / install --------------------------------------------

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum Mode {
    /// Install as soon as a verified update is in hand (start-up check, button).
    InstallNow,
    /// Download and verify, then wait for the user (daily check, "Check now").
    Stage,
}

fn pending_version(state: &UpdateState) -> Option<String> {
    state
        .pending
        .lock()
        .ok()
        .and_then(|p| p.as_ref().map(|(u, _)| u.version.clone()))
}

fn install(update: &Update, bytes: &[u8]) -> Result<String, String> {
    log(&format!("Installing {} - Tabburrito will restart.", update.version));
    // On Windows a successful install() starts the installer and EXITS this
    // process, so only the error branch ever returns here.
    match update.install(bytes) {
        Ok(()) => Ok(format!("Installing {}.", update.version)),
        Err(e) => {
            let msg = format!(
                "Installing {} failed: {e}. The installed version is untouched.",
                update.version
            );
            log(&msg);
            Err(msg)
        }
    }
}

async fn run_check(app: &AppHandle, mode: Mode) -> Result<String, String> {
    if !is_setup_install() {
        return Err(not_installed_reason());
    }
    let state = app.state::<UpdateState>();
    let _busy = BusyGuard::acquire(&state.busy)
        .ok_or_else(|| "An update check is already running.".to_string())?;

    // A verified download already waiting: install it or report it.
    let staged = state.pending.lock().map_err(|e| e.to_string())?.take();
    if let Some((update, bytes)) = staged {
        if mode == Mode::InstallNow {
            let result = install(&update, &bytes);
            // Still here means the install failed; keep the download.
            *state.pending.lock().map_err(|e| e.to_string())? = Some((update, bytes));
            return result;
        }
        let msg = format!("Version {} is downloaded and verified - restart to install.", update.version);
        *state.pending.lock().map_err(|e| e.to_string())? = Some((update, bytes));
        return Ok(msg);
    }

    let current = app.package_info().version.to_string();
    let handle = app.clone();
    let updater = app
        .updater_builder()
        .on_before_exit(move || {
            // The installer is about to start and this process to exit
            // without the normal shutdown, so save the window layout now.
            use tauri_plugin_window_state::{AppHandleExt, StateFlags};
            let _ = handle.save_window_state(StateFlags::all());
        })
        .build()
        .map_err(|e| {
            let msg = format!("Update check failed: {e}");
            log(&msg);
            msg
        })?;

    let update = match updater.check().await {
        Ok(Some(u)) => u,
        Ok(None) => {
            let msg = format!("Up to date (version {current}).");
            log(&msg);
            return Ok(msg);
        }
        Err(e) => {
            let msg = format!("Update check failed: {e}");
            log(&msg);
            return Err(msg);
        }
    };

    let version = update.version.clone();
    log(&format!("Version {version} available (running {current}) - downloading."));
    let bytes = match update.download(|_, _| {}, || {}).await {
        Ok(b) => b,
        Err(e) => {
            let msg = format!(
                "Version {version} REFUSED - download or signature check failed: {e}. The installed version is untouched."
            );
            log(&msg);
            return Err(msg);
        }
    };
    log(&format!(
        "Version {version} downloaded and signature verified ({} bytes).",
        bytes.len()
    ));

    match mode {
        Mode::InstallNow => install(&update, &bytes),
        Mode::Stage => {
            *state.pending.lock().map_err(|e| e.to_string())? = Some((update, bytes));
            let msg = format!("Version {version} is ready - restart to install.");
            log(&msg);
            let _ = app.emit("tb-update-ready", version);
            Ok(msg)
        }
    }
}

fn not_installed_reason() -> String {
    if cfg!(debug_assertions) {
        "Development build - updates apply only to an installed copy.".to_string()
    } else {
        "This copy was not installed with the Tabburrito setup program, so it cannot update itself. Install the latest release from GitHub.".to_string()
    }
}

/// Called once from `setup`. Retires the old updater, then runs the start-up
/// check and the daily check on a background thread.
pub fn start(app: &AppHandle) {
    if !is_setup_install() {
        return;
    }
    if !is_portable() {
        retire_legacy_updater();
    }
    let handle = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(START_DELAY);
        let mut mode = Mode::InstallNow;
        loop {
            if auto_enabled() {
                let _ = tauri::async_runtime::block_on(run_check(&handle, mode));
            }
            mode = Mode::Stage;
            std::thread::sleep(CHECK_INTERVAL);
        }
    });
}

// --- Commands ---------------------------------------------------------------

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UpdateStatusPayload {
    running_version: String,
    /// False for dev builds and copies not installed by the setup program.
    can_update: bool,
    unavailable_reason: Option<String>,
    auto_update_enabled: bool,
    pending_version: Option<String>,
    checking: bool,
    last_checked: Option<String>,
    last_result: Option<String>,
}

#[tauri::command]
pub async fn get_update_status(app: AppHandle) -> Result<UpdateStatusPayload, String> {
    let state = app.state::<UpdateState>();
    let can_update = is_setup_install();
    let (last_checked, last_result) = match fs::read_to_string(log_path()) {
        Ok(text) => parse_last_log_line(&text),
        Err(_) => (None, None),
    };
    Ok(UpdateStatusPayload {
        running_version: app.package_info().version.to_string(),
        can_update,
        unavailable_reason: (!can_update).then(not_installed_reason),
        auto_update_enabled: auto_enabled(),
        pending_version: pending_version(&state),
        checking: state.busy.load(Ordering::SeqCst),
        last_checked,
        last_result,
    })
}

#[tauri::command]
pub async fn set_auto_update_enabled(enabled: bool) -> Result<(), String> {
    write_auto_enabled(enabled)?;
    log(if enabled { "Automatic updates turned on." } else { "Automatic updates turned off." });
    Ok(())
}

/// "Check now": downloads and verifies a newer release, then waits for
/// `install_update`.
#[tauri::command]
pub async fn check_for_updates(app: AppHandle) -> Result<String, String> {
    run_check(&app, Mode::Stage).await
}

/// "Restart and install": installs the staged update (or checks first).
#[tauri::command]
pub async fn install_update(app: AppHandle) -> Result<String, String> {
    run_check(&app, Mode::InstallNow).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn civil_dates_match_known_days() {
        assert_eq!(civil_from_days(0), (1970, 1, 1));
        assert_eq!(civil_from_days(11_016), (2000, 2, 29));
        assert_eq!(civil_from_days(-1), (1969, 12, 31));
        // 2026-11-19 is day 20_776 since the epoch.
        assert_eq!(civil_from_days(20_776), (2026, 11, 19));
    }

    #[test]
    fn timestamp_is_iso_utc() {
        assert_eq!(utc_timestamp(0), "1970-01-01T00:00:00Z");
        assert_eq!(utc_timestamp(20_776 * 86_400 + 13 * 3600 + 5 * 60 + 9), "2026-11-19T13:05:09Z");
    }

    #[test]
    fn last_log_line_is_split_into_time_and_message() {
        let text = "[2026-11-19T10:00:00Z] first\n[2026-11-19T11:00:00Z] Up to date (version 0.2.0).\n\n";
        assert_eq!(
            parse_last_log_line(text),
            (
                Some("2026-11-19T11:00:00Z".to_string()),
                Some("Up to date (version 0.2.0).".to_string())
            )
        );
        assert_eq!(parse_last_log_line(""), (None, None));
        assert_eq!(parse_last_log_line("no stamp"), (None, Some("no stamp".to_string())));
    }

    #[test]
    fn busy_guard_is_exclusive_and_released_on_drop() {
        let flag = AtomicBool::new(false);
        let first = BusyGuard::acquire(&flag);
        assert!(first.is_some());
        assert!(BusyGuard::acquire(&flag).is_none());
        drop(first);
        assert!(BusyGuard::acquire(&flag).is_some());
    }
}
