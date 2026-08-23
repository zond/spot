// --- Offline caching of the app shell ---
const CACHE_NAME = 'spot-v1';

self.addEventListener('install', (event) => {
  self.skipWaiting();
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys().then((names) =>
      Promise.all(names.filter((n) => n !== CACHE_NAME).map((n) => caches.delete(n)))
    ).then(() => self.clients.claim())
  );
});

self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;
  if (event.request.method !== 'GET') return;
  event.respondWith(
    fetch(event.request).then((response) => {
      if (response.ok) {
        const clone = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, clone));
      }
      return response;
    }).catch(() => caches.match(event.request))
  );
});

// --- Firebase Cloud Messaging ---
importScripts("https://www.gstatic.com/firebasejs/10.12.0/firebase-app-compat.js");
importScripts("https://www.gstatic.com/firebasejs/10.12.0/firebase-messaging-compat.js");

firebase.initializeApp({
  apiKey: "AIzaSyDdsNrnheLnhAe5fPJNkQo86f40DgBdg5I",
  appId: "1:245672555479:web:01dd2824ac0ff9e94e9192",
  messagingSenderId: "245672555479",
  projectId: "fcm-switch",
  authDomain: "fcm-switch.firebaseapp.com",
  storageBucket: "fcm-switch.firebasestorage.app",
});

const messaging = firebase.messaging();

// Background pushes are state snapshots from the host. Browsers insist that a
// push shows *some* notification, so show a single, silent, self-replacing
// "now playing" one instead of a pile of "site updated in background".
messaging.onBackgroundMessage((payload) => {
  let body = 'Party update';
  try {
    const m = JSON.parse(payload.data?.m || '{}');
    if (m.now && m.now.t) {
      body = `${m.now.t.n} — ${m.now.t.a} (for ${m.now.mn})`;
    } else if (m.h) {
      body = `${m.h}'s party: nothing playing`;
    }
  } catch (e) {}
  return self.registration.showNotification('Spot', {
    body,
    icon: 'icons/Icon-192.png',
    badge: 'icons/badge-96.png',
    tag: 'spot-state',
    renotify: false,
    silent: true,
    data: payload.data,
  });
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil(
    clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if (client.url.includes('spot') && 'focus' in client) return client.focus();
      }
      if (clients.openWindow) return clients.openWindow('./');
    })
  );
});
// build: 2026-08-23T20:11:13+02:00
