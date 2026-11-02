(() => {
  "use strict";
  let db = null;
  let profileType = "";
  let active = false;
  let forced = false;
  let continuation = null;
  let profileName = "";
  let profileRoleLabel = "Usuario";

  const style = document.createElement("style");
  style.textContent = `#evStaffProfileButton{display:none;position:fixed;right:16px;bottom:76px;z-index:250;border:0;border-radius:999px;padding:12px 16px;background:#2563eb;color:white;font-weight:900;box-shadow:0 5px 20px #0003}#evStaffProfileOverlay{display:none;position:fixed;inset:0;z-index:1000;align-items:center;justify-content:center;padding:16px;background:#0008;font-family:Arial,sans-serif;color:#111827}#evStaffProfileCard{width:min(100%,460px);max-height:90vh;overflow:auto;border-radius:18px;background:#fff;padding:22px;box-shadow:0 10px 35px #0004}#evStaffProfileCard h2{margin-top:0}#evStaffProfileCard label{display:block;margin:12px 0 5px;font-size:13px;font-weight:900}#evStaffProfileNameRow{display:flex;align-items:center;gap:8px;margin-top:12px}#evStaffProfileNameRow label{margin:0}#evStaffProfileRole{display:inline-block;border:1px solid #e5e7eb;border-radius:999px;padding:3px 8px;background:#f3f4f6;color:#6b7280;font-size:11px;font-weight:700}#evStaffProfileCard input{width:100%;box-sizing:border-box;padding:12px;border:1px solid #cbd5e1;border-radius:9px;font:inherit}#evStaffProfileCard button{width:100%;margin-top:14px;border:0;border-radius:9px;padding:12px;background:#2563eb;color:#fff;font-weight:900;font-size:15px}#evStaffProfileCard #evStaffProfileClose{background:#e5e7eb;color:#111827}#evStaffProfileStatus{min-height:20px;margin-top:10px;color:#374151;font-size:13px;white-space:pre-wrap}`;
  document.head.appendChild(style);
  document.body.insertAdjacentHTML("beforeend", `<button id="evStaffProfileButton" type="button">👤 Mi perfil</button><div id="evStaffProfileOverlay" aria-hidden="true"><div id="evStaffProfileCard" role="dialog" aria-modal="true" aria-labelledby="evStaffProfileTitle"><h2 id="evStaffProfileTitle">👤 Configurá tu perfil</h2><button id="evStaffProfileClose" type="button" style="display:none">Cerrar</button><p id="evStaffProfileIntro">Ingresá tu nombre y elegí una contraseña nueva.</p><div id="evStaffProfileNameRow"><label for="evStaffProfileName">Nombre</label><span id="evStaffProfileRole" aria-label="Rol, solo visualización"></span></div><input id="evStaffProfileName" maxlength="80" autocomplete="name"><label for="evStaffProfilePassword">Nueva contraseña</label><input id="evStaffProfilePassword" type="password" autocomplete="new-password"><label for="evStaffProfileConfirm">Repetir contraseña</label><input id="evStaffProfileConfirm" type="password" autocomplete="new-password"><div id="evStaffProfileStatus" role="status"></div><button id="evStaffProfileSave" type="button">Guardar</button></div></div>`);

  const $ = id => document.getElementById(id);
  function setActive(value) {
    active = !!value;
    $("evStaffProfileButton").style.display = active ? "block" : "none";
    if (!active) { forced = false; continuation = null; close(); }
  }
  function close() {
    $("evStaffProfileOverlay").style.display = "none";
    $("evStaffProfileOverlay").setAttribute("aria-hidden", "true");
  }
  function open(force, name = profileName) {
    forced = !!force;
    $("evStaffProfileTitle").textContent = forced ? "👋 Configurá tu perfil" : "👤 Mi perfil";
    $("evStaffProfileIntro").textContent = forced
      ? "La primera vez, configurá tu nombre y contraseña. Luego podrás cambiarlos desde Mi perfil."
      : "Actualizá tu nombre o elegí una contraseña nueva.";
    $("evStaffProfileName").value = name || "";
    $("evStaffProfileRole").textContent = profileRoleLabel;
    $("evStaffProfilePassword").value = "";
    $("evStaffProfileConfirm").value = "";
    $("evStaffProfileStatus").textContent = "";
    $("evStaffProfileSave").textContent = forced ? "Guardar y continuar" : "Guardar cambios";
    $("evStaffProfileClose").style.display = forced ? "none" : "block";
    $("evStaffProfileOverlay").style.display = "flex";
    $("evStaffProfileOverlay").setAttribute("aria-hidden", "false");
  }
  async function readProfile(type, uid) {
    if (type === "stock") {
      const {data,error} = await db.from("stock_profiles").select("name,profile_setup_completed,active,location").eq("user_id",uid).eq("active",true).maybeSingle();
      return {data,error};
    }
    const {data,error} = await db.from("admin_profiles").select("display_name,profile_setup_completed").eq("user_id",uid).maybeSingle();
    return {data,error};
  }
  async function ensure(client, session, type, onReady) {
    db = client; profileType = type; continuation = onReady;
    if (!session?.user?.id) return false;
    profileRoleLabel = "Usuario";
    const {data,error} = await readProfile(type, session.user.id);
    if (error) {
      $("evStaffProfileStatus").textContent = "No se pudo verificar el perfil. Recargá e intentá nuevamente.";
      open(true, "");
      return false;
    }
    if (!data) return false;
    profileName = data.name || data.display_name || "";
    if (type === "stock") {
      profileRoleLabel = data.location === "deposito" ? "Stock Depósito" : data.location === "local" ? "Stock Local" : "Stock";
    } else {
      const {data:accessRows} = await db.rpc("get_my_staff_access");
      const access = accessRows?.[0];
      profileRoleLabel = access?.role === "custom" ? (access.role_name || "Personalizado")
        : access?.role === "supervisor" ? "Supervisor"
        : access?.role === "admin" ? "Admin" : "Usuario";
    }
    setActive(true);
    if (!data.profile_setup_completed) {
      open(true, profileName);
      return false;
    }
    return true;
  }
  async function save() {
    const name = $("evStaffProfileName").value.trim();
    const password = $("evStaffProfilePassword").value;
    const confirm = $("evStaffProfileConfirm").value;
    const status = $("evStaffProfileStatus");
    if (!name) { status.textContent = "Ingresá tu nombre."; return; }
    if (forced && password.length < 8) { status.textContent = "La contraseña debe tener al menos 8 caracteres."; return; }
    if ((password || confirm) && password.length < 8) { status.textContent = "La contraseña debe tener al menos 8 caracteres."; return; }
    if (password !== confirm) { status.textContent = "Las contraseñas no coinciden."; return; }
    const button = $("evStaffProfileSave"); button.disabled = true; status.textContent = "Guardando…";
    try {
      if (password) {
        const {error} = await db.auth.updateUser({password});
        if (error) throw error;
      }
      const rpc = forced ? "complete_my_profile_setup" : "update_seller_display_name";
      const {data,error} = await db.rpc(rpc, {p_name:name});
      if (error) throw error;
      profileName = data || name;
      if (forced) {
        const next = continuation; continuation = null; close(); forced = false;
        if (next) await next();
      } else {
        status.textContent = "✅ Perfil actualizado.";
        $("evStaffProfilePassword").value = ""; $("evStaffProfileConfirm").value = "";
      }
    } catch (error) { status.textContent = "No se pudo guardar: " + (error.message || error); }
    finally { button.disabled = false; }
  }
  $("evStaffProfileButton").addEventListener("click", () => open(false));
  $("evStaffProfileClose").addEventListener("click", () => { if (!forced) close(); });
  $("evStaffProfileSave").addEventListener("click", save);
  window.EVStaffProfile = { ensure, setActive };
})();
