// Tabburrito Lite - tray shell for an isolated Firefox profile.
// Firefox does the rendering; Tauri provides lightweight controls.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs;
use std::io;
#[cfg(target_os = "windows")]
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use tauri::{
    image::Image,
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    AppHandle, Manager,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt as AutostartExt};
use tauri_plugin_global_shortcut::{
    Code, GlobalShortcutExt, Modifiers, Shortcut, ShortcutState,
};

const APP_DIR_NAME: &str = "TabburritoLite";
const APP_DISPLAY_NAME: &str = "TABBURRITO";
const APP_WINDOW_PREFIX: &str = "[TABBURRITO] ";
const PROFILE_DIR_NAME: &str = "profile";
const CONFIG_FILE_NAME: &str = "config.json";
const STATUS_FILE_NAME: &str = "status.json";
const UBLOCK_XPI_NAME: &str = "uBlock0@raymondhill.net.xpi";

#[cfg(target_os = "windows")]
const CREATE_NO_WINDOW: u32 = 0x08000000;

const LINKEDIN_FILTERS: &str = "! Tabburrito LinkedIn filters\n\
www.linkedin.com##span:has-text(Promoted):upward(6)\n\
www.linkedin.com##span:has-text(Suggested):upward(6)\n\
www.linkedin.com##p:has-text(/^Promoted/):upward(6)\n\
www.linkedin.com##span:has-text(Recommended for you):upward(6)\n\
www.linkedin.com##.ad-banner-container\n\
www.linkedin.com##.premium-upsell-link\n\
www.linkedin.com##.feed-follows-module\n\
www.linkedin.com##aside .artdeco-card:has(iframe)\n";

#[derive(Clone, Copy, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
enum ThemeMode {
    Dark,
    Light,
}

impl ThemeMode {
    fn toggle(self) -> Self {
        match self {
            Self::Dark => Self::Light,
            Self::Light => Self::Dark,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Dark => "dark",
            Self::Light => "light",
        }
    }
}

#[derive(Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
enum ServiceTemperature {
    AlwaysOn,
    Warm,
    OnDemand,
}

impl ServiceTemperature {
    fn label(self) -> &'static str {
        match self {
            Self::AlwaysOn => "always_on",
            Self::Warm => "warm",
            Self::OnDemand => "on_demand",
        }
    }
}

#[derive(Clone, Copy)]
struct ManagedService {
    id: &'static str,
    label: &'static str,
    url: &'static str,
    temperature: ServiceTemperature,
    shortcut_key: &'static str,
}

const SERVICES: [ManagedService; 5] = [
    ManagedService {
        id: "whatsapp",
        label: "WhatsApp",
        url: "https://web.whatsapp.com",
        temperature: ServiceTemperature::AlwaysOn,
        shortcut_key: "Ctrl+Alt+1",
    },
    ManagedService {
        id: "messenger",
        label: "Messenger",
        url: "https://www.messenger.com",
        temperature: ServiceTemperature::AlwaysOn,
        shortcut_key: "Ctrl+Alt+2",
    },
    ManagedService {
        id: "linkedin",
        label: "LinkedIn",
        url: "https://www.linkedin.com/feed/",
        temperature: ServiceTemperature::Warm,
        shortcut_key: "Ctrl+Alt+3",
    },
    ManagedService {
        id: "bluesky",
        label: "Bluesky",
        url: "https://bsky.app",
        temperature: ServiceTemperature::OnDemand,
        shortcut_key: "Ctrl+Alt+4",
    },
    ManagedService {
        id: "calendar",
        label: "Calendar",
        url: "https://accounts.google.com/ServiceLogin?continue=https://calendar.google.com/calendar/u/0/r?hl%3Den&hl=en",
        temperature: ServiceTemperature::OnDemand,
        shortcut_key: "Ctrl+Alt+5",
    },
];

#[derive(Clone, Serialize, Deserialize)]
struct ServiceConfig {
    id: String,
    startup: bool,
}

#[derive(Clone, Serialize, Deserialize)]
struct AppConfig {
    theme: ThemeMode,
    services: Vec<ServiceConfig>,
}

impl Default for AppConfig {
    fn default() -> Self {
        Self {
            theme: ThemeMode::Dark,
            services: SERVICES
                .iter()
                .map(|service| ServiceConfig {
                    id: service.id.to_string(),
                    startup: true,
                })
                .collect(),
        }
    }
}

#[derive(Serialize)]
struct ServiceStatus {
    id: String,
    label: String,
    temperature: String,
    startup: bool,
    shortcut: String,
}

#[derive(Serialize)]
struct StatusReport {
    firefox_running: bool,
    firefox_pid: Option<u32>,
    firefox_process_tree_count: Option<u32>,
    autostart_enabled: bool,
    muted_shortcut: String,
    refresh_shortcut: String,
    reopen_shortcut: String,
    theme_toggle_shortcut: String,
    theme: String,
    profile_dir: String,
    config_path: String,
    status_path: String,
    linkedin_filters_path: String,
    services: Vec<ServiceStatus>,
}

struct FirefoxState {
    child: Option<Child>,
    app_dir: PathBuf,
    profile_dir: PathBuf,
    config_path: PathBuf,
    status_path: PathBuf,
}

fn get_app_dir() -> PathBuf {
    let exe_path = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("."));
    let exe_dir = exe_path.parent().unwrap_or(Path::new("."));
    exe_dir.join(APP_DIR_NAME)
}

fn firefox_executable() -> PathBuf {
    let exe_path = std::env::current_exe().unwrap_or_else(|_| PathBuf::from("."));
    let exe_dir = exe_path.parent().unwrap_or(Path::new("."));

    let candidates = [
        exe_dir.join("tabburrito-browser.exe"),
        exe_dir.join("tabburrito-firefox.exe"),
        exe_dir.join("TabburritoFirefox").join("tabburrito-browser.exe"),
        exe_dir.join("TabburritoFirefox").join("tabburrito-firefox.exe"),
        exe_dir.join("TabburritoFirefox").join("firefox.exe"),
        exe_dir.join("firefox.exe"),
        PathBuf::from(r"C:\Program Files\Mozilla Firefox\firefox.exe"),
    ];

    for candidate in candidates {
        if candidate.exists() {
            return candidate;
        }
    }

    PathBuf::from(r"C:\Program Files\Mozilla Firefox\firefox.exe")
}

fn get_profile_dir(app_dir: &Path) -> PathBuf {
    app_dir.join(PROFILE_DIR_NAME)
}

fn config_path(app_dir: &Path) -> PathBuf {
    app_dir.join(CONFIG_FILE_NAME)
}

fn status_path(app_dir: &Path) -> PathBuf {
    app_dir.join(STATUS_FILE_NAME)
}

fn filters_path(profile_dir: &Path) -> PathBuf {
    profile_dir.join("linkedin-filters.txt")
}

fn ensure_safe_profile_dir(profile_dir: &Path) -> io::Result<()> {
    let profile_name = profile_dir.file_name().and_then(|name| name.to_str());
    let app_name = profile_dir
        .parent()
        .and_then(|parent| parent.file_name())
        .and_then(|name| name.to_str());

    if profile_name == Some(PROFILE_DIR_NAME) && app_name == Some(APP_DIR_NAME) {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "Refusing to operate on unexpected Firefox profile path: {}",
                profile_dir.display()
            ),
        ))
    }
}

fn load_or_create_config(path: &Path) -> io::Result<AppConfig> {
    if path.exists() {
        let raw = fs::read_to_string(path)?;
        let parsed = serde_json::from_str::<AppConfig>(&raw).unwrap_or_default();
        let normalized = AppConfig {
            theme: parsed.theme,
            services: SERVICES
                .iter()
                .map(|service| ServiceConfig {
                    id: service.id.to_string(),
                    startup: true,
                })
                .collect(),
        };
        save_config(path, &normalized)?;
        Ok(normalized)
    } else {
        let config = AppConfig::default();
        save_config(path, &config)?;
        Ok(config)
    }
}

fn save_config(path: &Path, config: &AppConfig) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    let raw = serde_json::to_string_pretty(config)?;
    fs::write(path, raw)
}

fn hide_command_window(mut command: Command) -> Command {
    #[cfg(target_os = "windows")]
    {
        command.creation_flags(CREATE_NO_WINDOW);
    }
    command
}

fn startup_for(config: &AppConfig, id: &str) -> bool {
    config
        .services
        .iter()
        .find(|service| service.id == id)
        .map(|service| service.startup)
        .unwrap_or(false)
}

fn configured_startup_urls(config: &AppConfig) -> Vec<&'static str> {
    let _ = config;
    first_run_urls()
}

fn first_run_urls() -> Vec<&'static str> {
    SERVICES.iter().map(|service| service.url).collect()
}

fn theme_prefs(theme: ThemeMode) -> &'static str {
    match theme {
        ThemeMode::Dark => {
            "user_pref(\"ui.systemUsesDarkTheme\", 1);\n\
             user_pref(\"browser.theme.content-theme\", 0);\n\
             user_pref(\"browser.theme.toolbar-theme\", 0);\n"
        }
        ThemeMode::Light => {
            "user_pref(\"ui.systemUsesDarkTheme\", 0);\n\
             user_pref(\"browser.theme.content-theme\", 1);\n\
             user_pref(\"browser.theme.toolbar-theme\", 1);\n"
        }
    }
}

fn theme_css(theme: ThemeMode) -> String {
    let (toolbar_bg, selected_bg, label, active_label, border, status_bg, urlbar_bg) = match theme {
        ThemeMode::Dark => ("#0d2b2b", "#0f4f4f", "#d6fff7", "#ffffff", "#081919", "#103636", "#123f3f"),
        ThemeMode::Light => ("#edf7f5", "#ffffff", "#20504d", "#0f172a", "#b8d8d2", "#dcefeb", "#ffffff"),
    };

    format!(
        "/* Tabburrito Lite - isolated browser chrome */\n\
         #PersonalToolbar {{ display: none !important; }}\n\
         #toolbar-menubar {{ display: none !important; }}\n\
         #firefox-view-button {{ display: none !important; }}\n\
         #tabs-newtab-button, #new-tab-button {{ display: none !important; }}\n\
         #alltabs-button {{ display: none !important; }}\n\
         .titlebar-spacer[type=\"pre-tabs\"], .titlebar-spacer[type=\"post-tabs\"] {{ max-width: 4px !important; }}\n\
         #TabsToolbar {{\n\
             --tab-min-height: 34px !important;\n\
             background: {toolbar_bg} !important;\n\
             border-bottom: 1px solid {border} !important;\n\
             -moz-window-dragging: drag !important;\n\
         }}\n\
         #tabbrowser-tabs {{ background: {toolbar_bg} !important; }}\n\
         #TabsToolbar::before {{\n\
             content: \"{APP_DISPLAY_NAME}\";\n\
             color: {label};\n\
             font-size: 12px;\n\
             font-weight: 800;\n\
             letter-spacing: 0.08em;\n\
             margin: 0 12px 0 8px;\n\
             opacity: 0.95;\n\
         }}\n\
         .tabbrowser-tab {{ max-width: 165px !important; -moz-window-dragging: no-drag !important; }}\n\
         .tabbrowser-tab .tab-background {{ border: none !important; background: transparent !important; }}\n\
         .tabbrowser-tab[selected] .tab-background {{\n\
             background: {selected_bg} !important;\n\
             border-radius: 7px !important;\n\
             margin: 3px 2px !important;\n\
         }}\n\
         .tabbrowser-tab .tab-label {{ color: {label} !important; font-size: 11px !important; }}\n\
         .tabbrowser-tab[selected] .tab-label {{ color: {active_label} !important; }}\n\
         .tab-close-button, #save-to-pocket-button {{ display: none !important; }}\n\
         .tabbrowser-tab::after, .tabbrowser-tab::before {{ display: none !important; }}\n\
         .tab-icon-sound {{ display: block !important; }}\n\
         #nav-bar {{\n\
             background: {toolbar_bg} !important;\n\
             border-bottom: 1px solid {border} !important;\n\
         }}\n\
         #urlbar-background {{ background: {urlbar_bg} !important; border-radius: 6px !important; }}\n\
         #urlbar {{ min-height: 28px !important; }}\n\
         #statuspanel-label {{ background: {status_bg} !important; border-color: {border} !important; }}\n"
    )
}

fn write_profile_files(profile_dir: &Path, config: &AppConfig) -> io::Result<()> {
    ensure_safe_profile_dir(profile_dir)?;
    fs::create_dir_all(profile_dir)?;

    let mut user_js = include_str!("../../user.js").to_string();
    user_js.push_str("\n// Tabburrito profile-managed settings\n");
    user_js.push_str(theme_prefs(config.theme));
    user_js.push_str(&format!(
        "user_pref(\"browser.window.titlePreface\", \"{APP_WINDOW_PREFIX}\");\n"
    ));
    user_js.push_str("user_pref(\"toolkit.legacyUserProfileCustomizations.stylesheets\", true);\n");
    user_js.push_str("user_pref(\"extensions.autoDisableScopes\", 0);\n");
    user_js.push_str("user_pref(\"extensions.enabledScopes\", 15);\n");
    user_js.push_str("user_pref(\"browser.tabs.loadInBackground\", false);\n");
    user_js.push_str("user_pref(\"browser.ctrlTab.sortByRecentlyUsed\", true);\n");
    fs::write(profile_dir.join("user.js"), user_js)?;

    let chrome_dir = profile_dir.join("chrome");
    fs::create_dir_all(&chrome_dir)?;
    fs::write(chrome_dir.join("userChrome.css"), theme_css(config.theme))?;

    let ext_dir = profile_dir.join("extensions");
    fs::create_dir_all(&ext_dir)?;
    let xpi_path = ext_dir.join(UBLOCK_XPI_NAME);
    if !xpi_path.exists() {
        let _ = hide_command_window(Command::new("powershell"))
            .args([
                "-NoProfile",
                "-Command",
                &format!(
                    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; \
                     Invoke-WebRequest -Uri 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi' \
                     -OutFile '{}' -UseBasicParsing",
                    xpi_path.display()
                ),
            ])
            .output();
    }

    fs::write(filters_path(profile_dir), LINKEDIN_FILTERS)?;
    fs::write(
        profile_dir.join("README.txt"),
        "This Firefox profile is managed by Tabburrito Lite.\n\
         It is isolated from your normal Firefox usage via --profile and --no-remote.\n\
         You can safely reset this profile from the Tabburrito Lite tray menu without affecting your primary Firefox profile.\n",
    )?;

    Ok(())
}

fn service_for_menu_id(id: &str) -> Option<&'static ManagedService> {
    let service_id = id.strip_prefix("service-")?;
    SERVICES.iter().find(|service| service.id == service_id)
}

fn current_pid(state: &Mutex<FirefoxState>) -> Option<u32> {
    let mut guard = state.lock().unwrap();
    let child = guard.child.as_mut()?;
    match child.try_wait() {
        Ok(Some(_)) => {
            guard.child = None;
            None
        }
        Ok(None) => Some(child.id()),
        Err(_) => {
            guard.child = None;
            None
        }
    }
}

fn escape_for_wmi(path: &Path) -> String {
    path.display().to_string().replace('\\', "\\\\")
}

fn find_running_firefox_pids(profile_dir: &Path) -> Vec<u32> {
    let profile = escape_for_wmi(profile_dir);
    let script = format!(
        "Get-CimInstance Win32_Process | Where-Object {{ \
            $_.CommandLine -like '*{profile}*' -and ($_.Name -like '*firefox*' -or $_.Name -like '*tabburrito*') \
        }} | Select-Object -ExpandProperty ProcessId"
    );
    let output = hide_command_window(Command::new("powershell"))
        .args(["-NoProfile", "-Command", &script])
        .output()
        .ok();
    let Some(output) = output else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    let text = String::from_utf8_lossy(&output.stdout);
    text.lines()
        .filter_map(|line| line.trim().parse::<u32>().ok())
        .collect()
}

fn find_running_firefox_pid(profile_dir: &Path) -> Option<u32> {
    find_running_firefox_pids(profile_dir).into_iter().next()
}

fn current_or_running_pid(state: &Mutex<FirefoxState>) -> Option<u32> {
    if let Some(pid) = current_pid(state) {
        return Some(pid);
    }
    let profile_dir = {
        let guard = state.lock().unwrap();
        guard.profile_dir.clone()
    };
    find_running_firefox_pid(&profile_dir)
}

fn app_activate(pid: u32) -> io::Result<()> {
    let script = format!(
        "$ws = New-Object -ComObject WScript.Shell; \
         if (-not $ws.AppActivate({pid})) {{ exit 1 }}"
    );
    let status = hide_command_window(Command::new("powershell"))
        .args(["-NoProfile", "-Command", &script])
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::Other,
            format!("Could not activate Firefox process {pid}"),
        ))
    }
}

fn send_keys(pid: u32, keys: &str) -> io::Result<()> {
    let script = format!(
        "$ws = New-Object -ComObject WScript.Shell; \
         if (-not $ws.AppActivate({pid})) {{ exit 1 }}; \
         Start-Sleep -Milliseconds 120; \
         $ws.SendKeys('{keys}')"
    );
    let status = hide_command_window(Command::new("powershell"))
        .args(["-NoProfile", "-Command", &script])
        .status()?;
    if status.success() {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::Other,
            format!("Could not send keys {keys} to Firefox"),
        ))
    }
}

fn service_tab_index(id: &str) -> Option<u8> {
    SERVICES
        .iter()
        .position(|service| service.id == id)
        .map(|idx| (idx + 1) as u8)
}

fn switch_to_tab(pid: u32, index: u8) -> io::Result<()> {
    let key = match index {
        1 => "^1",
        2 => "^2",
        3 => "^3",
        4 => "^4",
        5 => "^5",
        6 => "^6",
        7 => "^7",
        8 => "^8",
        9 => "^9",
        _ => "^1",
    };
    send_keys(pid, key)
}

fn spawn_firefox(profile_dir: &Path, urls: &[&str]) -> io::Result<Child> {
    let firefox_path = firefox_executable();
    let mut cmd = Command::new(firefox_path);
    cmd.arg("--profile").arg(profile_dir).arg("--no-remote");

    if urls.len() == 1 {
        cmd.arg("--new-tab").arg(urls[0]);
    } else if urls.is_empty() {
        // Let session restore handle tabs when available.
    } else {
        for url in urls {
            cmd.arg(url);
        }
    }

    cmd.spawn()
}

fn launch_firefox(state: &Mutex<FirefoxState>, urls: &[&str]) -> io::Result<()> {
    let mut guard = state.lock().unwrap();
    let child = spawn_firefox(&guard.profile_dir, urls)?;
    guard.child = Some(child);
    Ok(())
}

fn open_service(state: &Mutex<FirefoxState>, service: &'static ManagedService) -> io::Result<()> {
    if let Some(pid) = current_or_running_pid(state) {
        let _ = app_activate(pid);
        if let Some(index) = service_tab_index(service.id) {
            return switch_to_tab(pid, index);
        }
        open_startup_services(state)
    } else {
        open_startup_services(state)
    }
}

fn refresh_current_tab(state: &Mutex<FirefoxState>) -> io::Result<()> {
    if let Some(pid) = current_or_running_pid(state) {
        send_keys(pid, "^r")
    } else {
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            "Firefox is not running",
        ))
    }
}

fn mute_current_tab(state: &Mutex<FirefoxState>) -> io::Result<()> {
    if let Some(pid) = current_or_running_pid(state) {
        send_keys(pid, "^m")
    } else {
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            "Firefox is not running",
        ))
    }
}

fn close_current_tab(state: &Mutex<FirefoxState>) -> io::Result<()> {
    if let Some(pid) = current_or_running_pid(state) {
        send_keys(pid, "^w")
    } else {
        Err(io::Error::new(
            io::ErrorKind::NotFound,
            "Firefox is not running",
        ))
    }
}

fn kill_firefox(state: &Mutex<FirefoxState>) {
    let profile_dir = {
        let guard = state.lock().unwrap();
        guard.profile_dir.clone()
    };
    for pid in find_running_firefox_pids(&profile_dir) {
        let _ = hide_command_window(Command::new("taskkill"))
            .args(["/PID", &pid.to_string(), "/T", "/F"])
            .status();
    }
    let mut guard = state.lock().unwrap();
    if let Some(child) = guard.child.as_mut() {
        let _ = child.kill();
        let _ = child.wait();
    }
    guard.child = None;
}

fn restart_firefox(state: &Mutex<FirefoxState>, startup_urls: &[&str]) -> io::Result<()> {
    kill_firefox(state);
    launch_firefox(state, startup_urls)
}

fn restart_with_configured_startup(state: &Mutex<FirefoxState>) -> io::Result<()> {
    let config_path = {
        let guard = state.lock().unwrap();
        guard.config_path.clone()
    };
    let config = load_or_create_config(&config_path)?;
    let startup_urls = configured_startup_urls(&config);
    if startup_urls.is_empty() {
        restart_firefox(state, &first_run_urls())
    } else {
        restart_firefox(state, &startup_urls)
    }
}

fn process_tree_count(pid: u32) -> Option<u32> {
    let script = format!(
        "$seen = @{{}}; \
         function CountChildren([int]$id) {{ \
             $count = 0; \
             Get-CimInstance Win32_Process -Filter \"ParentProcessId = $id\" | ForEach-Object {{ \
                 if (-not $seen.ContainsKey($_.ProcessId)) {{ \
                     $seen[$_.ProcessId] = $true; \
                     $script:count++; \
                     CountChildren $_.ProcessId | Out-Null; \
                 }} \
             }} \
         }}; \
         $script:count = 1; \
         CountChildren {pid} | Out-Null; \
         Write-Output $script:count"
    );
    let output = hide_command_window(Command::new("powershell"))
        .args(["-NoProfile", "-Command", &script])
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    let text = String::from_utf8_lossy(&output.stdout);
    text.trim().parse::<u32>().ok()
}

fn write_status_report(app: &AppHandle, state: &Mutex<FirefoxState>) -> io::Result<PathBuf> {
    let pid = current_or_running_pid(state);
    let (profile_dir, config_file, status_file) = {
        let guard = state.lock().unwrap();
        (
            guard.profile_dir.clone(),
            guard.config_path.clone(),
            guard.status_path.clone(),
        )
    };
    let config = load_or_create_config(&config_file)?;
    let autostart_enabled = app.autolaunch().is_enabled().unwrap_or(false);
    let report = StatusReport {
        firefox_running: pid.is_some(),
        firefox_pid: pid,
        firefox_process_tree_count: pid.and_then(process_tree_count),
        autostart_enabled,
        muted_shortcut: "Ctrl+Alt+M".to_string(),
        refresh_shortcut: "Ctrl+Alt+R".to_string(),
        reopen_shortcut: "Ctrl+Alt+O".to_string(),
        theme_toggle_shortcut: "Ctrl+Alt+D".to_string(),
        theme: config.theme.label().to_string(),
        profile_dir: profile_dir.display().to_string(),
        config_path: config_file.display().to_string(),
        status_path: status_file.display().to_string(),
        linkedin_filters_path: filters_path(&profile_dir).display().to_string(),
        services: SERVICES
            .iter()
            .map(|service| ServiceStatus {
                id: service.id.to_string(),
                label: service.label.to_string(),
                temperature: service.temperature.label().to_string(),
                startup: startup_for(&config, service.id),
                shortcut: service.shortcut_key.to_string(),
            })
            .collect(),
    };
    let raw = serde_json::to_string_pretty(&report)?;
    fs::write(&status_file, raw)?;
    Ok(status_file)
}

fn open_in_explorer(path: &Path) {
    let _ = hide_command_window(Command::new("explorer.exe")).arg(path).spawn();
}

fn toggle_theme(state: &Mutex<FirefoxState>) -> io::Result<ThemeMode> {
    let guard = state.lock().unwrap();
    let mut config = load_or_create_config(&guard.config_path)?;
    config.theme = config.theme.toggle();
    save_config(&guard.config_path, &config)?;
    write_profile_files(&guard.profile_dir, &config)?;
    Ok(config.theme)
}

fn reset_profile(state: &Mutex<FirefoxState>) -> io::Result<()> {
    kill_firefox(state);
    let guard = state.lock().unwrap();
    ensure_safe_profile_dir(&guard.profile_dir)?;
    if guard.profile_dir.exists() {
        fs::remove_dir_all(&guard.profile_dir)?;
    }
    fs::create_dir_all(&guard.app_dir)?;
    let config = load_or_create_config(&guard.config_path)?;
    write_profile_files(&guard.profile_dir, &config)?;
    Ok(())
}

fn open_all_services(state: &Mutex<FirefoxState>) -> io::Result<()> {
    if current_or_running_pid(state).is_some() {
        open_startup_services(state)
    } else {
        launch_firefox(state, &first_run_urls())
    }
}

fn open_startup_services(state: &Mutex<FirefoxState>) -> io::Result<()> {
    if let Some(pid) = current_or_running_pid(state) {
        return app_activate(pid);
    }
    let config_path = {
        let guard = state.lock().unwrap();
        guard.config_path.clone()
    };
    let config = load_or_create_config(&config_path)?;
    let startup_urls = configured_startup_urls(&config);
    launch_firefox(state, &startup_urls)
}

fn startup_shortcuts() -> Vec<Shortcut> {
    vec![
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit1),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit2),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit3),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit4),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit5),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyR),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyM),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyW),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyO),
        Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyD),
    ]
}

fn handle_shortcut(app: &AppHandle, shortcut: &Shortcut) {
    let state = app.state::<Mutex<FirefoxState>>();
    match shortcut {
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit1) => {
            let _ = open_service(&state, &SERVICES[0]);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit2) => {
            let _ = open_service(&state, &SERVICES[1]);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit3) => {
            let _ = open_service(&state, &SERVICES[2]);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit4) => {
            let _ = open_service(&state, &SERVICES[3]);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::Digit5) => {
            let _ = open_service(&state, &SERVICES[4]);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyR) => {
            let _ = refresh_current_tab(&state);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyM) => {
            let _ = mute_current_tab(&state);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyW) => {
            let _ = close_current_tab(&state);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyO) => {
            let _ = open_startup_services(&state);
        }
        s if *s == Shortcut::new(Some(Modifiers::CONTROL | Modifiers::ALT), Code::KeyD) => {
            if toggle_theme(&state).is_ok() {
                let _ = restart_with_configured_startup(&state);
            }
        }
        _ => {}
    }
}

fn main() {
    let app_dir = get_app_dir();
    let profile_dir = get_profile_dir(&app_dir);
    let config_path = config_path(&app_dir);
    let status_path = status_path(&app_dir);
    fs::create_dir_all(&app_dir).expect("Failed to create Tabburrito app dir");
    let config = load_or_create_config(&config_path).expect("Failed to load config");
    write_profile_files(&profile_dir, &config).expect("Failed to bootstrap Firefox profile");

    let firefox_state = Mutex::new(FirefoxState {
        child: None,
        app_dir,
        profile_dir: profile_dir.clone(),
        config_path: config_path.clone(),
        status_path: status_path.clone(),
    });

    tauri::Builder::default()
        .manage(firefox_state)
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            let state = app.state::<Mutex<FirefoxState>>();
            let _ = open_startup_services(&state);
        }))
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .plugin(
            tauri_plugin_global_shortcut::Builder::new()
                .with_handler(|app, shortcut, event| {
                    if event.state() == ShortcutState::Pressed {
                        handle_shortcut(app, shortcut);
                    }
                })
                .build(),
        )
        .setup(move |app| {
            let show = MenuItemBuilder::with_id("show", "Open Tabburrito").build(app)?;
            let open_all = MenuItemBuilder::with_id("open-all", "Open All Services").build(app)?;
            let refresh = MenuItemBuilder::with_id("refresh", "Refresh Current Tab").build(app)?;
            let mute = MenuItemBuilder::with_id("mute", "Mute/Unmute Current Tab").build(app)?;
            let close_tab = MenuItemBuilder::with_id("close-tab", "Close Current Tab").build(app)?;
            let theme = MenuItemBuilder::with_id("theme", "Toggle Dark/Light Theme").build(app)?;
            let autostart = MenuItemBuilder::with_id("autostart", "Toggle Autostart").build(app)?;
            let restart = MenuItemBuilder::with_id("restart", "Restart Tabburrito Firefox").build(app)?;
            let status = MenuItemBuilder::with_id("status", "Write Status Report").build(app)?;
            let profile = MenuItemBuilder::with_id("profile", "Open Profile Folder").build(app)?;
            let reset = MenuItemBuilder::with_id("reset", "Reset Isolated Profile").build(app)?;
            let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;

            let mut menu = MenuBuilder::new(app)
                .item(&show)
                .item(&open_all)
                .separator();

            for service in SERVICES {
                let item = MenuItemBuilder::with_id(
                    format!("service-{}", service.id),
                    format!("Open {}", service.label),
                )
                .build(app)?;
                menu = menu.item(&item);
            }

            let menu = menu
                .separator()
                .item(&refresh)
                .item(&mute)
                .item(&close_tab)
                .item(&theme)
                .item(&autostart)
                .item(&restart)
                .separator()
                .item(&status)
                .item(&profile)
                .item(&reset)
                .separator()
                .item(&quit)
                .build()?;

            let icon = Image::from_bytes(include_bytes!("../icons/icon.png"))
                .expect("failed to load tray icon");

            let _tray = TrayIconBuilder::with_id("main-tray")
                .icon(icon)
                .menu(&menu)
                .tooltip("Tabburrito Control")
                .on_menu_event(|app, event| {
                    let state = app.state::<Mutex<FirefoxState>>();
                    match event.id().as_ref() {
                        "show" => {
                            let _ = open_startup_services(&state);
                        }
                        "open-all" => {
                            let _ = open_all_services(&state);
                        }
                        "refresh" => {
                            let _ = refresh_current_tab(&state);
                        }
                        "mute" => {
                            let _ = mute_current_tab(&state);
                        }
                        "close-tab" => {
                            let _ = close_current_tab(&state);
                        }
                        "theme" => {
                            if toggle_theme(&state).is_ok() {
                                let _ = restart_with_configured_startup(&state);
                            }
                        }
                        "autostart" => {
                            let enabled = app.autolaunch().is_enabled().unwrap_or(false);
                            if enabled {
                                let _ = app.autolaunch().disable();
                            } else {
                                let _ = app.autolaunch().enable();
                            }
                        }
                        "restart" => {
                            let _ = restart_with_configured_startup(&state);
                        }
                        "status" => {
                            if let Ok(path) = write_status_report(app, &state) {
                                open_in_explorer(&path);
                            }
                        }
                        "profile" => {
                            let profile_dir = {
                                let guard = state.lock().unwrap();
                                guard.profile_dir.clone()
                            };
                            open_in_explorer(&profile_dir);
                        }
                        "reset" => {
                            if reset_profile(&state).is_ok() {
                                let _ = launch_firefox(&state, &first_run_urls());
                            }
                        }
                        "quit" => {
                            kill_firefox(&state);
                            app.exit(0);
                        }
                        other => {
                            if let Some(service) = service_for_menu_id(other) {
                                let _ = open_service(&state, service);
                            }
                        }
                    }
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::DoubleClick { .. } = event {
                        let state = tray.app_handle().state::<Mutex<FirefoxState>>();
                        let _ = open_startup_services(&state);
                    }
                })
                .build(app)?;

            for shortcut in startup_shortcuts() {
                let _ = app.global_shortcut().register(shortcut);
            }

            let state = app.state::<Mutex<FirefoxState>>();
            let _ = open_startup_services(&state);

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Tabburrito Lite");
}
