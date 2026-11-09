import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://electrovariety.github.io",
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  "http://localhost:5500",
  "http://127.0.0.1:5500",
]);
const BUCKET = "customer-sale-private";
const MAX_BODY_BYTES = 10_700_000;
const MAX_FILE_BYTES = 5 * 1024 * 1024;
const MAX_ITEMS = 10;
const MAX_QUANTITY = 10;
const proofServiceOptions = new Set(["edesur", "metrogas", "water", "other", "none_in_name"]);
const incomeOptions = new Set([
  "formal_job", "informal_job", "self_employed", "business", "allowance",
  "retirement", "pension", "cooperative", "other",
]);
const mimeExtensions: Record<string, string> = {
  "application/pdf": "pdf",
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
};
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

function phoneDigits(value: string): string {
  return value.replace(/\D/g, "");
}

function yesNo(value: FormDataEntryValue | null): boolean | null {
  if (value === "yes") return true;
  if (value === "no") return false;
  return null;
}

function stringChoices(form: FormData, name: string, allowed: Set<string>): string[] | null {
  const values = form.getAll(name);
  if (values.some(value => typeof value !== "string")) return null;
  const choices = [...new Set(values as string[])];
  if (choices.length !== values.length || choices.some(value => !allowed.has(value))) return null;
  return choices;
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

function isValidSignature(mime: string, bytes: Uint8Array): boolean {
  if (mime === "application/pdf") return new TextDecoder().decode(bytes.slice(0, 5)) === "%PDF-";
  if (mime === "image/jpeg") return bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  if (mime === "image/png") return [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((value, index) => bytes[index] === value);
  if (mime === "image/webp") {
    return new TextDecoder().decode(bytes.slice(0, 4)) === "RIFF" &&
      new TextDecoder().decode(bytes.slice(8, 12)) === "WEBP";
  }
  return false;
}

async function validateFile(value: FormDataEntryValue | null): Promise<{ file: File; bytes: Uint8Array } | null> {
  if (!(value instanceof File) || value.size < 1 || value.size > MAX_FILE_BYTES || !mimeExtensions[value.type]) return null;
  const bytes = new Uint8Array(await value.arrayBuffer());
  return isValidSignature(value.type, bytes) ? { file: value, bytes } : null;
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
  if (!(request.headers.get("content-type") ?? "").toLowerCase().includes("multipart/form-data")) {
    return respond({ error: "El formulario no tiene un formato válido." }, 415, origin);
  }
  const contentLength = Number(request.headers.get("content-length") ?? "0");
  if (contentLength > MAX_BODY_BYTES) return respond({ error: "La solicitud es demasiado extensa." }, 413, origin);

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return respond({ error: "No se pudieron leer los datos del formulario." }, 400, origin);
  }
  const textPayload = [...form.entries()].filter(([, value]) => typeof value === "string");
  if (new TextEncoder().encode(JSON.stringify(textPayload)).length > 80_000) {
    return respond({ error: "La solicitud es demasiado extensa." }, 413, origin);
  }
  if (cleanText(form.get("website"), 200)) return respond({ error: "No se pudo validar el formulario." }, 400, origin);

  const fullName = cleanText(form.get("full_name"), 120, true);
  const dniRaw = cleanText(form.get("dni"), 20, true);
  const dni = (dniRaw ?? "").replace(/[.\s-]/g, "").toUpperCase();
  const dniUpdated = yesNo(form.get("dni_updated"));
  const phone = phoneDigits(String(form.get("phone") ?? ""));
  const alternativePhone = phoneDigits(String(form.get("alternative_phone") ?? ""));
  const alternativeRelationship = cleanText(form.get("alternative_contact_relationship"), 100, true);
  const referredBy = yesNo(form.get("referred_by"));
  const isCustomer = yesNo(form.get("is_electro_variety_customer"));
  const locality = cleanText(form.get("locality"), 120, true);
  const street = cleanText(form.get("street"), 120, true);
  const streetNumber = cleanText(form.get("street_number"), 30, true);
  const betweenStreets = cleanText(form.get("between_streets"), 120, true);
  const housingSituation = form.get("housing_situation");
  const notes = cleanText(form.get("notes"), 1000);
  const hasDebts = yesNo(form.get("has_debts"));
  const privacyAccepted = form.get("privacy_accepted") === "true";
  const proofServices = stringChoices(form, "proof_services", proofServiceOptions);
  const incomeSources = stringChoices(form, "income_sources", incomeOptions);
  if (!fullName || !dniRaw || !/^[A-Z]?\d{7,8}$/.test(dni) || dniUpdated === null ||
      phone.length < 8 || phone.length > 20 || alternativePhone.length < 8 || alternativePhone.length > 20 ||
      !alternativeRelationship || referredBy === null || isCustomer === null || !locality || !street ||
      !streetNumber || !betweenStreets || !["own", "rent_contract", "rent_verbal"].includes(String(housingSituation)) ||
      hasDebts === null || notes === null || proofServices === null || proofServices.length < 1 || incomeSources === null ||
      (proofServices.includes("none_in_name") && proofServices.length > 1)) {
    return respond({ error: "Revisá los datos obligatorios, el DNI, teléfonos, domicilio y comprobantes." }, 400, origin);
  }
  if (!privacyAccepted) return respond({ error: "Aceptá el uso de tus datos y documentos para poder enviar la solicitud." }, 400, origin);

  const front = await validateFile(form.get("dni_front"));
  const back = await validateFile(form.get("dni_back"));
  if (!front || !back) return respond({ error: "Adjuntá el frente y el dorso del DNI en PDF, JPG, PNG o WebP (máximo 5 MB cada uno)." }, 400, origin);

  let rawItems: unknown;
  try {
    rawItems = JSON.parse(String(form.get("items") ?? ""));
  } catch {
    return respond({ error: "No pudimos leer los productos seleccionados." }, 400, origin);
  }
  if (!Array.isArray(rawItems) || rawItems.length < 1 || rawItems.length > MAX_ITEMS) {
    return respond({ error: `Elegí entre 1 y ${MAX_ITEMS} productos.` }, 400, origin);
  }
  const requestedItems: Array<{ productId: number; quantity: number; frequency: "quincenal" | "mensual" }> = [];
  const seen = new Set<number>();
  for (const raw of rawItems) {
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
    .select("id,name,category,image_url,active,stock,q_count,q_price,m_count,m_price")
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

  const requestId = crypto.randomUUID();
  const frontPath = `dni/${requestId}/front.${mimeExtensions[front.file.type]}`;
  const backPath = `dni/${requestId}/back.${mimeExtensions[back.file.type]}`;
  const uploadedPaths: string[] = [];
  const storage = admin.storage.from(BUCKET);
  try {
    for (const [path, file] of [[frontPath, front], [backPath, back]] as const) {
      const { error } = await storage.upload(path, file.bytes, {
        contentType: file.file.type,
        cacheControl: "0",
        upsert: false,
      });
      if (error) throw error;
      uploadedPaths.push(path);
    }

    const fullAddress = `${street} ${streetNumber}, entre ${betweenStreets}`.slice(0, 200);
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const code = trackingCode();
      const { error } = await admin.from("customer_sale_requests").insert({
        id: requestId,
        tracking_code: code,
        full_name: fullName,
        dni,
        dni_updated: dniUpdated,
        phone,
        alternative_phone: alternativePhone,
        alternative_contact_relationship: alternativeRelationship,
        referred_by: referredBy,
        is_electro_variety_customer: isCustomer,
        locality,
        address: fullAddress,
        street,
        street_number: streetNumber,
        between_streets: betweenStreets,
        housing_situation: String(housingSituation),
        proof_services: proofServices,
        has_debts: hasDebts,
        income_sources: incomeSources,
        dni_front_path: frontPath,
        dni_back_path: backPath,
        notes: notes ?? "",
        items: snapshots,
        privacy_accepted: true,
      });
      if (!error) return respond({ success: true, tracking_code: code }, 201, origin);
      if (error.code === "23505" && attempt === 0) continue;
      throw error;
    }
  } catch (error) {
    await storage.remove(uploadedPaths).catch(() => undefined);
    console.error("No se pudo guardar la solicitud de compra", error);
    return respond({ error: "No se pudo guardar la solicitud. Intentá nuevamente en unos minutos." }, 500, origin);
  }
  await storage.remove(uploadedPaths).catch(() => undefined);
  return respond({ error: "No se pudo guardar la solicitud. Intentá nuevamente." }, 500, origin);
});
