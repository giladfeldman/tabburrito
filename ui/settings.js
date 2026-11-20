// Tabburrito settings panel.
//
// This runs in its own webview, so it does NOT share localStorage with the
// sidebar (index.html) or the URL bar (urlbar.html) — each webview has its own
// origin-scoped storage. Changes are therefore broadcast over Tauri events;
// the owning webview applies the change and persists it to its own store.
// This panel never writes the sidebar/urlbar localStorage keys directly.

const SERVICES = [
  { id: 'whatsapp', name: 'WhatsApp' },
  { id: 'messenger', name: 'Messenger' },
  { id: 'linkedin', name: 'LinkedIn' },
  { id: 'bluesky', name: 'Bluesky' },
  { id: 'x', name: 'X' },
  { id: 'calendar', name: 'Google Calendar' },
];

const NOTIFY_MODES = ['off', 'badge', 'full'];
// Only these two report unread counts (see UNREAD_BOOTSTRAP_JS in main.rs).
const NOTIFY_CAPABLE = ['whatsapp', 'messenger'];

const invoke = (cmd, args) =>
  window.__TAURI__ ? window.__TAURI__.core.invoke(cmd, args) : Promise.reject('no tauri');

const emit = (event, payload) => {
  if (window.__TAURI__?.event?.emit) window.__TAURI__.event.emit(event, payload);
};

// Mirrors the sidebar/urlbar state; populated from their broadcast on open.
let state = {
  dark: true,
  muted: false,
  unloadSeconds: 180,
  resourceMode: 'balanced',
  dndUntil: 0,
  notifyModes: {},
  serviceMutes: {},
  linkedinSort: 'recent',
  linkedinAdblock: false,
};

const $ = (id) => document.getElementById(id);

function applyTheme() {
  document.body.classList.toggle('dark', state.dark);
  document.body.classList.toggle('light', !state.dark);
}

function renderNotifyRows() {
  const host = $('notify-rows');
  host.innerHTML = '';
  SERVICES.forEach((svc) => {
    const row = document.createElement('div');
    row.className = 'notify-row';

    const name = document.createElement('span');
    name.className = 'svc-name';
    name.textContent = svc.name;
    if (!NOTIFY_CAPABLE.includes(svc.id)) {
      // Be honest about which tabs can actually report unread counts rather
      // than offering a control that silently does nothing.
      name.textContent += ' — no unread badge';
      name.style.opacity = '0.6';
    }
    row.appendChild(name);

    const seg = document.createElement('div');
    seg.className = 'seg';
    const current = state.notifyModes[svc.id] || 'off';
    NOTIFY_MODES.forEach((mode) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.textContent = mode[0].toUpperCase() + mode.slice(1);
      b.classList.toggle('on', current === mode);
      if (!NOTIFY_CAPABLE.includes(svc.id) && mode !== 'off') {
        b.disabled = true;
        b.style.opacity = '0.4';
        b.style.cursor = 'default';
      } else {
        b.addEventListener('click', () => {
          state.notifyModes[svc.id] = mode;
          emit('tb-settings-change', { key: 'notifyMode', serviceId: svc.id, value: mode });
          renderNotifyRows();
        });
      }
      seg.appendChild(b);
    });
    row.appendChild(seg);
    host.appendChild(row);
  });
}

function renderMuteRows() {
  const host = $('mute-rows');
  if (!host) return;
  host.innerHTML = '';
  SERVICES.forEach((svc) => {
    const row = document.createElement('div');
    row.className = 'notify-row';

    const name = document.createElement('span');
    name.className = 'svc-name';
    name.textContent = svc.name;
    // The master switch wins, so show these as forced-on and disabled
    // rather than letting the row imply a per-tab setting is in effect.
    if (state.muted) name.style.opacity = '0.6';
    row.appendChild(name);

    const label = document.createElement('label');
    label.className = 'switch';
    const input = document.createElement('input');
    input.type = 'checkbox';
    input.checked = state.muted || !!state.serviceMutes[svc.id];
    input.disabled = state.muted;
    input.addEventListener('change', async () => {
      const want = input.checked;
      try {
        await invoke('set_service_muted', { serviceId: svc.id, muted: want });
        state.serviceMutes[svc.id] = want;
        emit('tb-settings-change', { key: 'serviceMute', serviceId: svc.id, value: want });
      } catch {
        input.checked = !want; // did not take
      }
    });
    const slider = document.createElement('span');
    slider.className = 'slider';
    label.appendChild(input);
    label.appendChild(slider);
    row.appendChild(label);
    host.appendChild(row);
  });
}

function dndSelectValue() {
  if (!state.dndUntil || state.dndUntil <= Date.now()) return '0';
  const mins = Math.round((state.dndUntil - Date.now()) / 60000);
  if (mins <= 16) return '15';
  if (mins <= 61) return '60';
  return 'eod';
}

function updateDndNote() {
  const note = $('dnd-note');
  if (state.dndUntil > Date.now()) {
    const mins = Math.ceil((state.dndUntil - Date.now()) / 60000);
    note.textContent = `On — ${mins} minute${mins === 1 ? '' : 's'} left`;
  } else {
    note.textContent = 'Suppresses desktop popups';
  }
}

function updateSleepNote() {
  const note = $('sleep-note');
  if (!note) return;
  const mins = state.unloadSeconds / 60;
  const label = mins < 1
    ? `${state.unloadSeconds} seconds`
    : `${mins} minute${mins === 1 ? '' : 's'}`;
  note.textContent = `Background tabs unload after ${label} to free memory`;
}

function renderAll() {
  applyTheme();
  updateSleepNote();
  $('set-theme').value = state.dark ? 'dark' : 'light';
  $('set-unload').value = String(state.unloadSeconds);
  $('set-resource-mode').value = state.resourceMode;
  $('set-muted').checked = state.muted;
  $('set-dnd').value = dndSelectValue();
  $('set-linkedin-sort').value = state.linkedinSort;
  $('set-linkedin-adblock').checked = state.linkedinAdblock;
  updateDndNote();
  renderNotifyRows();
  renderMuteRows();
}

// --- Update section --------------------------------------------------------
//
// Updates are the signed releases on GitHub, handled in Rust
// (src-tauri/src/updates.rs). This panel only shows that state and offers
// "Check now" / "Restart and install".

function formatTimestamp(raw) {
  if (!raw) return 'Never';
  // Update log timestamps are ISO 8601 UTC ("2026-11-19T13:05:09Z").
  const d = new Date(raw);
  if (isNaN(d.getTime())) return raw;
  return d.toLocaleString();
}

function resultClass(msg) {
  const m = String(msg).toLowerCase();
  if (m.includes('fail') || m.includes('refused') || m.includes('cannot') || m.includes('error')) return 'bad';
  if (m.includes('ready') || m.includes('available') || m.includes('downloaded')) return 'warn';
  if (m.includes('up to date')) return 'good';
  return '';
}

function renderUpdateStatus(s, { keepMessage = false } = {}) {
  $('update-version').textContent = s.runningVersion || '—';
  $('update-meta').textContent = s.canUpdate
    ? 'Installed release'
    : (s.unavailableReason || 'Updates unavailable');
  $('set-auto-update').checked = !!s.autoUpdateEnabled;
  $('set-auto-update').disabled = !s.canUpdate;
  $('btn-check-update').disabled = !s.canUpdate || !!s.checking;
  $('update-last').textContent = formatTimestamp(s.lastChecked);

  const ready = $('update-ready-row');
  if (s.pendingVersion) {
    $('update-ready-version').textContent = `Version ${s.pendingVersion}, downloaded and verified`;
    ready.style.display = '';
  } else {
    ready.style.display = 'none';
  }

  if (keepMessage) return;
  const status = $('update-status');
  if (s.lastResult) {
    status.textContent = s.lastResult;
    status.className = 'note ' + resultClass(s.lastResult);
  } else {
    status.textContent = '';
    status.className = 'note';
  }
}

async function loadUpdateStatus(opts) {
  try {
    renderUpdateStatus(await invoke('get_update_status'), opts);
  } catch (err) {
    $('update-meta').textContent = 'Update status unavailable';
    $('update-status').textContent = String(err);
    $('update-status').className = 'note bad';
  }
}

async function runUpdateAction(command, busyLabel, busyText) {
  const btn = command === 'install_update' ? $('btn-install-update') : $('btn-check-update');
  const idle = btn.textContent;
  const status = $('update-status');
  btn.disabled = true;
  btn.textContent = busyLabel;
  status.className = 'note';
  status.innerHTML = `<span class="spinner"></span>${busyText}`;
  try {
    // On a successful install Tabburrito exits and the installer restarts it,
    // so this await only ever returns with an outcome to show, or an error.
    const msg = await invoke(command);
    status.textContent = msg;
    status.className = 'note ' + resultClass(msg);
  } catch (err) {
    status.textContent = String(err);
    status.className = 'note bad';
  } finally {
    btn.textContent = idle;
    btn.disabled = false;
    await loadUpdateStatus({ keepMessage: true });
  }
}

// --- Wiring ----------------------------------------------------------------

function close() {
  invoke('toggle_settings', { show: false }).catch(() => {});
}

function init() {
  $('settings-close').addEventListener('click', close);
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') close();
  });

  $('set-theme').addEventListener('change', (e) => {
    state.dark = e.target.value === 'dark';
    applyTheme();
    emit('tb-settings-change', { key: 'dark', value: state.dark });
  });

  $('set-unload').addEventListener('change', (e) => {
    state.unloadSeconds = Number(e.target.value);
    updateSleepNote();
    invoke('set_unload_seconds', { seconds: state.unloadSeconds }).catch(() => {});
    emit('tb-settings-change', { key: 'unloadSeconds', value: state.unloadSeconds });
  });

  $('set-resource-mode').addEventListener('change', (e) => {
    state.resourceMode = e.target.value;
    // The sidebar owns this preset: it rewrites unload timing AND notify
    // modes together, then broadcasts the resulting state back to us.
    emit('tb-settings-change', { key: 'resourceMode', value: state.resourceMode });
  });

  $('set-muted').addEventListener('change', (e) => {
    state.muted = e.target.checked;
    // Per-tab switches are overridden while the master is on, so redraw them
    // as forced-on/disabled instead of showing a setting that has no effect.
    renderMuteRows();
    invoke('set_muted', { muted: state.muted }).catch(() => {});
    emit('tb-settings-change', { key: 'muted', value: state.muted });
  });

  $('set-dnd').addEventListener('change', (e) => {
    const v = e.target.value;
    if (v === '0') state.dndUntil = 0;
    else if (v === 'eod') state.dndUntil = new Date(new Date().setHours(23, 59, 59, 999)).getTime();
    else state.dndUntil = Date.now() + Number(v) * 60000;
    updateDndNote();
    emit('tb-settings-change', { key: 'dndUntil', value: state.dndUntil });
  });

  $('set-linkedin-sort').addEventListener('change', (e) => {
    state.linkedinSort = e.target.value;
    invoke('set_linkedin_feed_sort', { sort: state.linkedinSort }).catch(() => {});
    emit('tb-settings-change', { key: 'linkedinSort', value: state.linkedinSort });
  });

  // Only claim the blocker changed once Rust has actually accepted it —
  // otherwise a failed call leaves the checkbox on while the feed is still
  // unblocked. (Codex review 2026-08-05.)
  $('set-linkedin-adblock').addEventListener('change', async (e) => {
    const want = e.target.checked;
    try {
      await invoke('set_adblock_service', { serviceId: 'linkedin', enabled: want });
      state.linkedinAdblock = want;
      emit('tb-settings-change', { key: 'linkedinAdblock', value: want });
    } catch (err) {
      e.target.checked = !want;
      state.linkedinAdblock = !want;
    }
  });

  $('set-autostart').addEventListener('change', async (e) => {
    const want = e.target.checked;
    try {
      await invoke('set_autostart_enabled', { enabled: want });
    } catch {
      e.target.checked = !want; // reflect that it did not take
    }
  });

  $('set-auto-update').addEventListener('change', async (e) => {
    const want = e.target.checked;
    const status = $('update-status');
    try {
      await invoke('set_auto_update_enabled', { enabled: want });
      status.textContent = want
        ? 'Automatic updates on - checks at start and once a day.'
        : 'Automatic updates off. Use "Check now" to update.';
      status.className = 'note good';
    } catch (err) {
      e.target.checked = !want;
      status.textContent = String(err);
      status.className = 'note bad';
    }
  });

  $('btn-check-update').addEventListener('click', () =>
    runUpdateAction('check_for_updates', 'Checking…', 'Checking GitHub for a newer release…'));
  $('btn-install-update').addEventListener('click', () =>
    runUpdateAction('install_update', 'Installing…', 'Installing - Tabburrito will close and reopen in a few seconds.'));

  if (window.__TAURI__?.event?.listen) {
    window.__TAURI__.event.listen('tb-update-ready', () => loadUpdateStatus()).catch(() => {});
  }

  refreshAsyncState();
  renderAll();
  subscribeThenRequestState();
}

/// Re-reads everything this panel cannot be notified about: autostart and
/// update state both live outside the app's event bus.
function refreshAsyncState() {
  invoke('get_autostart_enabled')
    .then((enabled) => { $('set-autostart').checked = !!enabled; })
    .catch(() => {});
  // Per-service mutes live in Rust (no webview owns them), so read them back
  // rather than waiting for a tb-settings-state broadcast that never carries
  // them.
  invoke('get_service_mutes')
    .then((mutes) => { state.serviceMutes = mutes || {}; renderMuteRows(); })
    .catch(() => {});
  loadUpdateStatus();
}

// The state listener MUST be registered before the request is emitted.
// listen() is async: emitting synchronously after calling it lets the
// sidebar's reply arrive before the subscription exists, leaving the panel
// showing defaults (dark, 3m, adblock off) while the app runs different
// values. Confirmed by Codex review 2026-08-05.
async function subscribeThenRequestState() {
  if (!window.__TAURI__?.event?.listen) return;
  try {
    // Two webviews answer: the sidebar sends theme/sleep/notify state, the
    // URL bar sends LinkedIn state. Each sends only the keys it owns, so
    // merge rather than replace — a naive spread of notifyModes would let
    // the URL bar's reply (which has none) erase the sidebar's.
    await window.__TAURI__.event.listen('tb-settings-state', (event) => {
      const p = event.payload || {};
      state = { ...state, ...p };
      if (p.notifyModes) state.notifyModes = { ...state.notifyModes, ...p.notifyModes };
      renderAll();
    });
    // The panel is re-shown rather than re-created on every open after the
    // first, so init() does not run again. Re-sync on each open.
    await window.__TAURI__.event.listen('tb-settings-shown', () => {
      refreshAsyncState();
      emit('tb-settings-request-state', {});
    });
  } catch {
    return;
  }
  emit('tb-settings-request-state', {});
}

init();
