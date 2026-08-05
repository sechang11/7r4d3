// PWA glue: install prompt, service-worker registration, and push subscription.
// Kept out of app.js so the dashboard logic stays about the trading data.
(() => {
const $ = (id) => document.getElementById(id);
const api = window.RMApi;   // token-aware fetch from app.js

// ── service worker ──────────────────────────────────────────────────
if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch((e) => console.warn('SW register failed', e));
  // The SW posts here when a notification is tapped, so the page can jump to
  // the instance the alert was about.
  navigator.serviceWorker.addEventListener('message', (e) => {
    if (e.data?.type === 'alert-open' && e.data.key && window.RMSelectInstance) {
      window.RMSelectInstance(e.data.key);
    }
  });
}

// ── install to home screen ──────────────────────────────────────────
// Android fires beforeinstallprompt; we defer it and drive it from our button
// so "Install" sits in the header rather than as a browser banner.
let deferredPrompt = null;
window.addEventListener('beforeinstallprompt', (e) => {
  e.preventDefault();
  deferredPrompt = e;
  $('installBtn').hidden = false;
});
$('installBtn').onclick = async () => {
  if (!deferredPrompt) return;
  deferredPrompt.prompt();
  await deferredPrompt.userChoice;
  deferredPrompt = null;
  $('installBtn').hidden = true;
};
// Already installed (standalone) — no button needed.
if (window.matchMedia('(display-mode: standalone)').matches) $('installBtn').hidden = true;

// ── push ────────────────────────────────────────────────────────────
const urlB64ToUint8 = (b64) => {
  const pad = '='.repeat((4 - (b64.length % 4)) % 4);
  const raw = atob((b64 + pad).replace(/-/g, '+').replace(/_/g, '/'));
  return Uint8Array.from([...raw].map((c) => c.charCodeAt(0)));
};

const pushBtn = $('pushBtn');
let pushReady = false;

async function refreshPushUi() {
  if (!('serviceWorker' in navigator) || !('PushManager' in window)) { pushBtn.hidden = true; return; }
  pushBtn.hidden = false;
  const reg = await navigator.serviceWorker.ready;
  const sub = await reg.pushManager.getSubscription();
  pushReady = Boolean(sub);
  pushBtn.textContent = pushReady ? '🔔 Alerts on' : '🔔 Alerts';
  pushBtn.classList.toggle('sel', pushReady);
}

async function enablePush() {
  const perm = await Notification.requestPermission();
  if (perm !== 'granted') { pushBtn.textContent = '🔔 blocked'; return; }
  const { publicKey } = await fetch('/api/push/key').then((r) => r.json());
  const reg = await navigator.serviceWorker.ready;
  const sub = await reg.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: urlB64ToUint8(publicKey),
  });
  await api('/api/push/subscribe', {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(sub),
  });
  await refreshPushUi();
  // Prove it end to end right away.
  api('/api/push/test', { method: 'POST' }).catch(() => {});
}

async function disablePush() {
  const reg = await navigator.serviceWorker.ready;
  const sub = await reg.pushManager.getSubscription();
  if (sub) {
    await api('/api/push/unsubscribe', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ endpoint: sub.endpoint }),
    }).catch(() => {});
    await sub.unsubscribe();
  }
  await refreshPushUi();
}

pushBtn.onclick = () => (pushReady ? disablePush() : enablePush());
refreshPushUi();
})();
