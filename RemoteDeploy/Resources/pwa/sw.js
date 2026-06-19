// Service worker for RemoteDeploy PWA.
// The PWA is served at the site root (TKT-064), so this worker's scope is "/" --
// it sees every same-origin request. It therefore manages ONLY the known app
// shell assets (network-first, cached as an offline fallback); API calls, the
// per-project OTA install pages, and .ipa/.zip downloads are left entirely to
// the network and are never cached. Bump CACHE_NAME on shell changes to purge
// the old cache on activate.
const CACHE_NAME = 'remotedeploy-v5';
const SHELL_FILES = [
  '/', '/style.css', '/app.js', '/projectform.js', '/settingsform.js',
  '/manifest.json', '/icon.svg',
];
const SHELL = new Set(SHELL_FILES);

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(SHELL_FILES))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  // Only manage same-origin app-shell assets. Everything else (API calls, OTA
  // install pages at /<slug>/, .ipa/.zip downloads) falls through to the default
  // network handling so we never cache large binaries or stale install pages.
  if (url.origin !== location.origin || !SHELL.has(url.pathname)) return;
  // Shell: network-first so a redeploy propagates; refresh the cache on each
  // success and fall back to the cached copy only when offline.
  event.respondWith(
    fetch(req)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(req, copy));
        return response;
      })
      .catch(() => caches.match(req))
  );
});
