// Service worker mínimo: solo cachea la interfaz estática (HTML/CSS/JS/íconos)
// para que el navegador pueda "instalar" la app. Los datos siempre se piden
// en vivo a Supabase, no se guardan offline.
const CACHE = 'fichaje-shell-v3';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icon-192.png', './icon-512.png', './icon-maskable-512.png'];

self.addEventListener('install', (e) => {
  e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)));
  self.skipWaiting();
});

self.addEventListener('activate', (e) => {
  e.waitUntil(
    caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
  );
  self.clients.claim();
});

self.addEventListener('fetch', (e) => {
  // No interceptamos llamadas a Supabase; solo servimos el shell desde caché
  // cuando corresponde, con la red como fuente principal.
  if (e.request.method !== 'GET' || e.request.url.includes('supabase.co')) return;
  e.respondWith(
    fetch(e.request).catch(() => caches.match(e.request))
  );
});
