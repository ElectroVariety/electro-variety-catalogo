import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://electrovariety.github.io",
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  "http://localhost:5500",
  "http://127.0.0.1:5500",
]);
const MAX_BODY_BYTES = 24_000;
const MAX_ITEMS = 10;
const MAX_QUANTITY = 10;
const rateWindows = new Map<string, { start: number; count: number }>();

const responseHeaders = {
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
  "Vary": "Origin",
};

function respond(body: Record<string, unknown>, status: number, origin: string) {
  const headers = new Headers(responseHeaders);
  if (allowedOrigins.has(origin)) headers.set("Access-Control-Allow-Origin", origin);
  return new Response(JSON.stringify(body), { status, headers });
}

function cleanText(value: unknown, maximum: number, required = false): string | null {
  if (typeof value !== "string") return required ? null : "";
  const result = value.trim();
  if (result.length > maximum || (required && result.length < 2)) return null;
  return result;
}

function moneyAmount(value: unknown): number | null {
  const digits = String(value ?? "").replace(/\D/g, "");
  if (!digits) return null;
  const amount = Number(digits);
  return Number.isSafeInteger(amount) && amount > 0 ? amount : null;
}

function trackingCode(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(5));
  const token = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("").toUpperCase();
  return `VTA-${token}`;
}

function checkRateLimit(request: Request): boolean {
  const ip = request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? "unknown";
  if (ip === "unknown") return true;
  const now = Date.now();
  const existing = rateWindows.get(ip);
  if (!existing || now - existing.start > 10 * 60_000) {
    rateWindows.set(ip, { start: now, count: 1 });
    return true;
  }
  existing.count += 1;
  return existing.count <= 8;
}

Deno.serve(async (request: Request) => {
  const origin = request.headers.get("origin") ?? "";
  if (request.method === "OPTIONS") {
    const headers = new Headers({
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Allow-Headers": "apikey, content-type, x-client-info",
      "Access-Control-Max-Age": "86400",
      "Vary": "Origin",
    });
    if (allowedOrigins.has(origin)) headers.set("Access-Control-Allow-Origin", origin);
    return new Response(null, { status: 204, headers });
  }
  if (request.method !== "POST") return respond({ error: "Método no permitido." }, 405, origin);
  if (!allowedOrigins.has(origin)) return respond({ error: "Origen no autorizado." }, 403, origin);
  if (!checkRateLimit(request)) return respond({ error: "Esperá unos minutos antes de volver a enviar una solicitud." }, 429, origin);
  if (!(request.headers.get("content-type") ?? "").toLowerCase().includes("application/json")) {
    return respond({ error: "El formulario no tiene un formato válido." }, 415, origin);
  }
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) return respond({ error: "La solicitud es demasiado extensa." }, 413, origin);

  let body: Record<string, unknown>;
  try {
    const parsed: unknown = await request.json();
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error("invalid");
    body = parsed as Record<string, unknown>;
  } catch {
    return respond({ error: "No se pudieron leer los datos del formulario." }, 400, origin);
  }
  if (new TextEncoder().encode(JSON.stringify(body)).length > MAX_BODY_BYTES) {
    return respond({ error: "La solicitud es demasiado extensa." }, 413, origin);
  }
  if (cleanText(body.website, 200)) return respond({ error: "No se pudo validar el formulario." }, 400, origin);

  const fullName = cleanText(body.full_name, 120, true);
  const phone = String(body.phone ?? "").replace(/\D/g, "");
  const locality = cleanText(body.locality, 120);
  const address = cleanText(body.address, 200);
  const notes = cleanText(body.notes, 1000);
  if (!fullName || phone.length < 8 || phone.length > 20 || locality === null || address === null || notes === null) {
    return respond({ error: "Revisá el nombre, el celular y los datos ingresados." }, 400, origin);
  }
  if (body.privacy_accepted !== true) return respond({ error: "Aceptá el uso de tus datos para poder enviar la solicitud." }, 400, origin);

  if (!Array.isArray(body.items) || body.items.length < 1 || body.items.length > MAX_ITEMS) {
    return respond({ error: `Elegí entre 1 y ${MAX_ITEMS} productos.` }, 400, origin);
  }
  const requestedItems: Array<{ productId: number; quantity: number; frequency: "quincenal" | "mensual" }> = [];
  const seen = new Set<number>();
  for (const raw of body.items) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return respond({ error: "Hay un producto con datos inválidos." }, 400, origin);
    const item = raw as Record<string, unknown>;
    const productId = Number(item.product_id);
    const quantity = Number(item.quantity);
    const frequency = item.frequency;
    if (!Number.isSafeInteger(productId) || productId <= 0 || !Number.isSafeInteger(quantity) || quantity < 1 || quantity > MAX_QUANTITY ||
        (frequency !== "quincenal" && frequency !== "mensual") || seen.has(productId)) {
      return respond({ error: "Revisá los productos, cantidades y planes elegidos." }, 400, origin);
    }
    seen.add(productId);
    requestedItems.push({ productId, quantity, frequency });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return respond({ error: "El formulario no está disponible en este momento." }, 503, origin);
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const ids = requestedItems.map(item => item.productId);
  const { data: products, error: productsError } = await admin.from("products")
    .select("id,name,subtitle,category,image_url,active,stock,q_count,q_price,m_count,m_price")
    .in("id", ids).eq("active", true);
  if (productsError) {
    console.error("No se pudieron validar los productos de la solicitud", productsError);
    return respond({ error: "No pudimos verificar los productos. Intentá nuevamente." }, 503, origin);
  }

  const productMap = new Map((products ?? []).map(product => [Number(product.id), product]));
  if (productMap.size !== requestedItems.length) return respond({ error: "Algún producto ya no está disponible. Actualizá la página y volvé a elegir." }, 409, origin);

  const snapshots: Record<string, unknown>[] = [];
  for (const item of requestedItems) {
    const product = productMap.get(item.productId)!;
    const publicStock = Number(product.stock);
    if (!Number.isFinite(publicStock) || publicStock === 0 || (publicStock > 0 && item.quantity > publicStock)) {
      return respond({ error: `El stock visible de «${String(product.name)}» cambió. Actualizá la página y revisá la cantidad.` }, 409, origin);
    }
    const count = Number(item.frequency === "quincenal" ? product.q_count : product.m_count);
    const price = moneyAmount(item.frequency === "quincenal" ? product.q_price : product.m_price);
    if (!Number.isSafeInteger(count) || count < 1 || !price) {
      return respond({ error: `El plan de pago elegido para «${String(product.name)}» ya no está disponible.` }, 409, origin);
    }
    const totalAmount = count * price * item.quantity;
    if (!Number.isSafeInteger(totalAmount)) return respond({ error: "El total de un producto excede el valor permitido." }, 409, origin);
    snapshots.push({
      product_id: item.productId,
      product_name: String(product.name ?? "Producto").slice(0, 200),
      category: String(product.category ?? "").slice(0, 80),
      image_url: String(product.image_url ?? "").slice(0, 1000),
      quantity: item.quantity,
      frequency: item.frequency,
      installment_count: count,
      installment_amount: price,
      total_amount: totalAmount,
    });
  }

  for (let attempt = 0; attempt < 2; attempt += 1) {
    const code = trackingCode();
    const { error } = await admin.from("customer_sale_requests").insert({
      tracking_code: code,
      full_name: fullName,
      phone,
      locality: locality ?? "",
      address: address ?? "",
      notes: notes ?? "",
      items: snapshots,
      privacy_accepted: true,
    });
    if (!error) return respond({ success: true, tracking_code: code }, 201, origin);
    if (error.code === "23505" && attempt === 0) continue;
    console.error("No se pudo guardar la solicitud de compra", error);
    return respond({ error: "No se pudo guardar la solicitud. Intentá nuevamente en unos minutos." }, 500, origin);
  }
  return respond({ error: "No se pudo guardar la solicitud. Intentá nuevamente." }, 500, origin);
});
