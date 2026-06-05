// Minimaler Service Worker — ermöglicht PWA-Installation.
// Kein Caching, kein Offline-Modus — nur für den Install-Prompt nötig.
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', event => event.waitUntil(clients.claim()));
