// Service worker for RemoteDeploy PWA.
// Caches the app shell only as an OFFLINE FALLBACK. The shell is served
// network-first so a server redeploy is picked up immediately for online users
// (the previous cache-first strategy pinned a stale app.js in the browser
// forever, so PWA updates never reached users). Bump CACHE_NAME on shell
// changes to purge the old cache on activate.
const CACHE_NAME = 'remotedeploy-v4';
const SHELL_FILES = ['/app/', '/app/style.css', '/app/app.js', '/app/manifest.json'];

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
  // API calls always go to the network.
  if (event.request.url.includes('/api/')) {
    event.respondWith(fetch(event.request));
    return;
  }
  // Shell: network-first so deploys propagate; refresh the cache on each
  // success and fall back to the cached copy only when offline.
  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        return response;
      })
      .catch(() => caches.match(event.request))
  );
});
