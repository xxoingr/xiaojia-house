/*
  情侣小屋 PWA 离线缓存
  策略：优先用网络（保证拿到最新版），网络失败时用缓存（离线也能打开）。
*/
const CACHE = "xiaojia-house-v9-apple-push";
const PRECACHE = [
  "./", "./index.html", "./supabase-config.js?v=20260812-push2", "./manifest.webmanifest",
  "./icons/icon-192.png", "./icons/icon-512.png", "./vendor/supabase.min.js",
  "./assets/empty-roll-cake.jpg", "./assets/logo-chef-bread.jpg", "./assets/mascot-watercolor.jpg",
  "./assets/nav-home.jpg", "./assets/nav-todo.jpg", "./assets/nav-record.jpg", "./assets/nav-diary.jpg",
  "./assets/nav-life.png", "./assets/nav-health.png", "./assets/nav-chat.png", "./assets/nav-me.png",
  "./assets/meal-breakfast.png", "./assets/meal-lunch.png", "./assets/meal-dinner.png", "./assets/meal-snack.png"
];

self.addEventListener("install", e => {
  e.waitUntil(
    caches.open(CACHE).then(c => c.addAll(PRECACHE)).catch(()=>{})
  );
  self.skipWaiting();
});

self.addEventListener("activate", e => {
  e.waitUntil(
    caches.keys().then(keys => Promise.all(keys.filter(k => k !== CACHE).map(k => caches.delete(k))))
  );
  self.clients.claim();
});

self.addEventListener("fetch", e => {
  const url = new URL(e.request.url);
  if (e.request.method !== "GET" || url.origin !== location.origin) return;
  if (e.request.mode === "navigate") {
    e.respondWith(
      fetch(e.request).then(res => {
        if (res && res.status === 200) {
          const copy = res.clone();
          caches.open(CACHE).then(c => c.put(e.request, copy));
        }
        return res;
      }).catch(() => caches.match(e.request).then(m => m || caches.match("./index.html")))
    );
    return;
  }
  e.respondWith(caches.match(e.request).then(cached => {
    const network = fetch(e.request).then(res => {
      if (res && res.status === 200) {
        const copy = res.clone();
        caches.open(CACHE).then(c => c.put(e.request, copy));
      }
      return res;
    }).catch(() => cached || Response.error());
    return cached || network;
  }));
});

self.addEventListener("push", e => {
  let data = {};
  try{ data = e.data ? e.data.json() : {}; }catch(_){ data = { body:e.data ? e.data.text() : "小佳专属小屋有一条提醒" }; }
  const title = data.title || "小佳专属小屋提醒";
  const options = {
    body: data.body || "有一条待办提醒，点开查看。",
    icon: data.icon || "./icons/icon-192.png",
    badge: data.badge || "./icons/icon-192.png",
    tag: data.tag || "xiaojia-house-reminder",
    renotify: true,
    data: { url: data.url || "./" }
  };
  e.waitUntil(self.registration.showNotification(title, options));
});

self.addEventListener("notificationclick", e => {
  e.notification.close();
  const target = e.notification.data && e.notification.data.url ? e.notification.data.url : "./";
  e.waitUntil(clients.matchAll({ type:"window", includeUncontrolled:true }).then(list=>{
    const existing = list.find(client=>"focus" in client);
    if(existing){ existing.navigate(target); return existing.focus(); }
    return clients.openWindow(target);
  }));
});
