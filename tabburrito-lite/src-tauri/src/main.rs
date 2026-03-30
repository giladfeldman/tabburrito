// Tabburrito Lite — tray icon app that manages a Firefox instance
// No windows, no webviews — just the tray icon + Firefox process management
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::fs;
use std::path::PathBuf;
use std::process::{Child, Command};
use std::sync::Mutex;
use tauri::{
    image::Image,
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    Manager,
};
use tauri_plugin_autostart::MacosLauncher;

const FIREFOX_PATH: &str = r"C:\Program Files\Mozilla Firefox\firefox.exe";

const SERVICES: &[(&str, &str)] = &[
    ("WhatsApp", "https://web.whatsapp.com"),
    ("Messenger", "https://www.messenger.com"),
    ("LinkedIn", "https://www.linkedin.com/feed/"),
    ("Bluesky", "https://bsky.app"),
    ("Calendar", "https://accounts.google.com/ServiceLogin?continue=https://calendar.google.com/calendar/u/0/r?hl%3Den&hl=en"),
];

const USER_JS: &str = include_str!("../../user.js");

const USER_CHROME_CSS: &str = r#"
/* Tabburrito Lite — clean minimal UI */

/* Hide navigation bar (URL bar, back/forward, extensions) */
#nav-bar { display: none !important; }

/* Hide bookmarks toolbar */
#PersonalToolbar { display: none !important; }

/* Hide menu bar */
#toolbar-menubar { display: none !important; }

/* Hide Firefox View button */
#firefox-view-button { display: none !important; }

/* Hide new tab button */
#tabs-newtab-button, #new-tab-button { display: none !important; }

/* Hide all-tabs button */
#alltabs-button { display: none !important; }

/* Compact title bar spacers */
.titlebar-spacer[type="pre-tabs"] { max-width: 4px !important; }
.titlebar-spacer[type="post-tabs"] { max-width: 4px !important; }

/* Dark tab bar */
#TabsToolbar {
    --tab-min-height: 36px !important;
    background: #1a1a2e !important;
    -moz-window-dragging: drag !important;
}

#tabbrowser-tabs { background: #1a1a2e !important; }

/* Tabs: show favicon + short title */
.tabbrowser-tab {
    background: transparent !important;
    max-width: 150px !important;
    -moz-window-dragging: no-drag !important;
}

.tabbrowser-tab .tab-background {
    background: transparent !important;
    border: none !important;
}

.tabbrowser-tab[selected] .tab-background {
    background: #2a2a4a !important;
    border-radius: 6px !important;
    margin: 3px 1px !important;
}

.tabbrowser-tab .tab-label {
    color: #ccc !important;
    font-size: 11px !important;
}

.tabbrowser-tab[selected] .tab-label {
    color: #fff !important;
}

/* Hide close button on tabs */
.tab-close-button { display: none !important; }

/* Remove tab separators */
.tabbrowser-tab::after, .tabbrowser-tab::before { display: none !important; }

/* Sound indicator stays visible */
.tab-icon-sound { display: block !important; }
"#;

struct FirefoxState {
    child: Option<Child>,
    profile_dir: PathBuf,
}

fn get_profile_dir() -> PathBuf {
    let appdata = std::env::var("APPDATA").unwrap_or_else(|_| ".".to_string());
    PathBuf::from(appdata).join("TabburritoLite").join("profile")
}

fn ensure_profile(profile_dir: &PathBuf) {
    if !profile_dir.exists() {
        fs::create_dir_all(profile_dir).expect("Failed to create profile dir");
    }

    // Write user.js (always overwrite to pick up changes)
    let mut user_js = USER_JS.to_string();
    user_js.push_str("\n// Enable userChrome.css\n");
    user_js.push_str("user_pref(\"toolkit.legacyUserProfileCustomizations.stylesheets\", true);\n");
    // Auto-install extensions without prompt
    user_js.push_str("user_pref(\"extensions.autoDisableScopes\", 0);\n");
    user_js.push_str("user_pref(\"extensions.enabledScopes\", 15);\n");
    fs::write(profile_dir.join("user.js"), &user_js).expect("Failed to write user.js");

    // Write userChrome.css
    let chrome_dir = profile_dir.join("chrome");
    fs::create_dir_all(&chrome_dir).ok();
    fs::write(chrome_dir.join("userChrome.css"), USER_CHROME_CSS).expect("Failed to write userChrome.css");

    // Download uBlock Origin if not already present
    let ext_dir = profile_dir.join("extensions");
    fs::create_dir_all(&ext_dir).ok();
    let ublock_xpi = ext_dir.join("uBlock0@raymondhill.net.xpi");
    if !ublock_xpi.exists() {
        eprintln!("[Tabburrito] Downloading uBlock Origin...");
        let _ = Command::new("powershell")
            .args([
                "-NoProfile", "-Command",
                &format!(
                    "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; \
                     Invoke-WebRequest -Uri 'https://addons.mozilla.org/firefox/downloads/latest/ublock-origin/latest.xpi' \
                     -OutFile '{}' -UseBasicParsing",
                    ublock_xpi.to_str().unwrap().replace('\'', "''")
                ),
            ])
            .output();
        if ublock_xpi.exists() {
            eprintln!("[Tabburrito] uBlock Origin installed");
        } else {
            eprintln!("[Tabburrito] uBlock Origin download failed — install manually");
        }
    }

    // Write uBlock Origin custom filters for LinkedIn
    // These go into the storage folder after first run, but we can also
    // create a policies.json to auto-configure
    let policies_dir = profile_dir.parent().unwrap().join("distribution");
    fs::create_dir_all(&policies_dir).ok();
    // Note: Firefox policies can't configure uBlock filters directly,
    // but the filters need to be added via uBlock's dashboard after first run.
    // We write a helper HTML file the user can open to see the filters.
    let filters_file = profile_dir.join("linkedin-filters.txt");
    fs::write(&filters_file,
        "! Tabburrito LinkedIn Filters — paste into uBlock Origin > My Filters\n\
         www.linkedin.com##span:has-text(Promoted):upward(6)\n\
         www.linkedin.com##span:has-text(Suggested):upward(6)\n\
         www.linkedin.com##p:has-text(/^Promoted/):upward(6)\n\
         www.linkedin.com##span:has-text(Recommended for you):upward(6)\n\
         www.linkedin.com##.ad-banner-container\n\
         www.linkedin.com##.premium-upsell-link\n\
         www.linkedin.com##.feed-follows-module\n\
         www.linkedin.com##aside .artdeco-card:has(iframe)\n"
    ).ok();
}

fn launch_firefox(state: &Mutex<FirefoxState>, first_run: bool) {
    let mut s = state.lock().unwrap();

    // Check if already running
    if let Some(ref mut child) = s.child {
        match child.try_wait() {
            Ok(Some(_)) => { s.child = None; } // exited
            Ok(None) => return, // still running — don't launch another
            Err(_) => { s.child = None; }
        }
    }

    let profile = s.profile_dir.to_str().unwrap().to_string();
    let mut cmd = Command::new(FIREFOX_PATH);
    cmd.arg("--profile").arg(&profile).arg("--no-remote");

    if first_run {
        // First launch: open all service URLs
        for (_, url) in SERVICES {
            cmd.arg(url);
        }
    }
    // If not first run, Firefox session restore handles the tabs

    match cmd.spawn() {
        Ok(child) => {
            s.child = Some(child);
        }
        Err(e) => {
            eprintln!("Failed to launch Firefox: {}", e);
        }
    }
}

fn is_firefox_running(state: &Mutex<FirefoxState>) -> bool {
    let mut s = state.lock().unwrap();
    if let Some(ref mut child) = s.child {
        match child.try_wait() {
            Ok(Some(_)) => { s.child = None; false }
            Ok(None) => true,
            Err(_) => { s.child = None; false }
        }
    } else {
        false
    }
}

fn kill_firefox(state: &Mutex<FirefoxState>) {
    let mut s = state.lock().unwrap();
    if let Some(ref mut child) = s.child {
        let _ = child.kill();
        let _ = child.wait();
        s.child = None;
    }
}

fn main() {
    let profile_dir = get_profile_dir();
    let first_run = !profile_dir.join("prefs.js").exists(); // prefs.js exists after first Firefox run

    ensure_profile(&profile_dir);

    let firefox_state = Mutex::new(FirefoxState {
        child: None,
        profile_dir: profile_dir.clone(),
    });

    tauri::Builder::default()
        .manage(firefox_state)
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            // Second instance launched — show Firefox
            let state = app.state::<Mutex<FirefoxState>>();
            if !is_firefox_running(&state) {
                launch_firefox(&state, false);
            }
        }))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .setup(move |app| {
            // Build tray menu
            let show = MenuItemBuilder::with_id("show", "Open Tabburrito").build(app)?;
            let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;
            let menu = MenuBuilder::new(app)
                .item(&show)
                .separator()
                .item(&quit)
                .build()?;

            let icon = Image::from_bytes(include_bytes!("../icons/icon.png"))
                .expect("failed to load tray icon");

            let _tray = TrayIconBuilder::with_id("main-tray")
                .icon(icon)
                .menu(&menu)
                .tooltip("Tabburrito Lite")
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "show" => {
                        let state = app.state::<Mutex<FirefoxState>>();
                        if !is_firefox_running(&state) {
                            launch_firefox(&state, false);
                        }
                    }
                    "quit" => {
                        let state = app.state::<Mutex<FirefoxState>>();
                        kill_firefox(&state);
                        app.exit(0);
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::DoubleClick { .. } = event {
                        let app = tray.app_handle();
                        let state = app.state::<Mutex<FirefoxState>>();
                        if !is_firefox_running(&state) {
                            launch_firefox(&state, false);
                        }
                    }
                })
                .build(app)?;

            // Launch Firefox
            let state = app.state::<Mutex<FirefoxState>>();
            launch_firefox(&state, first_run);

            // Spawn a thread to monitor Firefox — if user closes Firefox, keep tray alive
            let app_handle = app.handle().clone();
            std::thread::spawn(move || {
                loop {
                    std::thread::sleep(std::time::Duration::from_secs(2));
                    let state = app_handle.state::<Mutex<FirefoxState>>();
                    // Just check — don't restart. User can reopen from tray.
                    is_firefox_running(&state);
                }
            });

            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("error while running Tabburrito Lite");
}
