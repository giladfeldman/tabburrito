// WindowsTuneUp — Firefox memory tuning for daily-driver profiles
// Installed beside prefs.js; remove this file to revert.
// Restart Firefox after install.

// ============================================================
// TAB & SESSION — load less, release more
// ============================================================
user_pref("browser.sessionstore.restore_on_demand", true);
user_pref("browser.sessionstore.restore_tabs_lazily", true);
user_pref("browser.sessionstore.max_tabs_undo", 5);

// Unload background tabs when system memory is tight
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("browser.tabs.min_inactive_duration_before_unload", 600000);

// Smaller back/forward cache per tab
user_pref("browser.sessionhistory.max_entries", 10);

// ============================================================
// PROCESS & CACHE — fewer idle processes, bounded RAM cache
// ============================================================
// 20 tabs across 6 windows: 2 content processes is enough
user_pref("dom.ipc.processCount", 2);
user_pref("dom.ipc.processCount.webIsolated", 1);
user_pref("browser.tabs.remote.separatePrivilegedContentProcess", false);

// Keep Fission ON for Facebook Container / site isolation security
// user_pref("fission.autostart", false);

user_pref("browser.cache.memory.capacity", 65536);

// GPU compositor in-process (avoids a separate ~200–500 MB process)
user_pref("gfx.webrender.all", true);
user_pref("layers.gpu-process.enabled", false);

// ============================================================
// NETWORK — stop speculative work on background tabs
// ============================================================
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.prefetch-next", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.predictor.enabled", false);
