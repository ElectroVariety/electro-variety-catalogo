const CACHE = "electro-variety-clientes-push-v9";
const BASE = "/electro-variety-catalogo/clientes/";
const ROOT = "/electro-variety-catalogo/";
const SUPABASE_URL = "https://fwshqclpurjzotehqowq.supabase.co";
const SUPABASE_ANON_KEY = "sb_publishable_1SjIU9YCPiRriheH4AK1TA_oLMn_Iol";
const PUSH_VAPID_PUBLIC_KEY = "BErwYnWOMtaFCFL3l1IPvqTVRuqKbUCqB3-pxkzo9uKlNw9JgPufCMp73srJHCJ0nKA16NGecQ9o6Et9v_hBia0";

const SHELL = [
  BASE,
  BASE + "index.html",
  BASE + "manifest.webmanifest",
  BASE + "pwa-install.js",
  ROOT + "config.js",
  ROOT + "icons/icon-192.png",
  ROOT + "icons/icon-512.png"
];

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(CACHE)
      .then(cache => cache.addAll(SHELL))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(k => k.startsWith("electro-variety-clientes-") && k !== CACHE)
          .map(k => caches.delete(k))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  if(event.request.method !== "GET") return;
  const url = new URL(event.request.url);
  if(url.origin !== location.origin) return;

  event.respondWith(
    fetch(event.request, {cache:"no-store"})
      .then(response => {
        if(response && response.ok){
          const copy=response.clone();
          caches.open(CACHE).then(cache=>cache.put(event.request,copy)).catch(()=>{});
        }
        return response;
      })
      .catch(() => caches.match(event.request).then(response => response || caches.match(BASE + "index.html")))
  );
});

self.addEventListener("push", event => {
  let data={};
  try{ data=event.data ? event.data.json() : {}; }catch(_){ }

  event.waitUntil(
    self.registration.showNotification(
      data.title || "Electro Variety",
      {
        body:data.body || "Hay novedades en el catálogo.",
        icon:data.icon || (ROOT + "icons/icon-192.png"),
        badge:data.badge || (ROOT + "icons/icon-192.png"),
        data:{url:data.url || BASE}
      }
    )
  );
});

function normalizeTarget(raw){
  const target=new URL(raw || BASE,self.location.origin);
  const legacy={
    [ROOT+"clientes.html"]:BASE,
    [ROOT+"index.html"]:ROOT+"vendedores/",
    [ROOT+"stock-deposito.html"]:ROOT+"deposito/",
    [ROOT+"stock-local.html"]:ROOT+"local/",
    [ROOT+"admin.html"]:ROOT+"administrador/"
  };
  if(legacy[target.pathname]) target.pathname=legacy[target.pathname];
  return target.href;
}

self.addEventListener("notificationclick", event => {
  event.notification.close();
  const target=normalizeTarget(event.notification.data?.url);
  event.waitUntil((async()=>{
    const targetUrl=new URL(target,self.location.origin);
    // External targets such as WhatsApp must open directly; do not navigate
    // an existing catalog window to an external URL.
    if(targetUrl.origin!==self.location.origin){
      return self.clients.openWindow(targetUrl.href);
    }
    const clients=await self.clients.matchAll({type:"window",includeUncontrolled:true});
    for(const client of clients){
      if(client.url.startsWith(BASE)){
        try{await client.focus();}catch(_){ }
        try{if("navigate" in client) await client.navigate(targetUrl.href);}catch(_){ }
        return;
      }
    }
    return self.clients.openWindow(targetUrl.href);
  })());
});

async function saveSubscription(subscription){
  if(!subscription) return false;
  const json=subscription.toJSON();
  if(!json.endpoint || !json.keys?.p256dh || !json.keys?.auth) return false;
  const response=await fetch(`${SUPABASE_URL}/rest/v1/rpc/save_client_push_subscription`,{
    method:"POST",
    headers:{
      "Content-Type":"application/json",
      "apikey":SUPABASE_ANON_KEY,
      "Authorization":`Bearer ${SUPABASE_ANON_KEY}`
    },
    body:JSON.stringify({
      p_endpoint:json.endpoint,
      p_p256dh:json.keys.p256dh,
      p_auth:json.keys.auth,
      p_user_agent:self.navigator?.userAgent || "Electro Variety Client Push"
    })
  });
  return response.ok;
}

self.addEventListener("pushsubscriptionchange", event => {
  event.waitUntil((async()=>{
    try{
      const newSubscription=await self.registration.pushManager.subscribe({
        userVisibleOnly:true,
        applicationServerKey:Uint8Array.from(atob(PUSH_VAPID_PUBLIC_KEY.replace(/-/g,"+").replace(/_/g,"/")+"=".repeat((4-PUSH_VAPID_PUBLIC_KEY.length%4)%4)),c=>c.charCodeAt(0))
      });
      await saveSubscription(newSubscription);
      const clients=await self.clients.matchAll({type:"window",includeUncontrolled:true});
      for(const client of clients) client.postMessage({type:"PUSH_SUBSCRIPTION_CHANGED"});
    }catch(error){
      console.warn("No se pudo renovar automáticamente la suscripción Push",error);
    }
  })());
});
