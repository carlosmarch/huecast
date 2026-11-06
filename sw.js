/* Huecast service worker
 * App files: network first, so a new deploy shows up on the next load;
 * the cached copy is only used offline.
 * Fonts: cache first, refreshed in the background (they never change).
 * Weather API: network first, last response as offline fallback.
 */
const VERSION = 'huecast-v3.21.14';
const SHELL = [
  './',
  'index.html',
  'how.html',
  'css/tokens.css',
  'css/style.css',
  'css/how.css',
  'js/how.js',
  'js/roll.js',
  'js/picture.js',
  'js/app.js',
  'js/weather.js',
  'js/conditions.js',
  'js/palette.js',
  'js/scene.js',
  'js/cities.js',
  'js/explore.js',
  'icons/icon.svg',
  'manifest.webmanifest',
];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(VERSION).then(c => c.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', e => {
  e.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k !== VERSION).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', e => {
  const { request } = e;
  if (request.method !== 'GET') return;
  const url = new URL(request.url);

  if (url.hostname === 'api.open-meteo.com') {
    e.respondWith(networkFirst(request));
  } else if (url.origin === location.origin) {
    e.respondWith(appFile(request));
  } else if (url.hostname.endsWith('gstatic.com') || url.hostname === 'fonts.googleapis.com') {
    e.respondWith(staleWhileRevalidate(request));
  }
});

async function networkFirst(request) {
  const cache = await caches.open(VERSION);
  // one cached forecast per location, ignoring the rest of the query
  const u = new URL(request.url);
  const key = `${u.origin}${u.pathname}?lat=${u.searchParams.get('latitude')}&lon=${u.searchParams.get('longitude')}`;
  try {
    const res = await fetch(request);
    if (res.ok) cache.put(key, res.clone());
    return res;
  } catch (err) {
    const cached = await cache.match(key);
    if (cached) return cached;
    throw err;
  }
}

async function appFile(request) {
  const cache = await caches.open(VERSION);
  try {
    const res = await fetch(request, { cache: 'no-cache' });
    if (res.ok) cache.put(request, res.clone());
    return res;
  } catch (err) {
    const cached = await cache.match(request, { ignoreSearch: request.mode === 'navigate' });
    if (cached) return cached;
    throw err;
  }
}

async function staleWhileRevalidate(request) {
  const cache = await caches.open(VERSION);
  const cached = await cache.match(request, { ignoreSearch: request.mode === 'navigate' });
  const network = fetch(request)
    .then(res => {
      if (res.ok || res.type === 'opaque') cache.put(request, res.clone());
      return res;
    })
    .catch(() => cached);
  return cached || network;
}
