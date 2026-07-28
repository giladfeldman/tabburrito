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
let unreadCounts = {}; // { serviceId: number }
let unloadSeconds = 180;
const UNLOAD_PRESETS = [60, 180, 600];

function loadState() {
  try {
    const s = JSON.parse(localStorage.getItem('tabburrito') || '{}');
    isMuted = s.muted || false;
    isDark = s.dark !== undefined ? s.dark : true;
    activeService = s.active || null;
    if (s.notifyServices) notifyServices = s.notifyServices;
    unloadSeconds = Number(s.unloadSeconds) || 180;
  } catch {}
}

function saveState() {
  localStorage.setItem('tabburrito', JSON.stringify({
    muted: isMuted, dark: isDark, active: activeService,
    notifyServices: notifyServices,
    unloadSeconds: unloadSeconds,
  }));
}

function buildSidebar() {
  const c = document.getElementById('service-icons');
  SERVICES.forEach((svc) => {
    const btn = document.createElement('button');
    btn.className = 'service-icon';
    btn.title = svc.name;
    btn.dataset.id = svc.id;

    // Notification badge + icon
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
    unreadCounts[id] = 0;
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

function formatBadgeCount(n) {
  if (!n || n < 1) return '';
  if (n > 99) return '99+';
  return String(n);
}

function updateNotifyIndicators() {
  SERVICES.forEach(svc => {
    const btn = document.querySelector(`.service-icon[data-id="${svc.id}"]`);
    if (!btn) return;
    const dot = btn.querySelector('.notif-dot');
    const isTracked = notifyServices.includes(svc.id);
    const count = unreadCounts[svc.id] || 0;

    btn.classList.toggle('notify-tracked', isTracked);
    btn.classList.toggle('has-unread', isTracked && count > 0);

    if (!dot) return;
    if (isTracked && count > 0) {
      dot.textContent = formatBadgeCount(count);
      btn.title = `${svc.name} — ${count} unread DM${count === 1 ? '' : 's'}`;
    } else {
      dot.textContent = '';
      btn.title = isTracked ? `${svc.name} (notify on)` : svc.name;
    }
  });
}

function setUnreadCount(serviceId, count) {
  const n = Math.max(0, Math.floor(Number(count) || 0));
  if (unreadCounts[serviceId] === n) return;
  unreadCounts[serviceId] = n;
  updateNotifyIndicators();
}

async function showService(id) {
  document.querySelectorAll('.service-icon').forEach(el => el.classList.remove('active'));
  document.querySelector(`.service-icon[data-id="${id}"]`)?.classList.add('active');
  activeService = id;
  saveState();
  window.dispatchEvent(new CustomEvent('tabburrito:active-service', { detail: { id } }));

  if (window.__TAURI__) {
    try {
      await window.__TAURI__.core.invoke('show_service', { label: id });
    } catch (err) {
      document.title = 'ERR: ' + err;
    }
  }
}

function updateMemoryButton() {
  const btn = document.getElementById('btn-memory');
  if (!btn) return;
  btn.classList.add('memory');
  const mins = Math.round(unloadSeconds / 60);
  btn.title = `Unload after: ${mins}m (click to cycle 1m/3m/10m)`;
}

async function cycleMemoryPreset() {
  const idx = UNLOAD_PRESETS.findIndex(v => v === unloadSeconds);
  const next = UNLOAD_PRESETS[(idx + 1) % UNLOAD_PRESETS.length];
  unloadSeconds = next;
  saveState();
  updateMemoryButton();
  if (window.__TAURI__) {
    await window.__TAURI__.core.invoke('set_unload_seconds', { seconds: unloadSeconds }).catch(() => {});
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
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('set_muted', { muted: isMuted }).catch(() => {});
  }
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

function syncNotifyServicesToRust() {
  if (!window.__TAURI__) return;
  // Reset then enable currently tracked services
  SERVICES.forEach(svc => {
    window.__TAURI__.core.invoke('set_notify_service', {
      serviceId: svc.id,
      enabled: notifyServices.includes(svc.id),
    }).catch(() => {});
  });
}

async function initUnreadListener() {
  if (!window.__TAURI__?.event?.listen) return;
  try {
    await window.__TAURI__.event.listen('tb-unread', (event) => {
      const payload = event.payload || {};
      const id = payload.serviceId || payload.service_id;
      if (!id) return;
      setUnreadCount(id, payload.count);
    });
    await window.__TAURI__.event.listen('tb-active-service', (event) => {
      const payload = event.payload || {};
      const id = payload.serviceId || payload.service_id;
      if (!id) return;
      activeService = id;
      document.querySelectorAll('.service-icon').forEach(el => el.classList.remove('active'));
      document.querySelector(`.service-icon[data-id="${id}"]`)?.classList.add('active');
      window.dispatchEvent(new CustomEvent('tabburrito:active-service', { detail: { id } }));
      saveState();
    });
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
  document.getElementById('btn-memory').addEventListener('click', cycleMemoryPreset);

  updateMemoryButton();
  initAutostart();
  initUnreadListener();
  syncNotifyServicesToRust();

  // Apply persisted mute to WebView2 as soon as possible
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('set_muted', { muted: isMuted }).catch(() => {});
    window.__TAURI__.core.invoke('set_unload_seconds', { seconds: unloadSeconds }).catch(() => {});
  }

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
