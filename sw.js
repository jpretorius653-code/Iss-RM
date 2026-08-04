// ISS Remote Monitor — service worker (NETWORK-FIRST)
// Installable PWA, but always loads the freshest files. Never serves a stale
// dashboard. Bump CACHE_VER on each deploy to force a clean update.
const CACHE_VER = 'iss-rm-v8';
const CORE = ['/', '/index.html', '/manifest.json',
              '/icon-192.png', '/icon-512.png', '/icon-maskable-512.png', '/apple-touch-icon.png'];

self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE_VER).then(c => c.addAll(CORE).catch(()=>{})));
});
self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE_VER).map(k => caches.delete(k)));
    await self.clients.claim();
  })());
});
self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co')) return;   // never cache API/data
  e.respondWith((async () => {
    try {
      const fresh = await fetch(req);
      const cache = await caches.open(CACHE_VER);
      cache.put(req, fresh.clone()).catch(()=>{});
      return fresh;
    } catch (err) {
      const cached = await caches.match(req);
      return cached || caches.match('/index.html');
    }
  })());
});
