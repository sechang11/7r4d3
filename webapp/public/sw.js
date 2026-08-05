// Service worker: makes the dashboard installable and able to receive push.
//
// Two jobs. (1) Cache the app shell so the UI opens instantly and survives a
// dropped connection — the DATA is always fetched live, never cached, because a
// stale price or stale instance list is worse than a spinner. (2) Receive Web
// Push and surface it as a notification even when the app is closed.

const SHELL = 'rm-shell-v1';
const SHELL_FILES = [
  '/', '/index.html', '/style.css',
  '/app.js', '/plan.js', '/journal.js',
  '/icon-192.png', '/manifest.webmanifest',
];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== SHELL).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (e) => {
  const url = new URL(e.request.url);
  // API and cross-origin: always network, never cache. The dashboard's whole
  // premise is that every value is live from the EA.
  if (url.origin !== self.location.origin || url.pathname.startsWith('/api/')) return;

  // App shell: cache-first for instant open, refreshed in the background.
  e.respondWith(
    caches.match(e.request).then((hit) => {
      const net = fetch(e.request)
        .then((res) => {
          if (res.ok) caches.open(SHELL).then((c) => c.put(e.request, res.clone()));
          return res;
        })
        .catch(() => hit);
      return hit || net;
    })
  );
});

// ── push ────────────────────────────────────────────────────────────
self.addEventListener('push', (e) => {
  let data = {};
  try { data = e.data ? e.data.json() : {}; } catch { data = { body: e.data && e.data.text() }; }
  const title = data.title || 'RiskManager';
  e.waitUntil(self.registration.showNotification(title, {
    body:  data.body || '',
    icon:  '/icon-192.png',
    badge: '/icon-192.png',
    tag:   data.tag || 'rm',        // same tag replaces rather than stacks
    renotify: Boolean(data.tag),
    data:  { url: data.url || '/', key: data.key || null },
    vibrate: [80, 40, 80],
  }));
});

// Tapping a notification focuses the app (or opens it), and tells the page which
// instance the alert was about so it can select it.
self.addEventListener('notificationclick', (e) => {
  e.notification.close();
  const target = e.notification.data?.url || '/';
  const key = e.notification.data?.key || null;
  e.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) {
      if ('focus' in c) { c.postMessage({ type: 'alert-open', key }); return c.focus(); }
    }
    return self.clients.openWindow(target + (key ? '?key=' + encodeURIComponent(key) : ''));
  })());
});
