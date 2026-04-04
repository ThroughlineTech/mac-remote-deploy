// Service worker for RemoteDeploy PWA.
// Caches the app shell for offline access to the UI.
const CACHE_NAME = 'remotedeploy-v2';
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
  // Network-first for API calls, cache-first for shell
  if (event.request.url.includes('/api/')) {
    event.respondWith(fetch(event.request));
  } else {
    event.respondWith(
      caches.match(event.request).then((cached) => cached || fetch(event.request))
    );
  }
});
