// Tabburrito Lite — Firefox profile optimizations
// Based on official Mozilla prefs, no third-party patches.
// Goal: minimum memory, maximum speed, disable all bloat.

// ============================================================
// PERFORMANCE — Memory and process optimization
// ============================================================
// Limit content processes (default 8 = 8 renderer processes)
// 2 is enough for 5 tabs — each process handles 2-3 tabs
user_pref("dom.ipc.processCount", 2);

// Disable separate privileged content process (merges into regular)
user_pref("browser.tabs.remote.separatePrivilegedContentProcess", false);

// Limit isolated web content processes
user_pref("fission.webContentIsolationStrategy", 0);
user_pref("dom.ipc.processCount.webIsolated", 1);

// Unload tabs when memory is low
user_pref("browser.tabs.unloadOnLowMemory", true);
user_pref("browser.tabs.min_inactive_duration_before_unload", 600000);

// WebRender yes, but GPU process in-process (saves 200-500MB separate process)
user_pref("gfx.webrender.all", true);
user_pref("layers.gpu-process.enabled", false);

// Disable Fission (site isolation) — saves 1 process per unique domain
user_pref("fission.autostart", false);

// Reduce session history (back/forward cache per tab)
user_pref("browser.sessionhistory.max_entries", 10);

// Cap in-memory cache at 128MB (default unlimited)
user_pref("browser.cache.memory.capacity", 131072);
user_pref("browser.cache.disk.enable", false);

// Disable speculative pre-connections and prefetching
user_pref("network.http.speculative-parallel-limit", 0);
user_pref("network.prefetch-next", false);
user_pref("network.dns.disablePrefetch", true);
user_pref("network.predictor.enabled", false);

// Faster rendering — reduce reflow timer
user_pref("content.notify.interval", 100000);

// ============================================================
// DISABLE BLOAT — Telemetry, Pocket, Crash Reporter, etc.
// ============================================================
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("toolkit.telemetry.archive.enabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("browser.ping-centre.telemetry", false);
user_pref("browser.newtabpage.activity-stream.feeds.telemetry", false);
user_pref("browser.newtabpage.activity-stream.telemetry", false);

// Disable Pocket
user_pref("extensions.pocket.enabled", false);

// Disable crash reporter
user_pref("breakpad.reportURL", "");
user_pref("browser.tabs.crashReporting.sendReport", false);
user_pref("browser.crashReports.unsubmittedCheck.autoSubmit2", false);

// Disable default browser check
user_pref("browser.shell.checkDefaultBrowser", false);

// Disable "What's New" page
user_pref("browser.startup.homepage_override.mstone", "ignore");

// Disable Firefox accounts / sync prompts
user_pref("identity.fxaccounts.enabled", false);

// Disable normandy (Mozilla remote experiment system)
user_pref("app.normandy.enabled", false);
user_pref("app.normandy.api_url", "");

// Disable studies
user_pref("app.shield.optoutstudies.enabled", false);

// Disable recommendation pane in about:addons
user_pref("extensions.getAddons.showPane", false);
user_pref("extensions.htmlaboutaddons.recommendations.enabled", false);

// Disable auto-update (we manage the profile, not Firefox updates)
user_pref("app.update.enabled", false);

// ============================================================
// UI — Minimal chrome, dark mode
// ============================================================
// Let Tabburrito control startup tabs explicitly.
user_pref("browser.startup.page", 1);
user_pref("browser.sessionstore.restore_on_demand", false);
user_pref("browser.sessionstore.restore_tabs_lazily", false);
user_pref("browser.sessionstore.max_tabs_undo", 3);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("browser.shell.didSkipDefaultBrowserCheckOnFirstRun", true);
user_pref("trailhead.firstrun.didSeeAboutWelcome", true);

// Dark theme
user_pref("ui.systemUsesDarkTheme", 1);
user_pref("browser.theme.content-theme", 0);
user_pref("browser.theme.toolbar-theme", 0);

// Compact density
user_pref("browser.compactmode.show", true);
user_pref("browser.uidensity", 1);

// Disable animations for speed
user_pref("ui.prefersReducedMotion", 1);
user_pref("toolkit.cosmeticAnimations.enabled", false);
user_pref("browser.tabs.animate", false);
user_pref("browser.fullscreen.animate", false);

// ============================================================
// PRIVACY — Reasonable defaults (not paranoid)
// ============================================================
// Enable tracking protection
user_pref("privacy.trackingprotection.enabled", true);
user_pref("privacy.trackingprotection.socialtracking.enabled", true);

// Disable third-party cookies (helps with ads)
user_pref("network.cookie.cookieBehavior", 5);

// ============================================================
// SPELLCHECK — English + Hebrew
// ============================================================
user_pref("layout.spellcheckDefault", 2);
user_pref("spellchecker.dictionary", "en-US,he");

// ============================================================
// WEBVIEW-LIKE BEHAVIOR
// ============================================================
// Don't warn on close with multiple tabs
user_pref("browser.tabs.warnOnClose", false);
user_pref("browser.tabs.warnOnCloseOtherTabs", false);

// Don't show download panel automatically
user_pref("browser.download.alwaysOpenPanel", false);

// Disable "Ctrl+Q to quit" warning
user_pref("browser.warnOnQuit", false);

// Allow autoplay (needed for WhatsApp notifications)
user_pref("media.autoplay.default", 0);
