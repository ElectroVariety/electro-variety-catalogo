import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const origins = new Set(["https://electrovariety.github.io", "http://localhost:5173", "http://127.0.0.1:5173", "http://localhost:5500", "http://127.0.0.1:5500"]);
const headers = { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store", "Vary": "Origin" };
type Entity = { entidad: string; situacion: number | null; monto_miles: number | null; dias_atraso: number | null; en_revision: boolean; proceso_judicial: boolean };
const digits = (value: unknown) => String(value ?? "").replace(/\D/g, "");
function cuilCheckDigit(prefix: string, dni: string) {
  const base = `${prefix}${dni.padStart(8, "0")}`;
  const weights = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2];
  const sum = [...base].reduce((total, digit, index) => total + Number(digit) * weights[index], 0);
  const check = 11 - (sum % 11);
  if (check === 11) return `${base}0`;
  if (check === 10) return null;
  return `${base}${check}`;
}
function cuilCandidates(dni: string) {
  return [...new Set(["20", "23", "24", "27"].map(prefix => cuilCheckDigit(prefix, dni)).filter((value): value is string => !!value))];
}
function respond(body: Record<string, unknown>, status: number, origin: string) { const h = new Headers(headers); if (origins.has(origin)) h.set("Access-Control-Allow-Origin", origin); return new Response(JSON.stringify(body), { status, headers: h }); }

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin") ?? "";
  if (request.method === "OPTIONS") { const h = new Headers({ "Access-Control-Allow-Methods": "POST, OPTIONS", "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info", "Access-Control-Max-Age": "86400", Vary: "Origin" }); if (origins.has(origin)) h.set("Access-Control-Allow-Origin", origin); return new Response(null, { status: 204, headers: h }); }
  if (request.method !== "POST") return respond({ error: "Método no permitido." }, 405, origin);
  if (!origins.has(origin)) return respond({ error: "Origen no autorizado." }, 403, origin);
  const authorization = request.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return respond({ error: "Iniciá sesión para consultar la situación crediticia." }, 401, origin);
  let payload: { request_id?: string; cuil?: string };
  try { payload = await request.json(); } catch { return respond({ error: "Solicitud inválida." }, 400, origin); }
  if (!/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(payload.request_id ?? ""))) return respond({ error: "Solicitud inválida." }, 400, origin);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ?? "";
  if (!url || !anonKey) return respond({ error: "La función no está configurada correctamente." }, 500, origin);
  const db = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false }, global: { headers: { Authorization: authorization } } });
  const { data: authData, error: authError } = await db.auth.getUser(authorization.slice(7));
  if (authError || !authData.user) return respond({ error: "La sesión expiró. Iniciá sesión nuevamente." }, 401, origin);
  const { data: profile, error: profileError } = await db.from("admin_profiles").select("role").eq("user_id", authData.user.id).maybeSingle();
  if (profileError || !profile || !["admin", "supervisor"].includes(profile.role)) return respond({ error: "Solo administración y supervisores pueden consultar la situación crediticia." }, 403, origin);
  const { data: application, error: applicationError } = await db.from("customer_sale_requests").select("id,dni").eq("id", payload.request_id).maybeSingle();
  if (applicationError || !application) return respond({ error: "La solicitud no está disponible para tu cuenta." }, 404, origin);
  const dni = String(application.dni ?? "").trim();
  const dniDigits = digits(dni);
  if (!/^\d{7,8}$/.test(dniDigits)) return respond({ error: "Esta solicitud no tiene un DNI válido para identificar el CUIL." }, 422, origin);
  const suppliedCuil = digits(payload.cuil);
  if (payload.cuil && (!/^\d{11}$/.test(suppliedCuil) || suppliedCuil.slice(2, 10) !== dniDigits.padStart(8, "0"))) return respond({ error: "El CUIL ingresado no coincide con el DNI de esta solicitud." }, 422, origin);

  const padded = dniDigits.padStart(8, "0");
  let nosisCuil: string | null = suppliedCuil || null;
  if (!nosisCuil) try {
    const form = new URLSearchParams({ Texto: dni, Tipo: "-1", EdadDesde: "-1", EdadHasta: "-1", IdProvincia: "-1", Localidad: "" });
    const response = await fetch("https://informes.nosis.com/Home/Buscar", { method: "POST", headers: { Accept: "application/json, text/javascript, */*; q=0.01", "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8", "X-Requested-With": "XMLHttpRequest", Referer: "https://informes.nosis.com/" }, body: form, signal: AbortSignal.timeout(5000) });
    if (response.ok) {
      const nosis = await response.json() as Record<string, unknown>;
      const matches = (Array.isArray(nosis.EntidadesEncontradas) ? nosis.EntidadesEncontradas : []).flatMap(row => {
        if (!row || typeof row !== "object") return [];
        const cuil = digits((row as Record<string, unknown>).Documento);
        return /^\d{11}$/.test(cuil) && cuil.slice(2, 10) === padded ? [cuil] : [];
      });
      const unique = [...new Set(matches)];
      if (unique.length === 1) nosisCuil = unique[0];
    }
  } catch { /* Nosis' public search can time out or require a captcha; try the BCRA fallback below. */ }

  const requestBcra = async (cuil: string) => {
    const response = await fetch(`https://api.bcra.gob.ar/CentralDeDeudores/v1.0/Deudas/${cuil}`, { headers: { Accept: "application/json" }, signal: AbortSignal.timeout(10000) });
    if (response.status === 404) return null;
    if (!response.ok) throw new Error(`BCRA devolvió HTTP ${response.status}.`);
    const body = await response.json() as Record<string, unknown>;
    const results = body.results && typeof body.results === "object" ? body.results as Record<string, unknown> : {};
    const periods = Array.isArray(results.periodos) ? results.periodos : [];
    return { cuil, body, periodCount: periods.length };
  };
  let matches: Array<{ cuil: string; body: Record<string, unknown>; periodCount: number }> = [];
  if (nosisCuil) {
    try {
      const result = await requestBcra(nosisCuil);
      if (result) matches = [result];
      else return respond({ result: { cuil: nosisCuil, lookup_source: "Nosis", has_records: false, period: null, entities: [], queried_at: new Date().toISOString() } }, 200, origin);
    } catch { return respond({ error: "Nosis identificó el CUIL, pero el BCRA no pudo completar la consulta. Intentá nuevamente." }, 502, origin); }
  } else {
    const results = await Promise.allSettled(cuilCandidates(dniDigits).map(requestBcra));
    matches = results.flatMap(result => result.status === "fulfilled" && result.value ? [result.value] : []);
    const withRecords = matches.filter(result => result.periodCount > 0);
    if (withRecords.length === 1) matches = withRecords;
    else if (withRecords.length > 1) return respond({ error: "El DNI coincide con más de un CUIL con información en el BCRA. Verificá el CUIL antes de continuar." }, 422, origin);
    else if (!matches.length && results.every(result => result.status === "rejected")) return respond({ error: "No se pudo conectar con el BCRA para consultar los posibles CUIL. Intentá nuevamente." }, 502, origin);
    else return respond({ error: "Nosis no pudo localizar el CUIL y el BCRA no devolvió un registro que permita identificarlo automáticamente. Verificá el CUIL y volvé a consultar." }, 422, origin);
  }
  const cuil = matches[0].cuil;
  const bcra = matches[0].body;
  const results = bcra.results && typeof bcra.results === "object" ? bcra.results as Record<string, unknown> : {};
  const periods = Array.isArray(results.periodos) ? results.periodos : [];
  const latest = [...periods].filter((row): row is Record<string, unknown> => !!row && typeof row === "object").sort((a,b)=>String(b.periodo??"").localeCompare(String(a.periodo??"")))[0];
  const entities: Entity[] = Array.isArray(latest?.entidades) ? latest.entidades.flatMap((row) => {
    if (!row || typeof row !== "object") return [];
    const item = row as Record<string, unknown>;
    return [{ entidad: typeof item.entidad === "string" ? item.entidad : "Entidad informante", situacion: typeof item.situacion === "number" ? item.situacion : null, monto_miles: typeof item.monto === "number" && Number.isFinite(item.monto) ? item.monto : null, dias_atraso: typeof item.diasAtrasoPago === "number" ? item.diasAtrasoPago : null, en_revision: item.enRevision === true, proceso_judicial: item.procesoJud === true }];
  }) : [];
  return respond({ result: { cuil, lookup_source: nosisCuil ? "Nosis" : "BCRA por coincidencia de DNI", has_records: periods.length > 0, period: typeof latest?.periodo === "string" ? latest.periodo : null, entities, queried_at: new Date().toISOString() } }, 200, origin);
});
