const CACHE_NAME = 'oriveo-v3';
const STATIC_ASSETS = [
  '/',
  '/offline.html',
  '/manifest.json',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME).then((cache) => cache.addAll(STATIC_ASSETS))
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(keys.filter((k) => k !== CACHE_NAME).map((k) => caches.delete(k)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);

  // Skip non-GET requests
  if (request.method !== 'GET') return;

  // API routes and streaming: network-only
  if (url.pathname.startsWith('/api/')) return;

  // RSC payloads (router prefetch and soft navigation) bypass the service worker: routing them
  // through it only adds worker scheduling latency, and they are not worth caching.
  if (url.searchParams.has('_rsc')) return;
  if (request.headers.get('RSC') === '1' || request.headers.get('Next-Router-Prefetch') === '1') {
    return;
  }

  // Pages (HTML): network-first with offline fallback
  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request).catch(() => caches.match('/offline.html'))
    );
    return;
  }

  // Static assets are network-first: always the newest while online, cache only as an offline
  // fallback. Cache-first pinned CSS and JS locally forever, so a user could stay on stale styling
  // after a deploy with no way to clear it.
  if (url.pathname.match(/\.(js|css|woff2?|png|svg|ico|jpg|webp)$/)) {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.ok) {
            const clone = response.clone();
            caches.open(CACHE_NAME).then((cache) => cache.put(request, clone));
          }
          return response;
        })
        .catch(() => caches.match(request))
    );
    return;
  }

  // Everything else is network-only: not calling respondWith keeps the request off the worker.
});
