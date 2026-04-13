// Tabburrito URL bar — shows/edits URL, zoom controls, adblock indicator

const SERVICES = [
  { id: 'whatsapp', name: 'WhatsApp', url: 'https://web.whatsapp.com' },
  { id: 'messenger', name: 'Messenger', url: 'https://www.messenger.com' },
  { id: 'linkedin', name: 'LinkedIn', url: 'https://www.linkedin.com/feed/' },
  { id: 'bluesky', name: 'Bluesky', url: 'https://bsky.app' },
  { id: 'calendar', name: 'Calendar', url: 'https://accounts.google.com/ServiceLogin?continue=https://calendar.google.com/calendar/u/0/r?hl%3Den&hl=en' },
];

let currentService = null;
let zoomLevels = {}; // { serviceId: zoomPercent }
let adblockByService = {}; // { serviceId: bool }
let closedServices = {}; // { serviceId: bool }

function loadState() {
  try {
    const s = JSON.parse(localStorage.getItem('tabburrito_urlbar') || '{}');
    zoomLevels = s.zoom || {};
    adblockByService = s.adblock || {};
    closedServices = s.closed || {};
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

function updateForService(id) {
  currentService = id;
  const svc = SERVICES.find(s => s.id === id);
  if (!svc) return;

  document.getElementById('svc-label').textContent = svc.name;
  document.getElementById('url-input').value = svc.url;
  document.getElementById('zoom-label').textContent = getZoom(id) + '%';

  // Adblock indicator per service
  const ab = document.getElementById('adblock-indicator');
  const enabled = getAdblock(id);
  ab.classList.add('visible');
  ab.classList.toggle('disabled', !enabled);
  ab.textContent = enabled ? '\u{1F6E1} AdBlock On' : '\u{1F6E1} AdBlock Off';

  // Apply saved zoom
  const zoom = getZoom(id);
  if (zoom !== 100 && window.__TAURI__) {
    window.__TAURI__.core.invoke('zoom_service', {
      label: id, zoom: zoom / 100,
    }).catch(() => {});
  }
}

// Listen for service changes from sidebar via storage events
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

// Also poll (storage events don't fire within same origin sometimes)
setInterval(() => {
  try {
    const s = JSON.parse(localStorage.getItem('tabburrito') || '{}');
    if (s.active && s.active !== currentService) {
      updateForService(s.active);
    }
  } catch {}
}, 500);

// Navigate on Enter
document.getElementById('url-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter' && currentService) {
    let url = e.target.value.trim();
    if (!url.startsWith('http')) url = 'https://' + url;
    const svc = SERVICES.find(s => s.id === currentService);
    if (svc) svc.url = url;
    saveState();
    if (window.__TAURI__) {
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
  window.__TAURI__.core.invoke('reload_service', {
    label: currentService,
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

// Init
loadState();
try {
  const s = JSON.parse(localStorage.getItem('tabburrito') || '{}');
  updateForService(s.active || 'whatsapp');
} catch {
  updateForService('whatsapp');
}

// Sync adblock defaults to Rust at startup.
if (window.__TAURI__) {
  SERVICES.forEach(svc => {
    const enabled = getAdblock(svc.id);
    window.__TAURI__.core.invoke('set_adblock_service', {
      serviceId: svc.id,
      enabled: enabled,
    }).catch(() => {});
  });
}
