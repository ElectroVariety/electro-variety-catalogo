(() => {
  let deferredPrompt = null;
  const path = location.pathname;
  let app = "";

  if (path.includes("/vendedores/")) app = "vendedores";
  else if (path.includes("/clientes/")) app = "clientes";
  else if (path.includes("/deposito/")) app = "deposito";
  else if (path.includes("/local/")) app = "local";
  else if (path.includes("/administrador/")) app = "administrador";

  const labels = {
    vendedores: "📱 Instalar Electro Variety - Vendedores",
    clientes: "🛍️ Instalar Electro Variety - Catálogo",
    deposito: "🏭 Instalar Electro Variety - Depósito",
    local: "🏪 Instalar Electro Variety - Local",
    administrador: "🔐 Instalar Electro Variety - Administrador"
  };
  const label = labels[app] || "📲 Instalar Electro Variety";

  const isInstalled = () => window.matchMedia?.("(display-mode: standalone)").matches || navigator.standalone === true;

  async function install() {
    if (isInstalled()) return { outcome: "installed" };
    if (!deferredPrompt) return { outcome: "manual" };
    const promptEvent = deferredPrompt;
    deferredPrompt = null;
    try {
      promptEvent.prompt();
      return await promptEvent.userChoice;
    }
    catch (_) { return { outcome: "manual" }; }
  }

  function makeButton() {
    if (document.getElementById("evInstallPwa")) return;
    const b = document.createElement("button");
    b.id = "evInstallPwa";
    b.type = "button";
    b.textContent = label;
    Object.assign(b.style, {
      position:"fixed", left:"20px", right:"20px", bottom:"18px", zIndex:"99999",
      border:"0", borderRadius:"18px", padding:"16px 18px", background:"#16c75b",
      color:"#fff", fontSize:"16px", fontWeight:"900",
      boxShadow:"0 8px 28px rgba(0,0,0,.28)", cursor:"pointer",
      display:"none"
    });
    b.addEventListener("click", async () => {
      if (!deferredPrompt) return;
      deferredPrompt.prompt();
      try { await deferredPrompt.userChoice; } catch (_) {}
      deferredPrompt = null;
      b.remove();
    });
    document.body.appendChild(b);
    return b;
  }

  window.addEventListener("beforeinstallprompt", e => {
    e.preventDefault();
    deferredPrompt = e;
    window.dispatchEvent(new CustomEvent("ev-pwa-install-available"));
    if (app !== "clientes") {
      const b = makeButton();
      if (b) b.style.display = "block";
    }
  });

  window.addEventListener("appinstalled", () => {
    const b = document.getElementById("evInstallPwa");
    if (b) b.remove();
    deferredPrompt = null;
  });

  window.ElectroVarietyPWA = { app, label, install, isInstalled };
})();
