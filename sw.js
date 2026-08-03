// ISS Remote Monitor — service worker (NETWORK-FIRST)
// Always fetch the freshest files from the network; fall back to cache only
// when offline. Bump CACHE_VER whenever you deploy to force an update.
const CACHE_VER = 'iss-rm-v7';
const CORE = ['/', '/index.html', '/manifest.json', '/icon-192.png', '/icon-512.png'];

self.addEventListener('install', e => {
  self.skipWaiting(); // activate immediately, don't wait for old tabs to close
  e.waitUntil(caches.open(CACHE_VER).then(c => c.addAll(CORE).catch(()=>{})));
});

self.addEventListener('activate', e => {
  e.waitUntil((async () => {
    const keys = await caches.keys();
    await Promise.all(keys.filter(k => k !== CACHE_VER).map(k => caches.delete(k)));
    await self.clients.claim(); // take control of open pages right away
  })());
});

self.addEventListener('fetch', e => {
  const req = e.request;
  if (req.method !== 'GET') return;

  // Never cache Supabase / API calls — always live from network
  const url = new URL(req.url);
  if (url.hostname.endsWith('supabase.co')) return; // let it hit the network directly

  // Network-first for everything else; cache is only an offline fallback
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
