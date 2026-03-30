// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use tauri::{
    image::Image,
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    webview::{NewWindowResponse, PageLoadEvent, WebviewBuilder},
    LogicalPosition, LogicalSize, Manager, WebviewUrl, WindowEvent,
};
use tauri_plugin_autostart::MacosLauncher;

const SIDEBAR_W: f64 = 56.0;
const URLBAR_H: f64 = 32.0;
const CHROME_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

struct Service {
    id: &'static str,
    url: &'static str,
    notify_default: bool,
}

const SERVICES: &[Service] = &[
    Service { id: "whatsapp", url: "https://web.whatsapp.com", notify_default: true },
    Service { id: "messenger", url: "https://www.messenger.com", notify_default: true },
    Service { id: "linkedin", url: "https://www.linkedin.com/feed/", notify_default: false },
    Service { id: "bluesky", url: "https://bsky.app", notify_default: false },
    Service { id: "calendar", url: "https://accounts.google.com/ServiceLogin?continue=https://calendar.google.com/calendar/u/0/r?hl%3Den&hl=en", notify_default: false },
];

// LinkedIn ad/noise blocker — JS-based, replicates uBlock Origin approach:
//   span:has-text(Promoted):upward(div.relative)
// LinkedIn wraps every feed item in <div class="relative">, so we find
// any span containing the keyword text and walk up to the nearest div.relative
const LINKEDIN_ADBLOCK_JS: &str = r#"
(function() {
    'use strict';

    const BLOCK_TEXTS = ['promoted', 'suggested'];
    const BLOCK_TEXTS_FULL = [
        'recommended for you', 'events recommended for you',
        'jobs recommended for you', "today's top courses",
        'linkedin news', 'take a break with a linkedin puzzle',
        'grow your career',
    ];

    const CSS = `
        [data-tb-hidden="1"] {
            display: none !important;
            height: 0 !important;
            overflow: hidden !important;
        }
        .ad-banner-container, [data-ad-banner], .premium-upsell-link,
        .feed-follows-module, .news-module, .feed-shared-news-module,
        .feed-shared-update-v2--e-promoted, .is-promoted,
        [class*="--is-sponsored"] {
            display: none !important;
        }
    `;

    function injectCSS() {
        if (!document.getElementById('tb-li-css')) {
            const s = document.createElement('style');
            s.id = 'tb-li-css';
            s.textContent = CSS;
            (document.head || document.documentElement).appendChild(s);
        }
    }

    // Walk up from an element to the nearest div.relative (LinkedIn's feed item wrapper)
    // or other known feed containers. This mimics uBlock's :upward() selector.
    function findContainer(el) {
        let node = el;
        for (let i = 0; i < 25 && node; i++) {
            node = node.parentElement;
            if (!node) return null;
            // LinkedIn 2026: posts are wrapped in divs with componentkey attributes
            // The outermost componentkey div that contains the full post
            if (node.tagName === 'DIV' && node.hasAttribute('componentkey')) {
                // Check if this is a top-level feed item (has h2 "Feed post" inside)
                const h2 = node.querySelector('h2');
                if (h2 && h2.textContent.includes('Feed post')) return node;
            }
            // div.relative wrapper (older LinkedIn)
            if (node.tagName === 'DIV' && node.classList.contains('relative')) return node;
            // Known feed item classes
            if (node.classList.contains('feed-shared-update-v2') ||
                node.classList.contains('feed-shared-update') ||
                node.classList.contains('fie-impression-container')) return node;
            // data-id with activity URN
            if (node.dataset?.id?.includes('urn:li:activity') ||
                node.dataset?.id?.includes('urn:li:aggregate')) return node;
        }
        return null;
    }

    function hide(el) {
        if (!el || el.getAttribute('data-tb-hidden') === '1') return;
        el.setAttribute('data-tb-hidden', '1');
        hideCount++;
    }

    let hideCount = 0;
    const MAX_HIDES_PER_SCAN = 5;

    function scan() {
        let hiddenThisScan = 0;
        // Strategy 1: TreeWalker — find text nodes that are exactly labels
        // Only match short text nodes (< 40 chars) to avoid body text false positives
        if (document.body) {
            const walker = document.createTreeWalker(
                document.body, NodeFilter.SHOW_TEXT, null
            );
            let textNode;
            while (textNode = walker.nextNode()) {
                const raw = textNode.textContent.trim();
                if (!raw || raw.length > 40) continue;
                const txt = raw.toLowerCase();
                const isLabel = (txt === 'promoted' || txt.startsWith('promoted by')) ||
                    txt === 'suggested' ||
                    BLOCK_TEXTS_FULL.some(kw => txt === kw);
                if (isLabel) {
                    const parent = textNode.parentElement;
                    if (!parent || parent.closest('[data-tb-hidden="1"]')) continue;
                    const c = findContainer(parent);
                    if (c) hide(c);
                }
            }
        }

        // Strategy 2: Find short <p> and <span> label elements
        // The "Promoted" / "Promoted by X" label is always a short element (< 80 chars)
        // This avoids hiding posts where someone writes "I got promoted" in the body
        document.querySelectorAll('p, span').forEach(el => {
            if (el.closest('[data-tb-hidden="1"]')) return;
            const txt = el.textContent.trim();
            if (txt.length > 80) return; // skip long text — it's post body, not a label
            const lower = txt.toLowerCase();
            if (lower === 'promoted' || lower.startsWith('promoted by') ||
                lower === 'suggested') {
                const c = findContainer(el);
                if (c) hide(c);
            }
        });

        // Strategy 4: Right sidebar ads
        document.querySelectorAll('aside .artdeco-card:not([data-tb-hidden="1"])').forEach(card => {
            const txt = card.textContent.toLowerCase();
            if ((txt.includes('job search') && txt.includes('powered by')) ||
                txt.includes('explore jobs') || card.querySelector('iframe')) {
                hide(card);
            }
        });
    }

    injectCSS();

    // Debounced observer — pauses during scan to prevent cascading
    let timer;
    let paused = false;
    const obs = new MutationObserver(() => {
        if (paused) return;
        clearTimeout(timer);
        timer = setTimeout(() => {
            paused = true;
            scan();
            setTimeout(() => { paused = false; }, 500);
        }, 300);
    });
    function start() {
        if (document.body) {
            obs.observe(document.body, { childList: true, subtree: true });
            scan();
        } else {
            setTimeout(start, 50);
        }
    }
    start();

    // Safety net — not too aggressive
    setInterval(() => {
        paused = true;
        scan();
        setTimeout(() => { paused = false; }, 500);
    }, 5000);

    console.log('[Tabburrito] LinkedIn blocker active');
})();
"#;

#[tauri::command]
async fn show_service(app: tauri::AppHandle, label: String) -> Result<(), String> {
    for svc in SERVICES {
        if let Some(wv) = app.get_webview(svc.id) {
            if svc.id == label.as_str() {
                wv.show().map_err(|e| e.to_string())?;
                wv.set_focus().map_err(|e| e.to_string())?;
            } else {
                let _ = wv.hide();
            }
        }
    }
    Ok(())
}

#[tauri::command]
async fn refresh_service(app: tauri::AppHandle, label: String) -> Result<(), String> {
    if let Some(svc) = SERVICES.iter().find(|s| s.id == label.as_str()) {
        if let Some(wv) = app.get_webview(svc.id) {
            let url: url::Url = svc.url.parse().map_err(|e: url::ParseError| e.to_string())?;
            wv.navigate(url).map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

#[tauri::command]
async fn navigate_service(app: tauri::AppHandle, label: String, url: String) -> Result<(), String> {
    if let Some(wv) = app.get_webview(&label) {
        let parsed: url::Url = url.parse().map_err(|e: url::ParseError| e.to_string())?;
        wv.navigate(parsed).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn zoom_service(app: tauri::AppHandle, label: String, zoom: f64) -> Result<(), String> {
    if let Some(wv) = app.get_webview(&label) {
        wv.set_zoom(zoom).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn get_autostart_enabled(app: tauri::AppHandle) -> Result<bool, String> {
    use tauri_plugin_autostart::ManagerExt;
    app.autolaunch().is_enabled().map_err(|e| e.to_string())
}

#[tauri::command]
async fn set_autostart_enabled(app: tauri::AppHandle, enabled: bool) -> Result<(), String> {
    use tauri_plugin_autostart::ManagerExt;
    if enabled {
        app.autolaunch().enable().map_err(|e| e.to_string())
    } else {
        app.autolaunch().disable().map_err(|e| e.to_string())
    }
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(w) = app.get_window("main") {
                let _ = w.show();
                let _ = w.unminimize();
                let _ = w.set_focus();
            }
        }))
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_window_state::Builder::new().build())
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .invoke_handler(tauri::generate_handler![
            show_service,
            refresh_service,
            navigate_service,
            zoom_service,
            get_autostart_enabled,
            set_autostart_enabled,
        ])
        .setup(|app| {
            let window = tauri::window::WindowBuilder::new(app, "main")
                .title("Tabburrito")
                .inner_size(1200.0, 800.0)
                .min_inner_size(800.0, 600.0)
                .maximized(true)
                .visible(true)
                .build()?;

            // Use the monitor work area (screen minus taskbar) for sizing
            // This ensures webviews fill correctly when maximized
            let scale = window.scale_factor().unwrap_or(1.0);
            let (w, h) = if let Ok(Some(monitor)) = window.current_monitor() {
                let wa = monitor.work_area();
                (wa.size.width as f64 / scale, wa.size.height as f64 / scale)
            } else {
                let win_size = window.inner_size().unwrap_or(tauri::PhysicalSize::new(1920, 1080));
                (win_size.width as f64 / scale, win_size.height as f64 / scale)
            };
            let content_w = w - SIDEBAR_W;

            // Sidebar
            window.add_child(
                WebviewBuilder::new("sidebar", WebviewUrl::App("index.html".into()))
                    .auto_resize(),
                LogicalPosition::new(0.0, 0.0),
                LogicalSize::new(SIDEBAR_W, h),
            )?;

            // Service webviews — offset by URL bar height
            let app_handle = app.handle().clone();
            for (i, svc) in SERVICES.iter().enumerate() {
                let url: url::Url = svc.url.parse().unwrap();
                let ah = app_handle.clone();
                let svc_id = svc.id.to_string();
                let mut builder = WebviewBuilder::new(svc.id, WebviewUrl::External(url))
                    .user_agent(CHROME_UA)
                    .auto_resize()
                    .zoom_hotkeys_enabled(true)
                    .on_navigation(|_| true)
                    .on_new_window(move |url, _features| {
                        // Handle popups (Google OAuth, etc.) by opening in a new window
                        static POPUP_COUNTER: std::sync::atomic::AtomicU32 = std::sync::atomic::AtomicU32::new(0);
                        let n = POPUP_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        let label = format!("popup-{}-{}", svc_id, n);

                        match tauri::WebviewWindowBuilder::new(
                            &ah,
                            &label,
                            WebviewUrl::External(url.clone()),
                        )
                        .user_agent(CHROME_UA)
                        .title(url.as_str())
                        .inner_size(600.0, 700.0)
                        .build()
                        {
                            Ok(win) => NewWindowResponse::Create { window: win },
                            Err(_) => NewWindowResponse::Allow,
                        }
                    });

                // LinkedIn: inject adblock via on_page_load (avoids CSP blocking)
                if svc.id == "linkedin" {
                    let script = LINKEDIN_ADBLOCK_JS.to_string();
                    builder = builder
                        .initialization_script(LINKEDIN_ADBLOCK_JS)
                        .on_page_load(move |webview, payload| {
                            if payload.event() == PageLoadEvent::Finished {
                                let _ = webview.eval(&script);
                            }
                        });
                }

                let wv = window.add_child(
                    builder,
                    LogicalPosition::new(SIDEBAR_W, URLBAR_H),
                    LogicalSize::new(content_w, h - URLBAR_H),
                )?;
                // Hide all — sidebar JS will show the correct one after window is ready
                wv.hide()?;
            }

            // URL bar webview (between sidebar and content)
            window.add_child(
                WebviewBuilder::new("urlbar", WebviewUrl::App("urlbar.html".into()))
                    .auto_resize(),
                LogicalPosition::new(SIDEBAR_W, 0.0),
                LogicalSize::new(content_w, URLBAR_H),
            )?;

            // Tray icon with embedded PNG
            let icon = Image::from_bytes(include_bytes!("../icons/icon.png"))
                .expect("failed to load tray icon");

            let show = MenuItemBuilder::with_id("show", "Show Tabburrito").build(app)?;
            let quit = MenuItemBuilder::with_id("quit", "Quit").build(app)?;
            let menu = MenuBuilder::new(app)
                .item(&show)
                .separator()
                .item(&quit)
                .build()?;

            let _tray = TrayIconBuilder::with_id("main-tray")
                .icon(icon)
                .menu(&menu)
                .tooltip("Tabburrito")
                .on_menu_event(|app, event| match event.id().as_ref() {
                    "show" => {
                        if let Some(w) = app.get_window("main") {
                            let _ = w.show();
                            let _ = w.unminimize();
                            let _ = w.set_focus();
                        }
                    }
                    "quit" => app.exit(0),
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let tauri::tray::TrayIconEvent::DoubleClick { .. } = event {
                        if let Some(w) = tray.app_handle().get_window("main") {
                            let _ = w.show();
                            let _ = w.unminimize();
                            let _ = w.set_focus();
                        }
                    }
                })
                .build(app)?;

            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                let _ = window.hide();
                api.prevent_close();
            }
        })
        .run(tauri::generate_context!())
        .expect("error while running Tabburrito");
}
