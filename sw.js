// Service worker mínimo: hace que el navegador ofrezca instalar la app.
// No guarda nada en caché, así que siempre se ve la última versión.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', () => {});
