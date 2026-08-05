// Tabburrito URL bar — shows/edits URL, zoom controls, adblock indicator, LinkedIn feed sort

const SERVICES = [
  { id: 'whatsapp', name: 'WhatsApp', url: 'https://web.whatsapp.com' },
  { id: 'messenger', name: 'Messenger', url: 'https://www.messenger.com' },
  { id: 'linkedin', name: 'LinkedIn', url: 'https://www.linkedin.com/feed/' },
  { id: 'bluesky', name: 'Bluesky', url: 'https://bsky.app' },
  { id: 'calendar', name: 'Calendar', url: 'https://accounts.google.com/ServiceLogin?continue=https://calendar.google.com/calendar/u/0/r?hl%3Den&hl=en' },
];
const DEFAULT_SERVICE_URLS = Object.fromEntries(SERVICES.map(s => [s.id, s.url]));

let currentService = null;
let zoomLevels = {}; // { serviceId: zoomPercent }
let adblockByService = {}; // { serviceId: bool }
let closedServices = {}; // { serviceId: bool }
let linkedinFeedSort = 'recent'; // 'recent' | 'top'
let lastGoodUrls = {}; // { serviceId: url }

function loadState() {
  try {
    const s = JSON.parse(localStorage.getItem('tabburrito_urlbar') || '{}');
    zoomLevels = s.zoom || {};
    adblockByService = s.adblock || {};
    closedServices = s.closed || {};
    lastGoodUrls = s.lastGoodUrls || {};
    linkedinFeedSort = s.linkedinFeedSort === 'top' ? 'top' : 'recent';
    // Load custom URLs
    if (s.urls) {
      for (const svc of SERVICES) {
        if (s.urls[svc.id]) svc.url = s.urls[svc.id];
      }
    }
  } catch {}
}

function saveState() {
  const urls = {};
  SERVICES.forEach(s => urls[s.id] = s.url);
  localStorage.setItem('tabburrito_urlbar', JSON.stringify({
    zoom: zoomLevels,
    adblock: adblockByService,
    closed: closedServices,
    urls: urls,
    linkedinFeedSort: linkedinFeedSort,
    lastGoodUrls: lastGoodUrls,
  }));
}

function getAdblock(id) {
  if (adblockByService[id] === undefined) return id === 'linkedin';
  return adblockByService[id];
}

function setAdblock(id, enabled) {
  adblockByService[id] = enabled;
  saveState();
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('set_adblock_service', {
      serviceId: id,
      enabled: enabled,
    }).catch(() => {});
  }
}

function getZoom(id) {
  return zoomLevels[id] || 100;
}

function setZoom(id, pct) {
  pct = Math.max(25, Math.min(250, pct));
  zoomLevels[id] = pct;
  saveState();
  document.getElementById('zoom-label').textContent = pct + '%';
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('zoom_service', {
      label: id, zoom: pct / 100,
    }).catch(() => {});
  }
}

function updateFeedSortToggle() {
  const el = document.getElementById('feed-sort-toggle');
  if (!el) return;
  const onLinkedIn = currentService === 'linkedin';
  el.classList.toggle('visible', onLinkedIn);
  el.classList.toggle('recent', linkedinFeedSort === 'recent');
  el.classList.toggle('top', linkedinFeedSort === 'top');
  el.textContent = linkedinFeedSort === 'recent' ? 'Sort: Recent' : 'Sort: Top';
  el.title = 'LinkedIn feed sort — click to toggle Top/Recent';
}

function syncLinkedInFeedSort() {
  if (!window.__TAURI__) return;
  window.__TAURI__.core.invoke('set_linkedin_feed_sort', {
    sort: linkedinFeedSort,
  }).catch(() => {});
}

function toggleLinkedInFeedSort() {
  linkedinFeedSort = linkedinFeedSort === 'recent' ? 'top' : 'recent';
  saveState();
  updateFeedSortToggle();
  syncLinkedInFeedSort();
}

// Reflects the current service's adblock state in the indicator. Shared by
// updateForService, the indicator's own click handler, and the settings panel.
function updateAdblockButton() {
  const ab = document.getElementById('adblock-indicator');
  if (!ab || !currentService) return;
  const enabled = getAdblock(currentService);
  ab.classList.add('visible');
  ab.classList.toggle('disabled', !enabled);
  ab.textContent = enabled ? '\u{1F6E1} AdBlock On' : '\u{1F6E1} AdBlock Off';
}

function updateForService(id) {
  currentService = id;
  const svc = SERVICES.find(s => s.id === id);
  if (!svc) return;

  document.getElementById('svc-label').textContent = svc.name;
  document.getElementById('url-input').value = svc.url;
  document.getElementById('zoom-label').textContent = getZoom(id) + '%';

  updateAdblockButton();
  updateFeedSortToggle();

  // Apply saved zoom
  const zoom = getZoom(id);
  if (zoom !== 100 && window.__TAURI__) {
    window.__TAURI__.core.invoke('zoom_service', {
      label: id, zoom: zoom / 100,
    }).catch(() => {});
  }
}

// Sync active service from sidebar via custom event (same window) or storage (fallback)
window.addEventListener('tabburrito:active-service', (e) => {
  const id = e.detail?.id;
  if (id && id !== currentService) {
    updateForService(id);
  }
});

window.addEventListener('storage', (e) => {
  if (e.key === 'tabburrito') {
    try {
      const s = JSON.parse(e.newValue || '{}');
      if (s.active && s.active !== currentService) {
        updateForService(s.active);
      }
    } catch {}
  }
});

async function pushServiceUrlToRust(id, url) {
  if (!window.__TAURI__) return;
  await window.__TAURI__.core.invoke('set_service_url', {
    serviceId: id,
    url: url,
  }).catch(() => {});
}

// Init
document.getElementById('url-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && currentService) {
    let url = e.target.value.trim();
    if (!url.startsWith('http')) url = 'https://' + url;
    const svc = SERVICES.find(s => s.id === currentService);
    if (svc) {
      const prev = svc.url;
      if (prev && prev !== url) lastGoodUrls[currentService] = prev;
      svc.url = url;
    }
    saveState();
    if (window.__TAURI__) {
      pushServiceUrlToRust(currentService, url);
      window.__TAURI__.core.invoke('navigate_service', {
        label: currentService, url: url,
      }).catch(() => {});
    }
  }
});

document.getElementById('btn-go').addEventListener('click', () => {
  document.getElementById('url-input').dispatchEvent(
    new KeyboardEvent('keydown', { key: 'Enter' })
  );
});

document.getElementById('btn-zin').addEventListener('click', () => {
  if (currentService) setZoom(currentService, getZoom(currentService) + 10);
});

document.getElementById('btn-zout').addEventListener('click', () => {
  if (currentService) setZoom(currentService, getZoom(currentService) - 10);
});

document.getElementById('adblock-indicator').addEventListener('click', () => {
  if (!currentService) return;
  const enabled = !getAdblock(currentService);
  setAdblock(currentService, enabled);
  updateForService(currentService);
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('reload_service', { label: currentService }).catch(() => {});
  }
});

document.getElementById('feed-sort-toggle').addEventListener('click', () => {
  if (currentService !== 'linkedin') return;
  toggleLinkedInFeedSort();
});

function openServiceTab() {
  if (!currentService) return;
  const svc = SERVICES.find(s => s.id === currentService);
  if (!svc) return;
  closedServices[currentService] = false;
  saveState();
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('navigate_service', {
      label: currentService,
      url: svc.url,
    }).catch(() => {});
  }
}

function reloadServiceTab() {
  if (!currentService || !window.__TAURI__) return;
  const svc = SERVICES.find(s => s.id === currentService);
  if (!svc) return;
  pushServiceUrlToRust(currentService, svc.url);
  window.__TAURI__.core.invoke('navigate_service', {
    label: currentService,
    url: svc.url,
  }).catch(() => {});
}

function closeServiceTab() {
  if (!currentService || !window.__TAURI__) return;
  closedServices[currentService] = true;
  saveState();
  window.__TAURI__.core.invoke('navigate_service', {
    label: currentService,
    url: 'about:blank',
  }).catch(() => {});
}

document.getElementById('btn-open').addEventListener('click', openServiceTab);
document.getElementById('btn-reload').addEventListener('click', reloadServiceTab);
document.getElementById('btn-close').addEventListener('click', closeServiceTab);
document.getElementById('btn-reset-url').addEventListener('click', () => {
  if (!currentService) return;
  const svc = SERVICES.find(s => s.id === currentService);
  const def = DEFAULT_SERVICE_URLS[currentService];
  if (!svc || !def) return;
  const prev = svc.url;
  if (prev && prev !== def) lastGoodUrls[currentService] = prev;
  svc.url = def;
  document.getElementById('url-input').value = def;
  saveState();
  pushServiceUrlToRust(currentService, def);
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('navigate_service', { label: currentService, url: def }).catch(() => {});
  }
});
document.getElementById('btn-restore-url').addEventListener('click', () => {
  if (!currentService) return;
  const svc = SERVICES.find(s => s.id === currentService);
  const restored = lastGoodUrls[currentService];
  if (!svc || !restored) return;
  svc.url = restored;
  document.getElementById('url-input').value = restored;
  saveState();
  pushServiceUrlToRust(currentService, restored);
  if (window.__TAURI__) {
    window.__TAURI__.core.invoke('navigate_service', { label: currentService, url: restored }).catch(() => {});
  }
});

// Init
loadState();
try {
  const s = JSON.parse(localStorage.getItem('tabburrito') || '{}');
  updateForService(s.active || 'whatsapp');
} catch {
  updateForService('whatsapp');
}

// Sync adblock defaults + LinkedIn sort to Rust at startup.
if (window.__TAURI__) {
  SERVICES.forEach(svc => {
    const enabled = getAdblock(svc.id);
    window.__TAURI__.core.invoke('set_adblock_service', {
      serviceId: svc.id,
      enabled: enabled,
    }).catch(() => {});
  });
  syncLinkedInFeedSort();
  SERVICES.forEach(svc => {
    pushServiceUrlToRust(svc.id, svc.url);
  });
  if (window.__TAURI__?.event?.listen) {
    window.__TAURI__.event.listen('tb-active-service', (event) => {
      const payload = event.payload || {};
      const id = payload.serviceId || payload.service_id;
      if (!id || id === currentService) return;
      updateForService(id);
    }).catch(() => {});

    // The settings panel owns no state of its own — LinkedIn sort and the
    // adblock toggle live here, so mirror its changes into this webview's
    // store and keep the URL-bar controls in step.
    window.__TAURI__.event.listen('tb-settings-change', (event) => {
      const { key, value } = event.payload || {};
      if (key === 'linkedinSort') {
        linkedinFeedSort = value === 'top' ? 'top' : 'recent';
        saveState();
        updateFeedSortToggle();
        syncLinkedInFeedSort();
      } else if (key === 'linkedinAdblock') {
        setAdblock('linkedin', !!value);
        updateAdblockButton();
        // The blocker is injected on page load, so toggling it only takes
        // effect after a reload — same as the indicator's click handler.
        window.__TAURI__.core.invoke('reload_service', { label: 'linkedin' }).catch(() => {});
      }
    }).catch(() => {});

    // Answer the panel's state request with what this webview owns.
    window.__TAURI__.event.listen('tb-settings-request-state', () => {
      window.__TAURI__.event.emit('tb-settings-state', {
        linkedinSort: linkedinFeedSort,
        linkedinAdblock: getAdblock('linkedin'),
      });
    }).catch(() => {});
  }
}
