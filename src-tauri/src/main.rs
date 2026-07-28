// Prevents additional console window on Windows in release
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use tauri::{
    image::Image,
    menu::{MenuBuilder, MenuItemBuilder},
    tray::TrayIconBuilder,
    webview::{DownloadEvent, NewWindowResponse, PageLoadEvent, WebviewBuilder},
    Emitter, LogicalPosition, LogicalSize, Manager, WebviewUrl, WindowEvent,
};
use tauri_plugin_autostart::MacosLauncher;

#[cfg(debug_assertions)]
fn agent_debug_log(hypothesis_id: &str, location: &str, message: &str, data: serde_json::Value) {
    let _ = (hypothesis_id, location, message, data);
}

#[cfg(not(debug_assertions))]
fn agent_debug_log(_hypothesis_id: &str, _location: &str, _message: &str, _data: serde_json::Value) {}

const SIDEBAR_W: f64 = 56.0;
const URLBAR_H: f64 = 32.0;
const DEFAULT_COLD_UNLOAD_SECS: u64 = 180;
const CHROME_UA: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

fn exe_dir() -> std::path::PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|p| p.to_path_buf()))
        .unwrap_or_else(|| std::path::PathBuf::from("."))
}

fn webview_data_dir() -> std::path::PathBuf {
    exe_dir().join("TabburritoWebViewData").join("main")
}

fn shell_webview_data_dir() -> std::path::PathBuf {
    exe_dir().join("TabburritoWebViewData").join("shell")
}

#[cfg(windows)]
fn show_save_file_dialog(
    suggested_name: &str,
    initial_dir: Option<&std::path::Path>,
) -> Option<std::path::PathBuf> {
    use std::os::windows::ffi::{OsStrExt, OsStringExt};

    #[repr(C)]
    struct OpenFilenameW {
        l_struct_size: u32,
        hwnd_owner: *mut core::ffi::c_void,
        h_instance: *mut core::ffi::c_void,
        lpstr_filter: *const u16,
        lpstr_custom_filter: *mut u16,
        n_max_cust_filter: u32,
        n_filter_index: u32,
        lpstr_file: *mut u16,
        n_max_file: u32,
        lpstr_file_title: *mut u16,
        n_max_file_title: u32,
        lpstr_initial_dir: *const u16,
        lpstr_title: *const u16,
        flags: u32,
        n_file_offset: u16,
        n_file_extension: u16,
        lpstr_def_ext: *const u16,
        l_cust_data: isize,
        lpfn_hook: *mut core::ffi::c_void,
        lp_template_name: *const u16,
        pv_reserved: *mut core::ffi::c_void,
        dw_reserved: u32,
        flags_ex: u32,
    }

    #[link(name = "comdlg32")]
    extern "system" {
        fn GetSaveFileNameW(ofn: *mut OpenFilenameW) -> i32;
    }

    const OFN_OVERWRITEPROMPT: u32 = 0x0000_0002;
    const OFN_PATHMUSTEXIST: u32 = 0x0000_0800;
    const OFN_EXPLORER: u32 = 0x0008_0000;
    const OFN_NOCHANGEDIR: u32 = 0x0000_0008;
    const MAX_PATH_BUF: usize = 32768;

    fn to_wide(s: &str) -> Vec<u16> {
        std::ffi::OsStr::new(s)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect()
    }

    let mut file_buf: Vec<u16> = vec![0; MAX_PATH_BUF];
    let suggested_wide: Vec<u16> = std::ffi::OsStr::new(suggested_name)
        .encode_wide()
        .collect();
    let copy_len = suggested_wide.len().min(MAX_PATH_BUF - 1);
    file_buf[..copy_len].copy_from_slice(&suggested_wide[..copy_len]);

    let title = to_wide("Save As");
    let filter = to_wide("All Files (*.*)\0*.*");
    let initial_dir_wide = initial_dir.map(|p| {
        std::ffi::OsStr::new(p)
            .encode_wide()
            .chain(std::iter::once(0))
            .collect::<Vec<u16>>()
    });

    let mut ofn = OpenFilenameW {
        l_struct_size: std::mem::size_of::<OpenFilenameW>() as u32,
        hwnd_owner: std::ptr::null_mut(),
        h_instance: std::ptr::null_mut(),
        lpstr_filter: filter.as_ptr(),
        lpstr_custom_filter: std::ptr::null_mut(),
        n_max_cust_filter: 0,
        n_filter_index: 1,
        lpstr_file: file_buf.as_mut_ptr(),
        n_max_file: MAX_PATH_BUF as u32,
        lpstr_file_title: std::ptr::null_mut(),
        n_max_file_title: 0,
        lpstr_initial_dir: initial_dir_wide
            .as_ref()
            .map(|v| v.as_ptr())
            .unwrap_or(std::ptr::null()),
        lpstr_title: title.as_ptr(),
        flags: OFN_EXPLORER | OFN_OVERWRITEPROMPT | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR,
        n_file_offset: 0,
        n_file_extension: 0,
        lpstr_def_ext: std::ptr::null(),
        l_cust_data: 0,
        lpfn_hook: std::ptr::null_mut(),
        lp_template_name: std::ptr::null(),
        pv_reserved: std::ptr::null_mut(),
        dw_reserved: 0,
        flags_ex: 0,
    };

    let ok = unsafe { GetSaveFileNameW(&mut ofn) };
    if ok == 0 {
        return None;
    }

    let len = file_buf.iter().position(|&c| c == 0).unwrap_or(file_buf.len());
    let path = std::ffi::OsString::from_wide(&file_buf[..len]);
    Some(std::path::PathBuf::from(path))
}

#[cfg(not(windows))]
fn show_save_file_dialog(
    _suggested_name: &str,
    _initial_dir: Option<&std::path::Path>,
) -> Option<std::path::PathBuf> {
    None
}

struct Service {
    id: &'static str,
    url: &'static str,
    keep_loaded: bool,
    internal_hosts: &'static [&'static str],
}

const SERVICES: &[Service] = &[
    Service {
        id: "whatsapp",
        url: "https://web.whatsapp.com",
        keep_loaded: true,
        internal_hosts: &["web.whatsapp.com", "whatsapp.net"],
    },
    Service {
        id: "messenger",
        url: "https://www.messenger.com",
        keep_loaded: false,
        internal_hosts: &["messenger.com", "facebook.com"],
    },
    Service {
        id: "linkedin",
        url: "https://www.linkedin.com/feed/",
        keep_loaded: false,
        internal_hosts: &["linkedin.com"],
    },
    Service {
        id: "bluesky",
        url: "https://bsky.app",
        keep_loaded: false,
        internal_hosts: &["bsky.app"],
    },
    Service {
        id: "calendar",
        url: "https://accounts.google.com/ServiceLogin?continue=https://calendar.google.com/calendar/u/0/r?hl%3Den&hl=en",
        keep_loaded: true,
        internal_hosts: &["accounts.google.com", "calendar.google.com"],
    },
];

// LinkedIn ad/noise blocker — JS-based, replicates uBlock Origin approach:
//   span:has-text(Promoted):upward(div.relative)
// LinkedIn wraps every feed item in <div class="relative">, so we find
// any span containing the keyword text and walk up to the nearest div.relative
const LINKEDIN_ADBLOCK_JS: &str = r#"
(function() {
    'use strict';

    const CSS = `
        [data-tb-hidden="1"] {
            display: none !important;
            height: 0 !important;
            overflow: hidden !important;
        }
        .ad-banner-container, [data-ad-banner], .premium-upsell-link,
        .feed-follows-module, .news-module, .feed-shared-news-module {
            display: none !important;
        }
    `;

    const MARKER_TEXTS = new Set([
        'promoted',
        'suggested',
        'recommended for you',
        'events recommended for you',
        'jobs recommended for you',
        "today's top courses",
        'linkedin news',
        'take a break with a linkedin puzzle',
        'grow your career',
    ]);

    function injectCSS() {
        if (!document.getElementById('tb-li-css')) {
            const s = document.createElement('style');
            s.id = 'tb-li-css';
            s.textContent = CSS;
            (document.head || document.documentElement).appendChild(s);
        }
    }

    // A single feed post is wrapped in a div whose componentkey contains
    // "FeedType" (e.g. FeedType_MAIN_FEED_RELEVANCE) in the current LinkedIn DOM.
    // Older layouts used .feed-shared-update-v2 / article / urn:li:activity ids.
    // NOTE: the hashed class names (._297bc8a0 …) are volatile and intentionally
    // not matched on; only the semantic componentkey / urn anchors are.
    const POST_SELECTOR =
        '[componentkey*="FeedType"], .feed-shared-update-v2, .feed-shared-update, ' +
        '.fie-impression-container, article[data-id*="urn:li:activity"], ' +
        '[data-id*="urn:li:activity"], [data-id*="urn:li:aggregate"], [data-urn*="urn:li:activity"]';
    // Counts only top-level post wrappers — used to bound the blast radius.
    const POST_COUNT_SELECTOR =
        '[componentkey*="FeedType"], .feed-shared-update-v2, article[data-id*="urn:li:activity"]';

    function feedPostCount() {
        return document.querySelectorAll(POST_COUNT_SELECTOR).length;
    }
    function hiddenPostCount() {
        return document.querySelectorAll(
            '[componentkey*="FeedType"][data-tb-hidden="1"], ' +
            '.feed-shared-update-v2[data-tb-hidden="1"], ' +
            'article[data-id*="urn:li:activity"][data-tb-hidden="1"]'
        ).length;
    }

    // Resolve a marker element to the SINGLE post that contains it. We take the
    // nearest post wrapper (never climb past it) and refuse any candidate that
    // itself wraps two or more posts (a "Suggested" section / carousel). This
    // makes it structurally impossible to hide the whole stream from one marker.
    function findContainer(el) {
        const c = el.closest?.(POST_SELECTOR);
        if (!c || c.closest('aside, nav, header, footer')) return null;
        // A reshare embeds one nested post; a section embeds several. Allow <= 1.
        const nested = c.querySelectorAll(POST_COUNT_SELECTOR).length;
        if (nested >= 2) return null;
        return c;
    }

    let warnedCap = false;
    function hideFromMarker(el) {
        const c = findContainer(el);
        if (!c || c.closest('[data-tb-hidden="1"]')) return;
        // Circuit breaker: never let hidden posts exceed 60% of the loaded feed.
        // If a selector ever starts matching organic posts, this protects the
        // feed instead of blanking it (the regression this code path caused).
        const total = feedPostCount();
        if (total > 0 && hiddenPostCount() >= Math.max(4, Math.floor(total * 0.6))) {
            if (!warnedCap) {
                console.warn('[Tabburrito] feed-hide cap reached — skipping to protect feed (possible false match)');
                warnedCap = true;
            }
            return;
        }
        hide(c);
    }

    function isBlockedMarkerText(txt) {
        return MARKER_TEXTS.has(txt) ||
            txt.startsWith('promoted by') ||
            txt.includes('sponsored content');
    }

    function hide(el) {
        if (!el || el.getAttribute('data-tb-hidden') === '1') return;
        el.setAttribute('data-tb-hidden', '1');
        hideCount++;
    }

    let hideCount = 0;

    function scan() {
        warnedCap = false;
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
                if (isBlockedMarkerText(txt)) {
                    const parent = textNode.parentElement;
                    if (!parent) continue;
                    hideFromMarker(parent);
                }
            }
        }

        // Strategy 2: Find short <p> and <span> label elements
        // The "Promoted" / "Promoted by X" label is always a short element (< 80 chars)
        // This avoids hiding posts where someone writes "I got promoted" in the body
        document.querySelectorAll('p, span').forEach(el => {
            const txt = el.textContent.trim();
            if (txt.length > 80) return; // skip long text — it's post body, not a label
            const lower = txt.toLowerCase();
            if (isBlockedMarkerText(lower)) {
                hideFromMarker(el);
            }
        });

        // Strategy 3: Sponsored marker classes are sometimes attached to a
        // nested header/label instead of the whole post.
        document.querySelectorAll(
            '.feed-shared-update-v2--e-promoted, .is-promoted, [class*="--is-sponsored"], [data-sponsored="true"]'
        ).forEach(hideFromMarker);

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

// LinkedIn feed Top/Recent enforcer — semantic text only, no hashed classes.
const LINKEDIN_FEED_SORT_JS: &str = r#"
(function() {
    'use strict';
    if (window.__tbFeedSortBootstrapped) {
        if (typeof window.__tbApplyLinkedInSort === 'function') {
            window.__tbApplyLinkedInSort(window.__tbLinkedInSort || 'recent');
        }
        return;
    }
    window.__tbFeedSortBootstrapped = true;
    if (!window.__tbLinkedInSort) window.__tbLinkedInSort = 'recent';

    function want() {
        return (window.__tbLinkedInSort === 'top') ? 'top' : 'recent';
    }
    function wantLabel() {
        return want() === 'recent' ? 'Recent' : 'Top';
    }

    function norm(s) {
        return (s || '').replace(/\s+/g, ' ').trim();
    }
    function lower(s) { return norm(s).toLowerCase(); }

    function visible(el) {
        if (!el || !el.getBoundingClientRect) return false;
        const r = el.getBoundingClientRect();
        return r.width > 0 && r.height > 0;
    }

    function clickEl(el) {
        if (!el) return false;
        try {
            el.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, view: window }));
            return true;
        } catch (_) {
            try { el.click(); return true; } catch (e) { return false; }
        }
    }

    function currentSort() {
        const nodes = document.querySelectorAll('button, [role="button"], [aria-haspopup="menu"]');
        for (const el of nodes) {
            if (!visible(el)) continue;
            const t = lower(el.textContent || el.getAttribute('aria-label') || '');
            if (!t) continue;
            if (t.includes('sort by') && t.includes('recent')) return 'recent';
            if (t.includes('sort by') && t.includes('top')) return 'top';
            if (t === 'recent' || t === 'top') {
                const parent = el.closest('[class], div, section') || el.parentElement;
                const pt = lower(parent && parent.textContent);
                if (pt && pt.includes('sort')) return t === 'recent' ? 'recent' : 'top';
            }
        }
        const selected = document.querySelectorAll('[aria-checked="true"], [aria-selected="true"], [role="menuitemradio"][aria-checked="true"]');
        for (const el of selected) {
            const t = lower(el.textContent || '');
            if (t === 'recent' || t.includes('most recent')) return 'recent';
            if (t === 'top' || t.includes('top post') || t.includes('most relevant')) return 'top';
        }
        return null;
    }

    function findSortTrigger() {
        const nodes = [...document.querySelectorAll('button, [role="button"], [aria-haspopup="menu"]')];
        let best = null;
        for (const el of nodes) {
            if (!visible(el)) continue;
            const t = lower(el.textContent || el.getAttribute('aria-label') || '');
            if (!t) continue;
            if (t.includes('sort by')) return el;
            if (t === 'top' || t === 'recent') {
                const nearby = lower((el.parentElement && el.parentElement.textContent) || '');
                if (nearby.includes('sort')) best = best || el;
            }
        }
        return best;
    }

    function findMenuOption(target) {
        const labels = target === 'recent'
            ? ['recent', 'most recent', 'recent posts']
            : ['top', 'top posts', 'most relevant', 'relevant'];
        const nodes = document.querySelectorAll('[role="menuitem"], [role="menuitemradio"], [role="option"], button, [role="button"], div[role="listitem"]');
        for (const el of nodes) {
            if (!visible(el)) continue;
            const t = lower(el.textContent || el.getAttribute('aria-label') || '');
            if (!t || t.length > 40) continue;
            for (const label of labels) {
                if (t === label || t.startsWith(label + ' ') || t.includes(label)) {
                    if (t === label || t.startsWith(label)) return el;
                }
            }
        }
        return null;
    }

    let applying = false;
    function apply() {
        if (applying) return;
        if (!location.pathname.includes('/feed')) return;
        const target = want();
        const cur = currentSort();
        if (cur === target) return;
        applying = true;
        try {
            const trigger = findSortTrigger();
            if (!trigger) { applying = false; return; }
            const alreadyOpen = !!findMenuOption(target);
            if (!alreadyOpen) clickEl(trigger);
            setTimeout(() => {
                const opt = findMenuOption(target);
                if (opt) clickEl(opt);
                applying = false;
            }, 250);
        } catch (_) {
            applying = false;
        }
    }

    window.__tbApplyLinkedInSort = function(sort) {
        window.__tbLinkedInSort = (sort === 'top') ? 'top' : 'recent';
        apply();
    };

    setTimeout(apply, 800);
    setTimeout(apply, 2000);
    setTimeout(apply, 5000);
    setInterval(() => {
        const cur = currentSort();
        if (cur && cur !== want()) apply();
    }, 4000);

    const obs = new MutationObserver(() => {
        if (window.__tbSortObsTimer) return;
        window.__tbSortObsTimer = setTimeout(() => {
            window.__tbSortObsTimer = null;
            apply();
        }, 600);
    });
    try {
        obs.observe(document.documentElement, { childList: true, subtree: true });
    } catch (_) {}

    console.log('[Tabburrito] LinkedIn feed sort → ' + wantLabel());
})();
"#;

// WhatsApp / Messenger 1:1 DM unread reporter — encodes count into document.title.
const UNREAD_BOOTSTRAP_JS: &str = r#"
(function() {
    'use strict';
    if (window.__tbUnreadBootstrapped) return;
    window.__tbUnreadBootstrapped = true;
    const MARK = '\u2063';
    const host = location.hostname || '';

    function report(n) {
        n = Math.max(0, Math.floor(Number(n) || 0));
        if (window.__tbLastUnread === n) return;
        window.__tbLastUnread = n;
        try {
            const cleaned = String(document.title || '').replace(new RegExp(MARK + 'TB\\d+' + MARK, 'g'), '');
            document.title = cleaned + MARK + 'TB' + n + MARK;
        } catch (_) {}
    }

    function parseCount(text) {
        const m = String(text || '').match(/(\d+)/);
        return m ? parseInt(m[1], 10) : 0;
    }

    function isGroupish(el) {
        if (!el) return true;
        const hay = (
            (el.getAttribute('aria-label') || '') + ' ' +
            (el.getAttribute('title') || '') + ' ' +
            (el.textContent || '')
        ).toLowerCase();
        if (/\b(group|community|channel|broadcast|announcement|status)\b/.test(hay)) return true;
        if (el.querySelector('[data-testid="default-group"], [data-testid="group"], [data-icon="default-group"], [data-icon="community"], [data-testid="default-community"], [data-testid="newsletter-icon"], [data-testid="channel-icon"]')) {
            return true;
        }
        // Stacked/multi avatars often indicate groups
        const imgs = el.querySelectorAll('img');
        if (imgs.length >= 3) return true;
        return false;
    }

    function countWhatsApp() {
        let total = 0;
        const badges = document.querySelectorAll(
            'span[aria-label*="unread message" i], span[aria-label*="unread messages" i], [data-testid="icon-unread-count"], span[data-testid="icon-unread-count"]'
        );
        const seen = new Set();
        badges.forEach((badge) => {
            const row = badge.closest('[data-testid="cell-frame-container"]')
                || badge.closest('[role="listitem"]')
                || badge.closest('div[tabindex="-1"]')
                || badge.parentElement;
            if (!row || seen.has(row)) return;
            seen.add(row);
            if (isGroupish(row)) return;
            const label = badge.getAttribute('aria-label') || badge.textContent || '';
            const n = parseCount(label) || parseCount(badge.textContent) || 1;
            if (n > 0) total += n;
        });
        // Fallback: green unread pills inside chat list without aria-label
        if (total === 0) {
            document.querySelectorAll('#pane-side span').forEach((span) => {
                const t = (span.textContent || '').trim();
                if (!/^\d{1,3}$/.test(t)) return;
                const row = span.closest('[data-testid="cell-frame-container"]')
                    || span.closest('[role="listitem"]')
                    || span.closest('div[tabindex="-1"]');
                if (!row || isGroupish(row)) return;
                // Likely a timestamp if gray and not badge-like — require parent with unread styling heuristics
                const parentText = (span.parentElement && span.parentElement.getAttribute('aria-label')) || '';
                if (/unread/i.test(parentText) || /unread/i.test(span.getAttribute('aria-label') || '')) {
                    total += parseInt(t, 10);
                }
            });
        }
        return total;
    }

    function countMessenger() {
        let total = 0;
        const rows = document.querySelectorAll(
            '[role="row"], [role="listitem"], a[href*="/messages/"], a[href*="/t/"]'
        );
        const seen = new Set();
        rows.forEach((row) => {
            if (seen.has(row)) return;
            // Prefer the chat row container
            const container = row.closest('[role="row"]') || row;
            if (seen.has(container)) return;
            seen.add(container);
            if (isGroupish(container)) return;

            const aria = (container.getAttribute('aria-label') || '').toLowerCase();
            // Messenger often encodes unread in aria-label: "X unread items" / "unread"
            let n = 0;
            const m = aria.match(/(\d+)\s+unread/);
            if (m) n = parseInt(m[1], 10);
            else if (/\bunread\b/.test(aria)) n = 1;

            // Blue unread dot / badge
            if (n === 0) {
                const badge = container.querySelector(
                    '[aria-label*="unread" i], [data-visualcompletion="ignore"] span'
                );
                if (badge) {
                    const bt = (badge.getAttribute('aria-label') || badge.textContent || '').trim();
                    if (/unread/i.test(bt)) n = parseCount(bt) || 1;
                    else if (/^\d{1,3}$/.test(bt)) {
                        // numeric badge near bold title is a common unread pattern
                        const bold = container.querySelector('span[style*="font-weight"], strong, [class*="bold"]');
                        if (bold) n = parseInt(bt, 10);
                    }
                }
            }

            // Fail closed: if we can't confirm DM + unread, skip
            if (n > 0) total += n;
        });
        return total;
    }

    function tick() {
        try {
            let n = 0;
            if (host.includes('whatsapp')) n = countWhatsApp();
            else if (host.includes('messenger') || host.includes('facebook')) n = countMessenger();
            report(n);
        } catch (_) {}
    }

    window.__tbGetDmUnread = function() {
        if (host.includes('whatsapp')) return countWhatsApp();
        if (host.includes('messenger') || host.includes('facebook')) return countMessenger();
        return 0;
    };

    setTimeout(tick, 1500);
    setInterval(tick, 3000);
    const obs = new MutationObserver(() => {
        if (window.__tbUnreadObsTimer) return;
        window.__tbUnreadObsTimer = setTimeout(() => {
            window.__tbUnreadObsTimer = null;
            tick();
        }, 500);
    });
    try { obs.observe(document.documentElement, { childList: true, subtree: true, characterData: true }); } catch (_) {}
})();
"#;

fn external_link_bootstrap_js(internal_hosts: &[&str]) -> String {
    let hosts_list = internal_hosts
        .iter()
        .map(|host| format!("\"{host}\""))
        .collect::<Vec<_>>()
        .join(", ");
    format!(
        r#"
(function() {{
    if (window.__tabburritoLinkHandler) return;
    window.__tabburritoLinkHandler = true;
    const ALLOWED = new Set([{hosts_list}]);
    function hostAllowed(hostname) {{
        if (!hostname) return false;
        for (const allowed of ALLOWED) {{
            if (hostname === allowed || hostname.endsWith('.' + allowed)) return true;
        }}
        return false;
    }}
    function __tbDebugLog(_hypothesisId, _location, _message, _data) {{}}
    // Route File System Access saves through a normal <a download> so WebView2
    // fires DownloadStarting (which Tabburrito turns into a Save As dialog).
    try {{
        if (!window.__tbSavePickerPatched) {{
            window.__tbSavePickerPatched = true;
            const hadNative = typeof window.showSaveFilePicker === 'function';
            __tbDebugLog('B', 'bootstrap.js:showSaveFilePicker', 'installing download polyfill', {{
                hadNative: hadNative
            }});
            window.showSaveFilePicker = async function(options) {{
                const suggested = (options && options.suggestedName) || 'download';
                __tbDebugLog('B', 'bootstrap.js:showSaveFilePicker', 'polyfill showSaveFilePicker called', {{
                    suggestedName: suggested
                }});
                let chunks = [];
                return {{
                    kind: 'file',
                    name: suggested,
                    async getFile() {{
                        return new File(chunks, suggested);
                    }},
                    async createWritable() {{
                        return {{
                            async write(data) {{
                                if (data == null) return;
                                if (typeof data === 'object' && data.type === 'write') {{
                                    chunks.push(data.data);
                                }} else {{
                                    chunks.push(data);
                                }}
                            }},
                            async seek() {{}},
                            async truncate() {{}},
                            async abort() {{ chunks = []; }},
                            async close() {{
                                const blob = new Blob(chunks);
                                const objectUrl = URL.createObjectURL(blob);
                                const a = document.createElement('a');
                                a.href = objectUrl;
                                a.download = suggested;
                                a.style.display = 'none';
                                document.documentElement.appendChild(a);
                                a.click();
                                a.remove();
                                setTimeout(function() {{ URL.revokeObjectURL(objectUrl); }}, 60_000);
                                __tbDebugLog('B', 'bootstrap.js:showSaveFilePicker', 'polyfill triggered anchor download', {{
                                    suggestedName: suggested,
                                    size: blob.size
                                }});
                            }}
                        }};
                    }}
                }};
            }};
        }}
    }} catch (err) {{
        __tbDebugLog('B', 'bootstrap.js:showSaveFilePicker', 'showSaveFilePicker polyfill failed', {{
            error: String(err && (err.message || err))
        }});
    }}
    // #endregion
    document.addEventListener('click', function(e) {{
        // #region agent log
        try {{
            const t = e.target && (e.target.closest('[aria-label],button,a,[role="button"]') || e.target);
            const label = (t && (t.getAttribute('aria-label') || t.getAttribute('title') || t.textContent || '') || '').trim().slice(0, 80);
            if (/download|save|descargar|guardar|baixar|enregistrer/i.test(label)) {{
                __tbDebugLog('D', 'bootstrap.js:click', 'download-ish click', {{
                    label: label,
                    tag: t && t.tagName,
                    href: t && t.href || null
                }});
            }}
        }} catch (_) {{}}
        // #endregion
        if (e.defaultPrevented || e.button !== 0) return;
        if (e.ctrlKey || e.metaKey || e.shiftKey || e.altKey) return;
        const el = e.target.closest('a[href], [role="link"][href]');
        if (!el || !el.href) return;
        let url;
        try {{
            url = new URL(el.href);
        }} catch {{
            return;
        }}
        if (url.protocol === 'javascript:') return;
        if (url.protocol !== 'http:' && url.protocol !== 'https:') return;
        if (url.hash && el.getAttribute('href')?.startsWith('#')) return;
        if (hostAllowed(url.hostname)) return;
        // #region agent log
        __tbDebugLog('C', 'bootstrap.js:click', 'external link intercepted', {{
            href: url.href.slice(0, 200),
            downloadAttr: el.getAttribute('download')
        }});
        // #endregion
        e.preventDefault();
        e.stopImmediatePropagation();
        window.open(url.href, '_blank', 'noopener,noreferrer');
    }}, true);
}})();
"#
    )
}

struct AdblockState {
    enabled: Mutex<HashMap<String, bool>>,
}

impl AdblockState {
    fn new() -> Self {
        let mut map = HashMap::new();
        map.insert("linkedin".to_string(), true);
        Self {
            enabled: Mutex::new(map),
        }
    }

    fn is_enabled(&self, service_id: &str) -> bool {
        self.enabled
            .lock()
            .unwrap()
            .get(service_id)
            .copied()
            .unwrap_or(false)
    }

    fn set_enabled(&self, service_id: &str, enabled: bool) {
        self.enabled
            .lock()
            .unwrap()
            .insert(service_id.to_string(), enabled);
    }
}

struct MuteState {
    muted: Mutex<bool>,
}

impl MuteState {
    fn new() -> Self {
        Self {
            muted: Mutex::new(false),
        }
    }

    fn is_muted(&self) -> bool {
        *self.muted.lock().unwrap()
    }

    fn set_muted(&self, muted: bool) {
        *self.muted.lock().unwrap() = muted;
    }
}

struct LinkedInSortState {
    /// "recent" or "top"
    sort: Mutex<String>,
}

impl LinkedInSortState {
    fn new() -> Self {
        Self {
            sort: Mutex::new("recent".to_string()),
        }
    }

    fn get(&self) -> String {
        self.sort.lock().unwrap().clone()
    }

    fn set(&self, sort: &str) {
        let normalized = if sort.eq_ignore_ascii_case("top") {
            "top"
        } else {
            "recent"
        };
        *self.sort.lock().unwrap() = normalized.to_string();
    }
}

struct NotifyState {
    tracked: Mutex<HashMap<String, bool>>,
    counts: Mutex<HashMap<String, u32>>,
}

impl NotifyState {
    fn new() -> Self {
        let mut tracked = HashMap::new();
        tracked.insert("whatsapp".to_string(), true);
        tracked.insert("messenger".to_string(), true);
        Self {
            tracked: Mutex::new(tracked),
            counts: Mutex::new(HashMap::new()),
        }
    }

    fn is_tracked(&self, service_id: &str) -> bool {
        self.tracked
            .lock()
            .unwrap()
            .get(service_id)
            .copied()
            .unwrap_or(false)
    }

    fn set_tracked(&self, service_id: &str, enabled: bool) {
        self.tracked
            .lock()
            .unwrap()
            .insert(service_id.to_string(), enabled);
        if !enabled {
            self.counts.lock().unwrap().insert(service_id.to_string(), 0);
        }
    }

    fn set_count(&self, service_id: &str, count: u32) -> bool {
        let mut map = self.counts.lock().unwrap();
        let prev = map.get(service_id).copied().unwrap_or(0);
        map.insert(service_id.to_string(), count);
        prev != count
    }

    fn tracked_snapshot(&self) -> HashMap<String, bool> {
        self.tracked.lock().unwrap().clone()
    }

    fn replace_tracked(&self, tracked: HashMap<String, bool>) {
        *self.tracked.lock().unwrap() = tracked;
    }
}

struct AppPrefsState {
    unload_secs: Mutex<u64>,
}

impl AppPrefsState {
    fn new() -> Self {
        Self {
            unload_secs: Mutex::new(DEFAULT_COLD_UNLOAD_SECS),
        }
    }

    fn get_unload_secs(&self) -> u64 {
        let secs = *self.unload_secs.lock().unwrap();
        secs.clamp(30, 3600)
    }

    fn set_unload_secs(&self, secs: u64) {
        *self.unload_secs.lock().unwrap() = secs.clamp(30, 3600);
    }
}

struct ServiceUrlState {
    urls: Mutex<HashMap<String, String>>,
}

impl ServiceUrlState {
    fn new() -> Self {
        Self {
            urls: Mutex::new(HashMap::new()),
        }
    }

    fn set_url(&self, service_id: &str, url: &str) {
        self.urls
            .lock()
            .unwrap()
            .insert(service_id.to_string(), url.to_string());
    }

    fn get_url(&self, service_id: &str) -> Option<String> {
        self.urls.lock().unwrap().get(service_id).cloned()
    }

    fn snapshot(&self) -> HashMap<String, String> {
        self.urls.lock().unwrap().clone()
    }

    fn replace(&self, urls: HashMap<String, String>) {
        *self.urls.lock().unwrap() = urls;
    }
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct UnreadPayload {
    service_id: String,
    count: u32,
}

#[derive(Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct ActiveServicePayload {
    service_id: String,
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct PortableStatePayload {
    unload_seconds: u64,
    service_urls: HashMap<String, String>,
    linkedin_sort: String,
    notify_tracked: HashMap<String, bool>,
}

fn parse_tb_unread_marker(title: &str) -> Option<u32> {
    // Title encodes: …\u{2063}TB123\u{2063}
    let marker = '\u{2063}';
    let mut search = title;
    while let Some(start) = search.find(marker) {
        let after_marker = &search[start + marker.len_utf8()..];
        if let Some(rest) = after_marker.strip_prefix("TB") {
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if !digits.is_empty() {
                let after_digits = &rest[digits.len()..];
                if after_digits.starts_with(marker) {
                    return digits.parse().ok();
                }
            }
        }
        search = &search[start + marker.len_utf8()..];
    }
    None
}

fn apply_mute_to_webview(webview: &tauri::Webview, muted: bool) {
    let muted = muted;
    let _ = webview.with_webview(move |platform| {
        #[cfg(windows)]
        unsafe {
            use webview2_com::Microsoft::Web::WebView2::Win32::ICoreWebView2_8;
            use windows::core::Interface;
            if let Ok(core) = platform.controller().CoreWebView2() {
                if let Ok(core8) = core.cast::<ICoreWebView2_8>() {
                    let _ = core8.SetIsMuted(muted);
                }
            }
        }
        #[cfg(not(windows))]
        {
            let _ = (platform, muted);
        }
    });
}

fn apply_mute_to_all_services(app: &tauri::AppHandle, muted: bool) {
    for svc in SERVICES {
        if let Some(wv) = app.get_webview(svc.id) {
            apply_mute_to_webview(&wv, muted);
        }
    }
}

fn service_should_keep_loaded(app: &tauri::AppHandle, svc: &Service) -> bool {
    if svc.keep_loaded {
        return true;
    }
    // Keep notify-tracked messaging tabs hot so unread polling stays alive.
    if (svc.id == "whatsapp" || svc.id == "messenger")
        && app.state::<NotifyState>().is_tracked(svc.id)
    {
        return true;
    }
    false
}

fn emit_unread(app: &tauri::AppHandle, service_id: &str, count: u32) {
    let _ = app.emit(
        "tb-unread",
        UnreadPayload {
            service_id: service_id.to_string(),
            count,
        },
    );
}

fn update_tray_unread_tooltip(app: &tauri::AppHandle) {
    let notify = app.state::<NotifyState>();
    let counts = notify.counts.lock().unwrap();
    let total: u32 = counts.values().copied().sum();
    let tooltip = if total > 0 {
        format!("Tabburrito - {total} unread DM")
    } else {
        "Tabburrito".to_string()
    };
    if let Some(tray) = app.tray_by_id("main-tray") {
        let _ = tray.set_tooltip(Some(tooltip));
    }
}

fn emit_active_service(app: &tauri::AppHandle, service_id: &str) {
    let _ = app.emit(
        "tb-active-service",
        ActiveServicePayload {
            service_id: service_id.to_string(),
        },
    );
}

fn current_unload_after(app: &tauri::AppHandle) -> Duration {
    Duration::from_secs(app.state::<AppPrefsState>().get_unload_secs())
}

fn resolve_service_url(app: &tauri::AppHandle, svc: &Service) -> Result<url::Url, String> {
    if let Some(saved) = app.state::<ServiceUrlState>().get_url(svc.id) {
        return saved.parse().map_err(|e: url::ParseError| e.to_string());
    }
    svc.url.parse().map_err(|e: url::ParseError| e.to_string())
}

fn set_service_url_override(app: &tauri::AppHandle, service_id: &str, url: &str) {
    app.state::<ServiceUrlState>().set_url(service_id, url);
}

fn handle_service_title_changed(app: &tauri::AppHandle, service_id: &str, title: String) {
    let notify = app.state::<NotifyState>();
    if !notify.is_tracked(service_id) {
        return;
    }
    let Some(count) = parse_tb_unread_marker(&title) else {
        return;
    };
    if notify.set_count(service_id, count) {
        emit_unread(app, service_id, count);
        update_tray_unread_tooltip(app);
    }
}

fn linkedin_feed_sort_eval_js(sort: &str) -> String {
    let sort = if sort.eq_ignore_ascii_case("top") {
        "top"
    } else {
        "recent"
    };
    let mut js = String::with_capacity(LINKEDIN_FEED_SORT_JS.len() + 64);
    js.push_str("window.__tbLinkedInSort = '");
    js.push_str(sort);
    js.push_str("';\n");
    js.push_str(LINKEDIN_FEED_SORT_JS);
    js
}

fn apply_linkedin_sort_to_webview(app: &tauri::AppHandle) {
    let sort = app.state::<LinkedInSortState>().get();
    if let Some(wv) = app.get_webview("linkedin") {
        // Prefer in-page apply helper if already injected; otherwise inject full script.
        // Build via push_str so JS braces are not interpreted by format!.
        let mut js = String::with_capacity(LINKEDIN_FEED_SORT_JS.len() + 160);
        js.push_str("window.__tbLinkedInSort = '");
        js.push_str(&sort);
        js.push_str("';\n");
        js.push_str("if (typeof window.__tbApplyLinkedInSort === 'function') {");
        js.push_str(" window.__tbApplyLinkedInSort(window.__tbLinkedInSort);");
        js.push_str(" } else {\n");
        js.push_str(LINKEDIN_FEED_SORT_JS);
        js.push_str("\n}");
        let _ = wv.eval(js);
    }
}

struct WebviewState {
    loaded: Mutex<HashMap<String, bool>>,
    hidden_at: Mutex<HashMap<String, Instant>>,
}

impl WebviewState {
    fn new() -> Self {
        Self {
            loaded: Mutex::new(HashMap::new()),
            hidden_at: Mutex::new(HashMap::new()),
        }
    }

    fn is_loaded(&self, service_id: &str) -> bool {
        self.loaded
            .lock()
            .unwrap()
            .get(service_id)
            .copied()
            .unwrap_or(false)
    }

    fn set_loaded(&self, service_id: &str, loaded: bool) {
        self.loaded
            .lock()
            .unwrap()
            .insert(service_id.to_string(), loaded);
    }

    fn mark_hidden(&self, service_id: &str) {
        self.hidden_at
            .lock()
            .unwrap()
            .entry(service_id.to_string())
            .or_insert_with(Instant::now);
    }

    fn mark_visible(&self, service_id: &str) {
        self.hidden_at.lock().unwrap().remove(service_id);
    }

    fn hidden_for(&self, service_id: &str) -> Option<Duration> {
        self.hidden_at
            .lock()
            .unwrap()
            .get(service_id)
            .map(|instant| instant.elapsed())
    }
}

fn service_by_id(id: &str) -> Option<&'static Service> {
    SERVICES.iter().find(|svc| svc.id == id)
}

fn host_matches(host: &str, allowed_host: &str) -> bool {
    host == allowed_host || host.ends_with(&format!(".{allowed_host}"))
}

fn linkedin_safety_destination(url: &url::Url) -> Option<String> {
    if host_matches(url.host_str().unwrap_or_default(), "linkedin.com")
        && url.path().trim_end_matches('/') == "/safety/go"
    {
        return url
            .query_pairs()
            .find(|(key, value)| key == "url" && !value.is_empty())
            .map(|(_, destination)| destination.into_owned());
    }

    None
}

fn facebook_redirect_destination(url: &url::Url) -> Option<String> {
    if host_matches(url.host_str().unwrap_or_default(), "facebook.com")
        && url.path().trim_end_matches('/') == "/l.php"
    {
        return url
            .query_pairs()
            .find(|(key, value)| key == "u" && !value.is_empty())
            .map(|(_, destination)| destination.into_owned());
    }

    None
}

fn whatsapp_link_destination(url: &url::Url) -> Option<String> {
    if !host_matches(url.host_str().unwrap_or_default(), "whatsapp.com") {
        return None;
    }

    let path = url.path();
    if path.contains("/secure/link") || path.trim_end_matches('/') == "/link" {
        return url
            .query_pairs()
            .find(|(key, value)| (key == "url" || key == "link") && !value.is_empty())
            .map(|(_, destination)| destination.into_owned());
    }

    None
}

fn redirect_wrapper_destination(url: &url::Url) -> Option<String> {
    linkedin_safety_destination(url)
        .or_else(|| facebook_redirect_destination(url))
        .or_else(|| whatsapp_link_destination(url))
}

fn normalize_external_url(url: &url::Url) -> String {
    if let Some(destination) = redirect_wrapper_destination(url) {
        return destination;
    }

    url.as_str().to_string()
}

fn open_external_url(url: &url::Url) {
    let target = normalize_external_url(url);
    #[cfg(target_os = "windows")]
    {
        let _spawn_result = std::process::Command::new("rundll32")
            .args(["url.dll,FileProtocolHandler", target.as_str()])
            .spawn();
        #[cfg(debug_assertions)]
        if let Err(err) = _spawn_result {
            eprintln!("[Tabburrito] failed to open external URL: {err}");
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let opener = if cfg!(target_os = "macos") {
            "open"
        } else {
            "xdg-open"
        };
        let _ = std::process::Command::new(opener).arg(target).spawn();
    }
}

enum NavigationDecision {
    AllowInWebview,
    DenySilently,
    OpenExternal,
}

fn navigation_decision(service: &Service, url: &url::Url) -> NavigationDecision {
    if url.scheme() == "javascript" {
        return NavigationDecision::DenySilently;
    }

    if matches!(
        url.scheme(),
        "mailto" | "tel" | "sms" | "whatsapp" | "geo"
    ) {
        return NavigationDecision::OpenExternal;
    }

    if redirect_wrapper_destination(url).is_some() {
        return NavigationDecision::OpenExternal;
    }

    match url.scheme() {
        "http" | "https" => {
            let Some(host) = url.host_str() else {
                return NavigationDecision::AllowInWebview;
            };

            if service
                .internal_hosts
                .iter()
                .any(|allowed_host| host_matches(host, allowed_host))
            {
                NavigationDecision::AllowInWebview
            } else {
                NavigationDecision::OpenExternal
            }
        }
        "about" | "data" | "blob" | "devtools" => NavigationDecision::AllowInWebview,
        _ => NavigationDecision::OpenExternal,
    }
}

fn should_open_in_service(service: &Service, url: &url::Url) -> bool {
    matches!(
        navigation_decision(service, url),
        NavigationDecision::AllowInWebview
    )
}

fn handle_navigation(service: &Service, url: &url::Url) -> bool {
    match navigation_decision(service, url) {
        NavigationDecision::AllowInWebview => true,
        NavigationDecision::DenySilently => false,
        NavigationDecision::OpenExternal => {
            open_external_url(url);
            false
        }
    }
}

fn service_bounds(window: &tauri::Window) -> (LogicalPosition<f64>, LogicalSize<f64>) {
    let scale = window.scale_factor().unwrap_or(1.0);
    let win_size = window
        .inner_size()
        .unwrap_or(tauri::PhysicalSize::new(1920, 1080));
    let (w, h) = (
        win_size.width as f64 / scale,
        win_size.height as f64 / scale,
    );
    let content_w = w - SIDEBAR_W;
    (
        LogicalPosition::new(SIDEBAR_W, URLBAR_H),
        LogicalSize::new(content_w, h - URLBAR_H),
    )
}

fn create_service_webview(app: &tauri::AppHandle, service: &'static Service) -> Result<(), String> {
    if app.get_webview(service.id).is_some() {
        return Ok(());
    }
    let window = app
        .get_window("main")
        .ok_or_else(|| "main window not found".to_string())?;
    let (position, size) = service_bounds(&window);
    let url: url::Url = service
        .url
        .parse()
        .map_err(|e: url::ParseError| e.to_string())?;

    let navigation_service_nav = service;
    let navigation_service_window = service;
    let app_handle_for_window = app.clone();
    let service_id = service.id.to_string();
    let link_script = external_link_bootstrap_js(service.internal_hosts);
    let download_service_id = service.id.to_string();
    let mut init_scripts = link_script;
    if service.id == "whatsapp" || service.id == "messenger" {
        init_scripts.push('\n');
        init_scripts.push_str(UNREAD_BOOTSTRAP_JS);
    }
    let mut builder = WebviewBuilder::new(service.id, WebviewUrl::External(url))
        .user_agent(CHROME_UA)
        .data_directory(webview_data_dir())
        .auto_resize()
        .zoom_hotkeys_enabled(true)
        .initialization_script_for_all_frames(init_scripts)
        .on_download(move |_webview, event| {
            match event {
                DownloadEvent::Requested { url, destination } => {
                    // #region agent log
                    agent_debug_log(
                        "A",
                        "main.rs:on_download",
                        "download requested",
                        serde_json::json!({
                            "service": download_service_id.as_str(),
                            "url": url.as_str(),
                            "destination": destination.display().to_string(),
                            "fileName": destination.file_name().and_then(|s| s.to_str()).unwrap_or(""),
                        }),
                    );
                    // #endregion

                    let suggested_name = destination
                        .file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or("download")
                        .to_string();

                    let initial_dir = destination.parent().filter(|p| p.exists());
                    match show_save_file_dialog(&suggested_name, initial_dir) {
                        Some(path) => {
                            // #region agent log
                            agent_debug_log(
                                "A",
                                "main.rs:on_download",
                                "save dialog accepted",
                                serde_json::json!({
                                    "service": download_service_id.as_str(),
                                    "path": path.display().to_string(),
                                }),
                            );
                            // #endregion
                            *destination = path;
                            true
                        }
                        None => {
                            // #region agent log
                            agent_debug_log(
                                "A",
                                "main.rs:on_download",
                                "save dialog cancelled",
                                serde_json::json!({
                                    "service": download_service_id.as_str(),
                                    "url": url.as_str(),
                                }),
                            );
                            // #endregion
                            false
                        }
                    }
                }
                DownloadEvent::Finished { url, path, success } => {
                    // #region agent log
                    agent_debug_log(
                        "A",
                        "main.rs:on_download",
                        "download finished",
                        serde_json::json!({
                            "service": download_service_id.as_str(),
                            "url": url.as_str(),
                            "path": path.as_ref().map(|p| p.display().to_string()),
                            "success": success,
                        }),
                    );
                    // #endregion
                    true
                }
                _ => true,
            }
        })
        .on_navigation(move |url| {
            // #region agent log
            let host = url.host_str().unwrap_or("");
            let path = url.path();
            if path.contains("download")
                || host.contains("mmg")
                || host.contains("media")
                || url.scheme() == "blob"
            {
                let decision = match navigation_decision(navigation_service_nav, &url) {
                    NavigationDecision::AllowInWebview => "allow",
                    NavigationDecision::DenySilently => "deny",
                    NavigationDecision::OpenExternal => "external",
                };
                agent_debug_log(
                    "E",
                    "main.rs:on_navigation",
                    "nav candidate for download",
                    serde_json::json!({
                        "service": navigation_service_nav.id,
                        "url": url.as_str(),
                        "decision": decision,
                    }),
                );
            }
            // #endregion
            handle_navigation(navigation_service_nav, &url)
        })
        .on_new_window(move |url, features| {
            // A genuine popup (OAuth, share dialog, etc.) carries an explicit
            // size from window.open(). Middle-click, ctrl-click, right-click
            // "open in new tab", and plain target="_blank" links do not — those
            // are real new-tab intents, and the user wants them in the browser
            // rather than navigating this webview away from the current page.
            let is_popup = features.size().is_some();
            if is_popup && should_open_in_service(navigation_service_window, &url) {
                if let Some(wv) = app_handle_for_window.get_webview(service_id.as_str()) {
                    let _ = wv.navigate(url);
                }
            } else {
                open_external_url(&url);
            }
            NewWindowResponse::Deny
        });

    if service.id == "whatsapp" || service.id == "messenger" {
        let app_for_title = app.clone();
        let title_svc_id = service.id.to_string();
        builder = builder.on_document_title_changed(move |_webview, title| {
            handle_service_title_changed(&app_for_title, &title_svc_id, title);
        });
    }

    if service.id == "linkedin" {
        let adblock_script = LINKEDIN_ADBLOCK_JS.to_string();
        let app_handle_for_page = app.clone();
        let svc_id = service.id.to_string();
        builder = builder.on_page_load(move |webview, payload| {
            if payload.event() == PageLoadEvent::Finished {
                let adblock = app_handle_for_page.state::<AdblockState>();
                if adblock.is_enabled(&svc_id) {
                    let _ = webview.eval(&adblock_script);
                }
                let sort = app_handle_for_page.state::<LinkedInSortState>().get();
                let _ = webview.eval(linkedin_feed_sort_eval_js(&sort));
            }
        });
    }

    let wv = window
        .add_child(builder, position, size)
        .map_err(|e| e.to_string())?;
    wv.hide().map_err(|e| e.to_string())?;
    app.state::<WebviewState>().set_loaded(service.id, true);
    app.state::<WebviewState>().mark_hidden(service.id);
    apply_mute_to_webview(&wv, app.state::<MuteState>().is_muted());
    Ok(())
}

#[tauri::command]
async fn show_service(app: tauri::AppHandle, label: String) -> Result<(), String> {
    let state = app.state::<WebviewState>();
    if let Some(service) = service_by_id(&label) {
        create_service_webview(&app, service)?;
    }
    for svc in SERVICES {
        if let Some(wv) = app.get_webview(svc.id) {
            if svc.id == label.as_str() {
                state.mark_visible(svc.id);
                wv.show().map_err(|e| e.to_string())?;
                wv.set_focus().map_err(|e| e.to_string())?;
                if !state.is_loaded(svc.id) {
                    let url = resolve_service_url(&app, svc)?;
                    wv.navigate(url).map_err(|e| e.to_string())?;
                    state.set_loaded(svc.id, true);
                }
            } else {
                let _ = wv.hide();
                if service_should_keep_loaded(&app, svc) {
                    state.mark_visible(svc.id);
                } else {
                    let hidden_for = state.hidden_for(svc.id);
                    state.mark_hidden(svc.id);
                    if state.is_loaded(svc.id)
                        && hidden_for.is_some_and(|elapsed| elapsed >= current_unload_after(&app))
                    {
                        let blank: url::Url = "about:blank"
                            .parse()
                            .map_err(|e: url::ParseError| e.to_string())?;
                        let _ = wv.navigate(blank);
                        state.set_loaded(svc.id, false);
                    }
                }
            }
        }
    }
    emit_active_service(&app, &label);
    Ok(())
}

#[tauri::command]
async fn refresh_service(app: tauri::AppHandle, label: String) -> Result<(), String> {
    if let Some(svc) = SERVICES.iter().find(|s| s.id == label.as_str()) {
        create_service_webview(&app, svc)?;
        if let Some(wv) = app.get_webview(svc.id) {
            let url = resolve_service_url(&app, svc)?;
            wv.navigate(url).map_err(|e| e.to_string())?;
            app.state::<WebviewState>().set_loaded(svc.id, true);
        }
    }
    Ok(())
}

#[tauri::command]
async fn navigate_service(app: tauri::AppHandle, label: String, url: String) -> Result<(), String> {
    let service = service_by_id(&label);
    if let Some(svc) = service {
        create_service_webview(&app, svc)?;
    }
    if let Some(wv) = app.get_webview(&label) {
        let parsed: url::Url = url.parse().map_err(|e: url::ParseError| e.to_string())?;
        if parsed.as_str() == "about:blank" {
            wv.navigate(parsed).map_err(|e| e.to_string())?;
            app.state::<WebviewState>().set_loaded(&label, false);
            return Ok(());
        }
        if let Some(svc) = service {
            if should_open_in_service(svc, &parsed) {
                set_service_url_override(&app, &label, parsed.as_str());
                wv.navigate(parsed).map_err(|e| e.to_string())?;
                app.state::<WebviewState>().set_loaded(&label, true);
            } else {
                open_external_url(&parsed);
            }
        } else {
            wv.navigate(parsed).map_err(|e| e.to_string())?;
            app.state::<WebviewState>().set_loaded(&label, true);
        }
    }
    Ok(())
}

#[tauri::command]
async fn zoom_service(app: tauri::AppHandle, label: String, zoom: f64) -> Result<(), String> {
    if let Some(svc) = service_by_id(&label) {
        create_service_webview(&app, svc)?;
    }
    if let Some(wv) = app.get_webview(&label) {
        wv.set_zoom(zoom).map_err(|e| e.to_string())?;
    }
    Ok(())
}

#[tauri::command]
async fn reload_service(app: tauri::AppHandle, label: String) -> Result<(), String> {
    if let Some(svc) = service_by_id(&label) {
        create_service_webview(&app, svc)?;
        if let Some(wv) = app.get_webview(&label) {
            let url = resolve_service_url(&app, svc)?;
            wv.navigate(url).map_err(|e| e.to_string())?;
            app.state::<WebviewState>().set_loaded(svc.id, true);
        }
    }
    Ok(())
}

#[tauri::command]
async fn set_adblock_service(
    app: tauri::AppHandle,
    service_id: String,
    enabled: bool,
) -> Result<(), String> {
    let state = app.state::<AdblockState>();
    state.set_enabled(&service_id, enabled);
    Ok(())
}

#[tauri::command]
async fn set_muted(app: tauri::AppHandle, muted: bool) -> Result<(), String> {
    app.state::<MuteState>().set_muted(muted);
    apply_mute_to_all_services(&app, muted);
    Ok(())
}

#[tauri::command]
async fn set_linkedin_feed_sort(app: tauri::AppHandle, sort: String) -> Result<(), String> {
    app.state::<LinkedInSortState>().set(&sort);
    apply_linkedin_sort_to_webview(&app);
    Ok(())
}

#[tauri::command]
async fn set_unload_seconds(app: tauri::AppHandle, seconds: u64) -> Result<(), String> {
    app.state::<AppPrefsState>().set_unload_secs(seconds);
    Ok(())
}

#[tauri::command]
async fn set_service_url(app: tauri::AppHandle, service_id: String, url: String) -> Result<(), String> {
    if service_by_id(&service_id).is_none() {
        return Err("unknown service id".to_string());
    }
    let parsed: url::Url = url.parse().map_err(|e: url::ParseError| e.to_string())?;
    if let Some(svc) = service_by_id(&service_id) {
        if !should_open_in_service(svc, &parsed) {
            return Err("service URL must be internal to that service".to_string());
        }
    }
    set_service_url_override(&app, &service_id, parsed.as_str());
    Ok(())
}

#[tauri::command]
async fn backup_portable_state(app: tauri::AppHandle) -> Result<String, String> {
    let payload = PortableStatePayload {
        unload_seconds: app.state::<AppPrefsState>().get_unload_secs(),
        service_urls: app.state::<ServiceUrlState>().snapshot(),
        linkedin_sort: app.state::<LinkedInSortState>().get(),
        notify_tracked: app.state::<NotifyState>().tracked_snapshot(),
    };
    serde_json::to_string_pretty(&payload).map_err(|e| e.to_string())
}

#[tauri::command]
async fn restore_portable_state(app: tauri::AppHandle, payload: String) -> Result<(), String> {
    let parsed: PortableStatePayload = serde_json::from_str(&payload).map_err(|e| e.to_string())?;
    app.state::<AppPrefsState>().set_unload_secs(parsed.unload_seconds);
    app.state::<ServiceUrlState>().replace(parsed.service_urls);
    app.state::<LinkedInSortState>().set(&parsed.linkedin_sort);
    app.state::<NotifyState>().replace_tracked(parsed.notify_tracked.clone());
    for (service_id, enabled) in parsed.notify_tracked {
        if !enabled {
            emit_unread(&app, &service_id, 0);
        }
    }
    apply_linkedin_sort_to_webview(&app);
    Ok(())
}

#[tauri::command]
async fn set_notify_service(
    app: tauri::AppHandle,
    service_id: String,
    enabled: bool,
) -> Result<(), String> {
    let notify = app.state::<NotifyState>();
    notify.set_tracked(&service_id, enabled);
    if !enabled {
        emit_unread(&app, &service_id, 0);
    } else if let Some(svc) = service_by_id(&service_id) {
        // Ensure tracked messaging services exist and stay warm for polling.
        if svc.id == "whatsapp" || svc.id == "messenger" {
            create_service_webview(&app, svc)?;
            if let Some(wv) = app.get_webview(svc.id) {
                if !app.state::<WebviewState>().is_loaded(svc.id) {
                    let url: url::Url = svc
                        .url
                        .parse()
                        .map_err(|e: url::ParseError| e.to_string())?;
                    wv.navigate(url).map_err(|e| e.to_string())?;
                    app.state::<WebviewState>().set_loaded(svc.id, true);
                }
            }
        }
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
        .plugin(tauri_plugin_autostart::init(
            MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(AdblockState::new())
        .manage(WebviewState::new())
        .manage(MuteState::new())
        .manage(LinkedInSortState::new())
        .manage(NotifyState::new())
        .manage(AppPrefsState::new())
        .manage(ServiceUrlState::new())
        .invoke_handler(tauri::generate_handler![
            show_service,
            refresh_service,
            navigate_service,
            zoom_service,
            reload_service,
            set_adblock_service,
            set_muted,
            set_linkedin_feed_sort,
            set_unload_seconds,
            set_service_url,
            backup_portable_state,
            restore_portable_state,
            set_notify_service,
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

            // Use the actual window inner size (client area) for sizing
            // This prevents the webview from hiding behind the taskbar when maximized
            let scale = window.scale_factor().unwrap_or(1.0);
            let win_size = window
                .inner_size()
                .unwrap_or(tauri::PhysicalSize::new(1920, 1080));
            let (w, h) = (
                win_size.width as f64 / scale,
                win_size.height as f64 / scale,
            );
            let content_w = w - SIDEBAR_W;

            // Sidebar
            window.add_child(
                WebviewBuilder::new("sidebar", WebviewUrl::App("index.html".into()))
                    .data_directory(shell_webview_data_dir())
                    .auto_resize(),
                LogicalPosition::new(0.0, 0.0),
                LogicalSize::new(SIDEBAR_W, h),
            )?;

            // Service webviews — offset by URL bar height
            // Preload WhatsApp + Messenger (notify-tracked by default) so DM badges work.
            create_service_webview(&app.handle().clone(), &SERVICES[0])
                .map_err(tauri::Error::AssetNotFound)?;
            create_service_webview(&app.handle().clone(), &SERVICES[1])
                .map_err(tauri::Error::AssetNotFound)?;

            // URL bar webview (between sidebar and content)
            window.add_child(
                WebviewBuilder::new("urlbar", WebviewUrl::App("urlbar.html".into()))
                    .data_directory(shell_webview_data_dir())
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
