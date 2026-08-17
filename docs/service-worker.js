// Service worker mínimo: solo existe para que el navegador considere el sitio
// "instalable" como app. Estrategia "red primero, caché de respaldo": mientras haya
// internet siempre se usa el archivo más reciente (importante porque el sistema
// sigue en desarrollo activo); el caché solo entra si el celular está offline.
// Los datos de Supabase nunca se cachean, siempre vienen en vivo.
const CACHE = 'antojitos-shell-v2';
const SHELL = [
  'shared/style.css',
  'shared/supabaseClient.js',
  'shared/img/logo.png',
  'shared/img/favicon.png',
  'shared/img/icon-192.png',
  'shared/img/icon-512.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE).then((cache) => cache.addAll(SHELL)).catch(() => {})
  );
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((nombres) =>
      Promise.all(nombres.filter((n) => n !== CACHE).map((n) => caches.delete(n)))
    )
  );
  self.clients.claim();
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  // Nunca cachear llamadas a Supabase: los datos siempre deben ser en vivo.
  if (url.hostname.endsWith('supabase.co')) return;
  if (event.request.method !== 'GET') return;

  event.respondWith(
    fetch(event.request)
      .then((res) => {
        const copia = res.clone();
        caches.open(CACHE).then((cache) => cache.put(event.request, copia));
        return res;
      })
      .catch(() => caches.match(event.request))
  );
});
