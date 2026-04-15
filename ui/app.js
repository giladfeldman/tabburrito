// Tabburrito sidebar

const SERVICES = [
  { id: 'whatsapp', name: 'WhatsApp', icon: '\u{1F4AC}' },
  { id: 'messenger', name: 'Messenger', icon: '\u{1F535}' },
  { id: 'linkedin', name: 'LinkedIn', icon: '\u{1F517}' },
  { id: 'bluesky', name: 'Bluesky', icon: '\u{1F98B}' },
  { id: 'calendar', name: 'Google Calendar', icon: '\u{1F4C5}' },
];

let activeService = null;
let isMuted = false;
let isDark = true;
let notifyServices = ['whatsapp', 'messenger']; // default
let lastNotifState = false;

function loadState() {
  try {
    const s = JSON.parse(localStorage.getItem('tabburrito') || '{}');
    isMuted = s.muted || false;
    isDark = s.dark !== undefined ? s.dark : true;
    activeService = s.active || null;
    if (s.notifyServices) notifyServices = s.notifyServices;
  } catch {}
}

function saveState() {
  localStorage.setItem('tabburrito', JSON.stringify({
    muted: isMuted, dark: isDark, active: activeService,
    notifyServices: notifyServices,
  }));
}

function buildSidebar() {
  const c = document.getElementById('service-icons');
  SERVICES.forEach((svc) => {
    const btn = document.createElement('button');
    btn.className = 'service-icon';
    btn.title = svc.name;
    btn.dataset.id = svc.id;

    // Notification dot + icon
    btn.innerHTML = `<span class="svc-emoji">${svc.icon}</span><span class="notif-dot"></span>`;
    btn.addEventListener('click', () => showService(svc.id));

    // Right-click to toggle notification tracking
    btn.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      toggleNotifyService(svc.id);
    });

    c.appendChild(btn);
  });
}

function toggleNotifyService(id) {
  const idx = notifyServices.indexOf(id);
  if (idx >= 0) {
    notifyServices.splice(idx, 1);
  } else {
    notifyServices.push(id);
  }
  saveState();
  updateNotifyIndicators();

  // Sync to Rust
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('set_notify_service', {
      serviceId: id,
      enabled: notifyServices.includes(id),
    }).catch(() => {});
  }
}

function updateNotifyIndicators() {
  SERVICES.forEach(svc => {
    const btn = document.querySelector(`.service-icon[data-id="${svc.id}"]`);
    if (!btn) return;
    const dot = btn.querySelector('.notif-dot');
    const isTracked = notifyServices.includes(svc.id);

    // Show a subtle ring on tracked services
    btn.classList.toggle('notify-tracked', isTracked);

    // The dot itself is shown when there's an unread count
    // We'll update this in the polling function
  });
}

// Poll service webview titles to detect notification counts
// WhatsApp: "(3) WhatsApp" / Messenger: "Messenger (2)"
async function pollNotifications() {
  if (!window.__TAURI__) return;

  let anyNotif = false;

  for (const svcId of notifyServices) {
    // We can't read child webview titles directly from the sidebar webview.
    // Instead, inject JS into each tracked service webview to check document.title
    // For now, we use a simpler approach: check via the Rust side
    // The title change detection happens via page_title observers in WebView2
  }

  // For MVP: the sidebar JS can't directly inspect other webview titles.
  // The notification polling needs to happen from Rust. For now, mark the
  // architecture as ready and we'll wire the Rust-side title watching later.
}

async function showService(id) {
  document.querySelectorAll('.service-icon').forEach(el => el.classList.remove('active'));
  document.querySelector(`.service-icon[data-id="${id}"]`)?.classList.add('active');
  activeService = id;
  saveState();

  if (window.__TAURI__) {
    try {
      await window.__TAURI__.core.invoke('show_service', { label: id });
    } catch (err) {
      document.title = 'ERR: ' + err;
    }
  }
}

async function refreshCurrent() {
  if (!activeService || !window.__TAURI__) return;
  try {
    await window.__TAURI__.core.invoke('refresh_service', { label: activeService });
  } catch {}
}

function toggleMute() {
  isMuted = !isMuted;
  document.getElementById('btn-mute').classList.toggle('muted', isMuted);
  document.getElementById('mute-waves').setAttribute('d', isMuted
    ? 'M23 9l-6 6M17 9l6 6'
    : 'M19.07 4.93a10 10 0 010 14.14M15.54 8.46a5 5 0 010 7.08');
  saveState();
}
window.__tabburrito_toggleMute = toggleMute;

function toggleDark() {
  isDark = !isDark;
  document.body.classList.toggle('dark', isDark);
  document.body.classList.toggle('light', !isDark);
  saveState();
}

async function toggleAutostart() {
  if (!window.__TAURI__) return;
  try {
    const current = await window.__TAURI__.core.invoke('get_autostart_enabled');
    await window.__TAURI__.core.invoke('set_autostart_enabled', { enabled: !current });
    updateAutostartButton(!current);
  } catch {}
}

function updateAutostartButton(enabled) {
  const btn = document.getElementById('btn-autostart');
  btn.classList.toggle('active-toggle', enabled);
  btn.title = enabled ? 'Autostart: On (click to disable)' : 'Autostart: Off (click to enable)';
}

async function initAutostart() {
  if (!window.__TAURI__) return;
  try {
    const enabled = await window.__TAURI__.core.invoke('get_autostart_enabled');
    updateAutostartButton(enabled);
  } catch {}
}

document.addEventListener('keydown', (e) => {
  if (e.ctrlKey && e.key >= '1' && e.key <= '5') {
    e.preventDefault();
    if (SERVICES[+e.key - 1]) showService(SERVICES[+e.key - 1].id);
  }
  if (e.ctrlKey && e.key === 'm') { e.preventDefault(); toggleMute(); }
  if (e.ctrlKey && e.key === 'd') { e.preventDefault(); toggleDark(); }
  if (e.ctrlKey && e.key === 'r') { e.preventDefault(); refreshCurrent(); }
});

function init() {
  loadState();
  buildSidebar();
  updateNotifyIndicators();

  document.body.classList.toggle('dark', isDark);
  document.body.classList.toggle('light', !isDark);
  if (isMuted) {
    document.getElementById('btn-mute').classList.add('muted');
    document.getElementById('mute-waves').setAttribute('d', 'M23 9l-6 6M17 9l6 6');
  }
  document.getElementById('btn-mute').addEventListener('click', toggleMute);
  document.getElementById('btn-dark').addEventListener('click', toggleDark);
  document.getElementById('btn-refresh').addEventListener('click', refreshCurrent);
  document.getElementById('btn-autostart').addEventListener('click', toggleAutostart);

  initAutostart();

  // Restore last service — wait for window maximize to complete
  // then show the service, which triggers proper webview sizing
  const target = activeService || SERVICES[0].id;
  function tryShow() {
    showService(target);
  }
  // Stagger: try at 500ms, 1s, 2s to handle slow startups
  setTimeout(tryShow, 500);
  setTimeout(tryShow, 1000);
  setTimeout(tryShow, 2000);
}

init();
