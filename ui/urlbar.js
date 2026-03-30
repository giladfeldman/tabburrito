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
let adblockEnabled = true;

function loadState() {
  try {
    const s = JSON.parse(localStorage.getItem('tabburrito_urlbar') || '{}');
    zoomLevels = s.zoom || {};
    adblockEnabled = s.adblock !== undefined ? s.adblock : true;
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
    adblock: adblockEnabled,
    urls: urls,
  }));
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

  // Show adblock indicator only for LinkedIn
  const ab = document.getElementById('adblock-indicator');
  if (id === 'linkedin') {
    ab.classList.add('visible');
    ab.classList.toggle('disabled', !adblockEnabled);
    ab.textContent = adblockEnabled ? '\u{1F6E1} AdBlock On' : '\u{1F6E1} AdBlock Off';
  } else {
    ab.classList.remove('visible');
  }

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
  adblockEnabled = !adblockEnabled;
  saveState();
  const ab = document.getElementById('adblock-indicator');
  ab.classList.toggle('disabled', !adblockEnabled);
  ab.textContent = adblockEnabled ? '\u{1F6E1} AdBlock On' : '\u{1F6E1} AdBlock Off';
  // Refresh LinkedIn to apply/remove
  if (currentService === 'linkedin' && window.__TAURI__) {
    window.__TAURI__.core.invoke('refresh_service', { label: 'linkedin' }).catch(() => {});
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
