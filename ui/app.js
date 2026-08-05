// Tabburrito sidebar

const SERVICES = [
  { id: 'whatsapp', name: 'WhatsApp', icon: 'WA' },
  { id: 'messenger', name: 'Messenger', icon: 'MS' },
  { id: 'linkedin', name: 'LinkedIn', icon: 'IN' },
  { id: 'bluesky', name: 'Bluesky', icon: 'BS' },
  { id: 'calendar', name: 'Google Calendar', icon: 'GC' },
];

const UNLOAD_PRESETS = [60, 180, 600];

let activeService = null;
let isMuted = false;
let isDark = true;
let notifyServices = ['whatsapp', 'messenger'];
let notifyModes = { whatsapp: 'full', messenger: 'full' }; // off|badge|full
let unreadCounts = {};
let unloadSeconds = 180;
let dndUntil = 0;
let resourceMode = 'balanced'; // lean|balanced|instant
let profiles = {}; // {name: { sidebarState, portablePayload }}

function loadState() {
  try {
    const s = JSON.parse(localStorage.getItem('tabburrito') || '{}');
    isMuted = s.muted || false;
    isDark = s.dark !== undefined ? s.dark : true;
    activeService = s.active || null;
    notifyServices = Array.isArray(s.notifyServices) ? s.notifyServices : notifyServices;
    notifyModes = s.notifyModes || notifyModes;
    unloadSeconds = Number(s.unloadSeconds) || unloadSeconds;
    dndUntil = Number(s.dndUntil) || 0;
    resourceMode = s.resourceMode || resourceMode;
    profiles = s.profiles || {};
  } catch {}
}

function saveState() {
  localStorage.setItem('tabburrito', JSON.stringify({
    muted: isMuted,
    dark: isDark,
    active: activeService,
    notifyServices,
    notifyModes,
    unloadSeconds,
    dndUntil,
    resourceMode,
    profiles,
  }));
}

function inDndWindow() {
  return dndUntil > Date.now();
}

function formatBadgeCount(n) {
  if (!n || n < 1) return '';
  if (n > 99) return '99+';
  return String(n);
}

function buildSidebar() {
  const c = document.getElementById('service-icons');
  SERVICES.forEach((svc) => {
    const btn = document.createElement('button');
    btn.className = 'service-icon';
    btn.title = svc.name;
    btn.dataset.id = svc.id;
    btn.innerHTML = `<span class="svc-emoji">${svc.icon}</span><span class="notif-dot"></span>`;
    btn.addEventListener('click', () => showService(svc.id));
    btn.addEventListener('contextmenu', (e) => {
      e.preventDefault();
      if (e.shiftKey) cycleNotifyMode(svc.id);
      else toggleNotifyService(svc.id);
    });
    c.appendChild(btn);
  });
}

function updateNotifyIndicators() {
  SERVICES.forEach(svc => {
    const btn = document.querySelector(`.service-icon[data-id="${svc.id}"]`);
    if (!btn) return;
    const dot = btn.querySelector('.notif-dot');
    const tracked = notifyServices.includes(svc.id);
    const mode = notifyModes[svc.id] || (tracked ? 'full' : 'off');
    const count = unreadCounts[svc.id] || 0;

    btn.classList.toggle('notify-tracked', tracked);
    btn.classList.toggle('has-unread', tracked && count > 0);
    btn.classList.toggle('mode-badge', mode === 'badge');
    btn.classList.toggle('mode-off', mode === 'off');

    if (!dot) return;
    if (tracked && count > 0) dot.textContent = formatBadgeCount(count);
    else dot.textContent = '';
    btn.title = tracked ? `${svc.name} (${mode})` : `${svc.name} (off)`;
  });
}

function syncNotifyServicesToRust() {
  if (!window.__TAURI__) return;
  SERVICES.forEach(svc => {
    window.__TAURI__.core.invoke('set_notify_service', {
      serviceId: svc.id,
      enabled: notifyServices.includes(svc.id),
    }).catch(() => {});
  });
}

function toggleNotifyService(id) {
  const idx = notifyServices.indexOf(id);
  if (idx >= 0) {
    notifyServices.splice(idx, 1);
    unreadCounts[id] = 0;
    notifyModes[id] = 'off';
  } else {
    notifyServices.push(id);
    notifyModes[id] = notifyModes[id] === 'off' ? 'badge' : (notifyModes[id] || 'full');
  }
  saveState();
  updateNotifyIndicators();
  syncNotifyServicesToRust();
}

function cycleNotifyMode(id) {
  const current = notifyModes[id] || 'off';
  const next = current === 'off' ? 'badge' : current === 'badge' ? 'full' : 'off';
  notifyModes[id] = next;
  if (next === 'off') {
    notifyServices = notifyServices.filter(s => s !== id);
    unreadCounts[id] = 0;
  } else if (!notifyServices.includes(id)) {
    notifyServices.push(id);
  }
  saveState();
  updateNotifyIndicators();
  syncNotifyServicesToRust();
}

function maybeNotify(serviceId, count) {
  const mode = notifyModes[serviceId] || 'off';
  if (mode !== 'full' || inDndWindow()) return;
  if (!('Notification' in window)) return;
  const svc = SERVICES.find(s => s.id === serviceId);
  const title = svc ? svc.name : serviceId;
  if (Notification.permission === 'granted') {
    try {
      new Notification(`Tabburrito: ${title}`, {
        body: `${count} unread direct message${count === 1 ? '' : 's'}`,
      });
    } catch {}
  } else if (Notification.permission !== 'denied') {
    Notification.requestPermission().catch(() => {});
  }
}

function setUnreadCount(serviceId, count) {
  const n = Math.max(0, Math.floor(Number(count) || 0));
  const prev = unreadCounts[serviceId] || 0;
  if (prev === n) return;
  unreadCounts[serviceId] = n;
  if (n > prev) maybeNotify(serviceId, n);
  updateNotifyIndicators();
}

function updateMemoryButton() {
  const btn = document.getElementById('btn-memory');
  if (!btn) return;
  btn.classList.add('memory');
  btn.title = `Unload after: ${Math.round(unloadSeconds / 60)}m (click to cycle 1m/3m/10m)`;
}

async function cycleMemoryPreset() {
  const idx = UNLOAD_PRESETS.findIndex(v => v === unloadSeconds);
  unloadSeconds = UNLOAD_PRESETS[(idx + 1) % UNLOAD_PRESETS.length];
  saveState();
  updateMemoryButton();
  if (window.__TAURI__) {
    await window.__TAURI__.core.invoke('set_unload_seconds', { seconds: unloadSeconds }).catch(() => {});
  }
}

function applyResourceMode(mode) {
  resourceMode = mode;
  if (mode === 'lean') {
    unloadSeconds = 60;
    notifyModes = Object.fromEntries(SERVICES.map(s => [s.id, s.id === 'whatsapp' || s.id === 'messenger' ? 'badge' : 'off']));
  } else if (mode === 'instant') {
    unloadSeconds = 600;
    notifyModes = Object.fromEntries(SERVICES.map(s => [s.id, s.id === 'whatsapp' || s.id === 'messenger' ? 'full' : 'badge']));
  } else {
    unloadSeconds = 180;
    notifyModes = Object.fromEntries(SERVICES.map(s => [s.id, s.id === 'whatsapp' || s.id === 'messenger' ? 'full' : 'off']));
  }
  notifyServices = SERVICES.filter(s => (notifyModes[s.id] || 'off') !== 'off').map(s => s.id);
  saveState();
  updateMemoryButton();
  updateNotifyIndicators();
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('set_unload_seconds', { seconds: unloadSeconds }).catch(() => {});
    syncNotifyServicesToRust();
  }
}

function updateDndButton() {
  const btn = document.getElementById('btn-dnd');
  if (!btn) return;
  if (inDndWindow()) {
    btn.classList.add('dnd-on');
    const mins = Math.ceil((dndUntil - Date.now()) / 60000);
    btn.title = `DND: On (${mins}m left)`;
  } else {
    btn.classList.remove('dnd-on');
    btn.title = 'DND: Off (click to snooze)';
  }
}

function cycleDnd() {
  const now = Date.now();
  if (!inDndWindow()) dndUntil = now + 15 * 60_000;
  else if (dndUntil - now <= 15 * 60_000 + 5000) dndUntil = now + 60 * 60_000;
  else if (dndUntil - now <= 60 * 60_000 + 5000) dndUntil = new Date(new Date().setHours(23, 59, 59, 999)).getTime();
  else dndUntil = 0;
  saveState();
  updateDndButton();
}

async function saveProfile(name) {
  const profile = {
    sidebarState: { muted: isMuted, dark: isDark, active: activeService, notifyServices, notifyModes, unloadSeconds, dndUntil, resourceMode },
    portablePayload: null,
  };
  if (window.__TAURI__) {
    profile.portablePayload = await window.__TAURI__.core.invoke('backup_portable_state').catch(() => null);
  }
  profiles[name] = profile;
  saveState();
}

async function applyProfile(name) {
  const profile = profiles[name];
  if (!profile) return;
  const s = profile.sidebarState || {};
  isMuted = !!s.muted;
  isDark = s.dark !== undefined ? !!s.dark : isDark;
  activeService = s.active || activeService;
  notifyServices = Array.isArray(s.notifyServices) ? s.notifyServices : notifyServices;
  notifyModes = s.notifyModes || notifyModes;
  unloadSeconds = Number(s.unloadSeconds) || unloadSeconds;
  dndUntil = Number(s.dndUntil) || 0;
  resourceMode = s.resourceMode || resourceMode;
  if (profile.portablePayload && window.__TAURI__) {
    await window.__TAURI__.core.invoke('restore_portable_state', { payload: profile.portablePayload }).catch(() => {});
  }
  saveState();
  document.body.classList.toggle('dark', isDark);
  document.body.classList.toggle('light', !isDark);
  updateMemoryButton();
  updateDndButton();
  updateNotifyIndicators();
  syncNotifyServicesToRust();
  if (window.__TAURI__) {
    await window.__TAURI__.core.invoke('set_muted', { muted: isMuted }).catch(() => {});
    await window.__TAURI__.core.invoke('set_unload_seconds', { seconds: unloadSeconds }).catch(() => {});
  }
  if (activeService) await showService(activeService);
}

async function exportPortableBackup() {
  if (!window.__TAURI__) return;
  const payload = await window.__TAURI__.core.invoke('backup_portable_state').catch(() => null);
  if (!payload) return;
  const blob = new Blob([payload], { type: 'application/json' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = `tabburrito-backup-${Date.now()}.json`;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

async function restorePortableBackup() {
  if (!window.__TAURI__) return;
  const payload = window.prompt('Paste portable backup JSON');
  if (!payload) return;
  await window.__TAURI__.core.invoke('restore_portable_state', { payload }).catch(() => {});
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

async function refreshCurrent() {
  if (!activeService || !window.__TAURI__) return;
  await window.__TAURI__.core.invoke('refresh_service', { label: activeService }).catch(() => {});
}

function toggleMute() {
  isMuted = !isMuted;
  document.getElementById('btn-mute').classList.toggle('muted', isMuted);
  document.getElementById('mute-waves').setAttribute('d', isMuted ? 'M23 9l-6 6M17 9l6 6' : 'M19.07 4.93a10 10 0 010 14.14M15.54 8.46a5 5 0 010 7.08');
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

// --- Settings panel bridge -------------------------------------------------
//
// The settings panel is a separate webview with its own localStorage, so it
// cannot read or write this one's state. The sidebar stays the owner of
// sidebar state: it publishes a snapshot and applies changes coming back.

function settingsSnapshot() {
  return {
    dark: isDark,
    muted: isMuted,
    unloadSeconds,
    resourceMode,
    dndUntil,
    notifyModes,
  };
}

function publishSettingsState() {
  if (!window.__TAURI__?.event?.emit) return;
  window.__TAURI__.event.emit('tb-settings-state', settingsSnapshot());
}

function applySettingsChange(change) {
  const { key, value } = change || {};
  switch (key) {
    case 'dark':
      isDark = !!value;
      document.body.classList.toggle('dark', isDark);
      document.body.classList.toggle('light', !isDark);
      break;
    case 'muted':
      // Route through toggleMute's sibling logic so the button icon updates.
      if (isMuted !== !!value) toggleMute();
      return; // toggleMute already saved and synced
    case 'unloadSeconds':
      unloadSeconds = Number(value) || unloadSeconds;
      updateMemoryButton();
      break;
    case 'resourceMode':
      // applyResourceMode saves, syncs Rust, and rewrites notify modes.
      applyResourceMode(value);
      publishSettingsState();
      return;
    case 'dndUntil':
      dndUntil = Number(value) || 0;
      updateDndButton();
      break;
    case 'notifyMode': {
      const id = change.serviceId;
      if (!id) return;
      notifyModes[id] = value;
      if (value === 'off') {
        notifyServices = notifyServices.filter(s => s !== id);
        unreadCounts[id] = 0;
      } else if (!notifyServices.includes(id)) {
        notifyServices.push(id);
      }
      updateNotifyIndicators();
      syncNotifyServicesToRust();
      break;
    }
    default:
      return; // linkedinSort / linkedinAdblock are owned by the URL bar
  }
  saveState();
}

async function openSettings() {
  if (!window.__TAURI__) return;
  await window.__TAURI__.core.invoke('toggle_settings', { show: true }).catch(() => {});
  // settings.js init() runs only once, when the webview is first created.
  // On every SUBSEQUENT open the panel is merely re-shown, so tell it to
  // re-sync — otherwise it would display whatever it held when last closed
  // (including a stale autostart checkbox and stale update status).
  if (window.__TAURI__.event?.emit) {
    window.__TAURI__.event.emit('tb-settings-shown', {});
  }
  publishSettingsState();
}

async function initSettingsBridge() {
  if (!window.__TAURI__?.event?.listen) return;
  try {
    await window.__TAURI__.event.listen('tb-settings-request-state', publishSettingsState);
    await window.__TAURI__.event.listen('tb-settings-change', (event) => {
      applySettingsChange(event.payload || {});
    });
  } catch {}
}

function paletteCommands() {
  const svcCmds = SERVICES.map(s => ({ label: `Switch: ${s.name}`, run: () => showService(s.id) }));
  return [
    ...svcCmds,
    { label: 'Open settings', run: openSettings },
    { label: 'Toggle mute', run: toggleMute },
    { label: 'Refresh current', run: refreshCurrent },
    { label: 'Cycle memory preset', run: cycleMemoryPreset },
    { label: 'Cycle DND', run: cycleDnd },
    { label: 'Mode: Lean', run: () => applyResourceMode('lean') },
    { label: 'Mode: Balanced', run: () => applyResourceMode('balanced') },
    { label: 'Mode: Instant', run: () => applyResourceMode('instant') },
    { label: 'Profile: Save Work', run: () => saveProfile('work') },
    { label: 'Profile: Save Personal', run: () => saveProfile('personal') },
    { label: 'Profile: Save Focus', run: () => saveProfile('focus') },
    { label: 'Profile: Apply Work', run: () => applyProfile('work') },
    { label: 'Profile: Apply Personal', run: () => applyProfile('personal') },
    { label: 'Profile: Apply Focus', run: () => applyProfile('focus') },
    { label: 'Backup: Export portable state', run: exportPortableBackup },
    { label: 'Backup: Restore portable state', run: restorePortableBackup },
  ];
}

function renderPalette(filter = '') {
  const list = document.getElementById('palette-list');
  const q = filter.trim().toLowerCase();
  const items = paletteCommands().filter(c => c.label.toLowerCase().includes(q));
  list.innerHTML = '';
  items.forEach((cmd) => {
    const row = document.createElement('div');
    row.className = 'palette-item';
    row.textContent = cmd.label;
    row.addEventListener('click', async () => {
      await cmd.run();
      closePalette();
    });
    list.appendChild(row);
  });
}

function openPalette() {
  const p = document.getElementById('command-palette');
  const input = document.getElementById('palette-input');
  p.classList.remove('hidden');
  input.value = '';
  renderPalette('');
  setTimeout(() => input.focus(), 0);
}

function closePalette() {
  document.getElementById('command-palette').classList.add('hidden');
}

document.addEventListener('keydown', (e) => {
  if (e.ctrlKey && e.key >= '1' && e.key <= '5') {
    e.preventDefault();
    if (SERVICES[+e.key - 1]) showService(SERVICES[+e.key - 1].id);
  }
  if (e.ctrlKey && e.key.toLowerCase() === 'm') { e.preventDefault(); toggleMute(); }
  if (e.ctrlKey && e.key.toLowerCase() === 'd') { e.preventDefault(); toggleDark(); }
  if (e.ctrlKey && e.key.toLowerCase() === 'r') { e.preventDefault(); refreshCurrent(); }
  if (e.ctrlKey && e.key.toLowerCase() === 'k') { e.preventDefault(); openPalette(); }
  if (e.ctrlKey && e.key === ',') { e.preventDefault(); openSettings(); }
  if (e.key === 'Escape') closePalette();
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
  document.getElementById('btn-dnd').addEventListener('click', cycleDnd);
  document.getElementById('btn-settings').addEventListener('click', openSettings);
  document.getElementById('palette-input').addEventListener('input', (e) => renderPalette(e.target.value || ''));

  updateMemoryButton();
  updateDndButton();
  initAutostart();
  initUnreadListener();
  initSettingsBridge();
  syncNotifyServicesToRust();

  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('set_muted', { muted: isMuted }).catch(() => {});
    window.__TAURI__.core.invoke('set_unload_seconds', { seconds: unloadSeconds }).catch(() => {});
  }
  setInterval(updateDndButton, 30_000);

  const target = activeService || SERVICES[0].id;
  setTimeout(() => showService(target), 500);
  setTimeout(() => showService(target), 1000);
  setTimeout(() => showService(target), 2000);
}

init();
