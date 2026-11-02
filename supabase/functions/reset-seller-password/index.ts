import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function jsonResponse(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

Deno.serve(async (request: Request) => {
  if (request.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (request.method !== "POST") return jsonResponse({ error: "Método no permitido." }, 405);

  const authorization = request.headers.get("Authorization");
  const bearer = authorization?.match(/^Bearer\s+(.+)$/i)?.[1];
  if (!bearer) return jsonResponse({ error: "Sesión no autorizada." }, 401);

  const url = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anonKey || !serviceRoleKey) {
    return jsonResponse({ error: "Falta configuración segura en el servidor." }, 500);
  }

  const userClient = createClient(url, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const adminClient = createClient(url, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: authData, error: authError } = await userClient.auth.getUser(bearer);
  if (authError || !authData.user) return jsonResponse({ error: "Sesión no autorizada." }, 401);

  const { data: profile, error: profileError } = await adminClient
    .from("admin_profiles")
    .select("role")
    .eq("user_id", authData.user.id)
    .maybeSingle();
  if (profileError) return jsonResponse({ error: "No se pudo verificar el rol administrador." }, 500);
  if (profile?.role !== "admin") return jsonResponse({ error: "Solo un administrador puede restablecer contraseñas." }, 403);

  let body: { user_id?: unknown; password?: unknown };
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ error: "Solicitud inválida." }, 400);
  }
  const userId = typeof body.user_id === "string" ? body.user_id : "";
  const password = typeof body.password === "string" ? body.password : "";
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(userId)) {
    return jsonResponse({ error: "Vendedor inválido." }, 400);
  }
  if (password.length < 8 || password.length > 128) {
    return jsonResponse({ error: "La contraseña debe tener entre 8 y 128 caracteres." }, 400);
  }

  const { data: seller, error: sellerError } = await adminClient
    .from("seller_profiles")
    .select("user_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (sellerError) return jsonResponse({ error: "No se pudo verificar el vendedor." }, 500);
  if (!seller) return jsonResponse({ error: "No se encontró el perfil de vendedor." }, 404);

  const { error: updateError } = await adminClient.auth.admin.updateUserById(userId, { password });
  if (updateError) return jsonResponse({ error: updateError.message || "No se pudo cambiar la contraseña." }, 400);

  return jsonResponse({ success: true });
});
