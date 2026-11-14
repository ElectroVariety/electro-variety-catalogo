import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://electrovariety.github.io",
  "https://electrovariety.com",
  "https://www.electrovariety.com",
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  "http://localhost:5500",
  "http://127.0.0.1:5500",
]);
const BUCKET = "customer-sale-private";
const MAX_BODY_BYTES = 26_500_000;
const MAX_FILE_BYTES = 5 * 1024 * 1024;
const MAX_TOTAL_FILE_BYTES = 25 * 1024 * 1024;
const MAX_FILES = 12;
const proofServiceOptions = new Set(["edesur", "metrogas", "water", "other", "none_in_name"]);
const incomeOptions = new Set([
  "formal_job", "informal_job", "self_employed", "business", "allowance",
  "retirement", "pension", "cooperative", "other",
]);
const conditionalDetailOptions = new Set([
  "customer_only",
  "referrer_full_name", "referrer_phone", "referrer_relationship", "service_owner",
  "service_holder_name", "service_holder_dni", "service_holder_relationship",
  "debt_reason", "debt_amount", "occupation_formal", "occupation_informal", "wallet_provider",
  "self_employed_activity", "business_name", "business_activity", "business_address",
  "business_duration", "business_revenue", "business_profit", "other_income_description",
  "income_formal_job", "income_informal_job", "income_self_employed", "income_business",
  "income_allowance", "income_retirement", "income_pension", "income_cooperative", "income_other",
  "benefit_allowance", "benefit_retirement", "benefit_pension", "benefit_cooperative",
]);
const mimeExtensions: Record<string, string> = {
  "application/pdf": "pdf",
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "video/mp4": "mp4",
  "video/quicktime": "mov",
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

function strictMoneyAmount(value: unknown): number | null {
  const text = String(value ?? "").trim();
  if (!/^\d+$/.test(text) && !/^\d{1,3}(?:[.,]\d{3})+$/.test(text)) return null;
  const amount = Number(text.replace(/[.,]/g, ""));
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
  if (mime === "video/mp4" || mime === "video/quicktime") {
    return bytes.length >= 12 && new TextDecoder().decode(bytes.slice(4, 8)) === "ftyp";
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
  const customerOnly = isCustomer === true;
  let conditionalDetails: Record<string, string> = {};
  try {
    const rawDetails = JSON.parse(String(form.get("conditional_details") ?? "{}"));
    if (!rawDetails || typeof rawDetails !== "object" || Array.isArray(rawDetails)) throw new Error("invalid details");
    for (const [key, value] of Object.entries(rawDetails as Record<string, unknown>)) {
      if (!conditionalDetailOptions.has(key) || typeof value !== "string" || value.length > 500) throw new Error("invalid detail field");
      conditionalDetails[key] = value.trim();
    }
  } catch {
    return respond({ error: "No pudimos leer los datos condicionales del formulario." }, 400, origin);
  }
  if (!fullName || !dniRaw || !/^[A-Z]?\d{7,8}$/.test(dni) || isCustomer === null ||
      phone.length < 8 || phone.length > 20 || notes === null || proofServices === null || incomeSources === null ||
      (!customerOnly && (dniUpdated === null || alternativePhone.length < 8 || alternativePhone.length > 20 ||
        !alternativeRelationship || referredBy === null || !locality || !street || !streetNumber || !betweenStreets ||
        !["own", "rent_contract", "rent_verbal"].includes(String(housingSituation)) || hasDebts === null ||
        proofServices.length < 1 || incomeSources.length < 1 ||
        (proofServices.includes("none_in_name") && proofServices.length > 1))) ||
      (customerOnly && (proofServices.length > 0 || incomeSources.length > 0 ||
        conditionalDetails.customer_only !== "true" || Object.keys(conditionalDetails).length !== 1))) {
    return respond({ error: "Revisá los datos obligatorios, el DNI, teléfonos, domicilio y comprobantes." }, 400, origin);
  }
  const requiredDetails: string[] = [];
  const hasUtilityProof = proofServices.some(value => ["edesur", "metrogas", "water"].includes(value));
  const noNamedService = proofServices.includes("none_in_name");
  if (!customerOnly && referredBy) requiredDetails.push("referrer_full_name", "referrer_phone", "referrer_relationship");
  if (hasUtilityProof) requiredDetails.push("service_owner");
  if (!customerOnly && hasUtilityProof && !["yes", "no"].includes(conditionalDetails.service_owner ?? "")) {
    return respond({ error: "Indicá si el comprobante está a tu nombre." }, 400, origin);
  }
  if (!customerOnly && (noNamedService || conditionalDetails.service_owner === "no")) requiredDetails.push("service_holder_name", "service_holder_dni", "service_holder_relationship");
  if (!customerOnly && hasDebts) requiredDetails.push("debt_reason", "debt_amount");
  for (const source of customerOnly ? [] : incomeSources) {
    requiredDetails.push(`income_${source}`);
    if (source === "formal_job") requiredDetails.push("occupation_formal");
    if (source === "informal_job") requiredDetails.push("occupation_informal", "wallet_provider");
    if (source === "self_employed") requiredDetails.push("self_employed_activity");
    if (source === "business") requiredDetails.push("business_name", "business_activity", "business_address", "business_duration", "business_revenue", "business_profit");
    if (["allowance", "retirement", "pension", "cooperative"].includes(source)) requiredDetails.push(`benefit_${source}`);
    if (source === "other") requiredDetails.push("other_income_description");
  }
  if (requiredDetails.some(key => !conditionalDetails[key])) {
    return respond({ error: "Completá los datos adicionales que se desplegaron al elegir tus respuestas." }, 400, origin);
  }
  if (!customerOnly && conditionalDetails.service_holder_dni && !/^[A-Z]?\d{7,8}$/.test(conditionalDetails.service_holder_dni.replace(/[.\s-]/g, "").toUpperCase())) {
    return respond({ error: "Revisá el DNI de la persona titular del servicio." }, 400, origin);
  }
  const moneyDetailKeys = ["debt_amount", "business_revenue", "business_profit", ...(customerOnly ? [] : incomeSources.map(source => `income_${source}`))];
  if (moneyDetailKeys.some(key => conditionalDetails[key] && !strictMoneyAmount(conditionalDetails[key]))) {
    return respond({ error: "Revisá los montos ingresados; deben ser valores enteros mayores a cero." }, 400, origin);
  }
  if (!privacyAccepted) return respond({ error: "Aceptá el uso de tus datos y documentos para poder enviar la solicitud." }, 400, origin);

  const front = customerOnly ? null : await validateFile(form.get("dni_front"));
  const back = customerOnly ? null : await validateFile(form.get("dni_back"));
  if (!customerOnly && (!front || !back)) return respond({ error: "Adjuntá el frente y el dorso del DNI en PDF, JPG, PNG o WebP (máximo 5 MB cada uno)." }, 400, origin);
  if (customerOnly && [...form.entries()].some(([key, value]) =>
    (key === "dni_front" || key === "dni_back" || key.startsWith("attachment:")) && value instanceof File && value.size > 0
  )) return respond({ error: "Las solicitudes de clientes registrados no requieren adjuntos." }, 400, origin);
  const attachmentMimeTypes: Record<string, Set<string>> = {
    rental_contract: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    utility_bill: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    service_holder_dni_front: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    service_holder_dni_back: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    salary_receipt: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    wallet_statement: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    income_proof_self_employed: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    income_proof_allowance: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    income_proof_retirement: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    income_proof_pension: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    income_proof_cooperative: new Set(["application/pdf", "image/jpeg", "image/png", "image/webp"]),
    business_photos: new Set(["image/jpeg", "image/png", "image/webp"]),
    business_video: new Set(["video/mp4", "video/quicktime"]),
  };
  const requiredAttachments: string[] = [];
  if (!customerOnly && housingSituation === "rent_contract") requiredAttachments.push("rental_contract");
  if (!customerOnly && proofServices.length > 0) requiredAttachments.push("utility_bill");
  if (!customerOnly && (noNamedService || (hasUtilityProof && conditionalDetails.service_owner === "no"))) requiredAttachments.push("service_holder_dni_front", "service_holder_dni_back");
  if (!customerOnly && incomeSources.includes("formal_job")) requiredAttachments.push("salary_receipt");
  if (!customerOnly && incomeSources.includes("informal_job")) requiredAttachments.push("wallet_statement");
  if (!customerOnly && incomeSources.includes("self_employed")) requiredAttachments.push("income_proof_self_employed");
  if (!customerOnly && incomeSources.includes("business")) requiredAttachments.push("business_photos", "business_video");
  for (const source of ["allowance", "retirement", "pension", "cooperative"]) {
    if (!customerOnly && incomeSources.includes(source)) requiredAttachments.push(`income_proof_${source}`);
  }
  const attachmentFiles = new Map<string, Array<{ file: File; bytes: Uint8Array }>>();
  let totalFileBytes = (front?.file.size ?? 0) + (back?.file.size ?? 0);
  let totalFileCount = customerOnly ? 0 : 2;
  for (const [key, value] of form.entries()) {
    if (!key.startsWith("attachment:")) continue;
    const attachmentKey = key.slice("attachment:".length);
    const allowedTypes = attachmentMimeTypes[attachmentKey];
    if (!allowedTypes || !(value instanceof File) || !allowedTypes.has(value.type)) {
      return respond({ error: "Hay un adjunto con un formato no permitido." }, 400, origin);
    }
    const validated = await validateFile(value);
    if (!validated) return respond({ error: `El adjunto «${attachmentKey}» no se pudo validar o supera los 5 MB.` }, 400, origin);
    const values = attachmentFiles.get(attachmentKey) ?? [];
    if (values.length > 0 && attachmentKey !== "business_photos") {
      return respond({ error: "Se adjuntó más de un archivo en un campo individual." }, 400, origin);
    }
    values.push(validated);
    attachmentFiles.set(attachmentKey, values);
    totalFileBytes += value.size;
    totalFileCount += 1;
  }
  if (requiredAttachments.some(key => !attachmentFiles.has(key))) {
    return respond({ error: "Falta adjuntar uno o más documentos requeridos por las respuestas elegidas." }, 400, origin);
  }
  if (totalFileCount > MAX_FILES || totalFileBytes > MAX_TOTAL_FILE_BYTES) {
    return respond({ error: "Los adjuntos no pueden superar 12 archivos ni 25 MB en total." }, 413, origin);
  }

  let rawItems: unknown;
  try {
    rawItems = JSON.parse(String(form.get("items") ?? ""));
  } catch {
    return respond({ error: "No pudimos leer los productos seleccionados." }, 400, origin);
  }
  const unitLimit = customerOnly ? 3 : 1;
  if (!Array.isArray(rawItems) || rawItems.length < 1 || rawItems.length > unitLimit) {
    return respond({ error: `Esta solicitud permite elegir entre 1 y ${unitLimit} unidad${unitLimit === 1 ? "" : "es"}.` }, 400, origin);
  }
  const requestedItems: Array<{ productId: number; quantity: number; frequency: "quincenal" | "mensual" }> = [];
  const seen = new Set<number>();
  let totalUnits = 0;
  for (const raw of rawItems) {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return respond({ error: "Hay un producto con datos inválidos." }, 400, origin);
    const item = raw as Record<string, unknown>;
    const productId = Number(item.product_id);
    const quantity = Number(item.quantity);
    const frequency = item.frequency;
    if (!Number.isSafeInteger(productId) || productId <= 0 || !Number.isSafeInteger(quantity) || quantity < 1 || quantity > unitLimit ||
        (frequency !== "quincenal" && frequency !== "mensual") || seen.has(productId)) {
      return respond({ error: "Revisá los productos, cantidades y planes elegidos." }, 400, origin);
    }
    totalUnits += quantity;
    if (totalUnits > unitLimit) return respond({ error: `Esta solicitud permite elegir hasta ${unitLimit} unidad${unitLimit === 1 ? "" : "es"} en total.` }, 400, origin);
    seen.add(productId);
    requestedItems.push({ productId, quantity, frequency });
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceRoleKey) return respond({ error: "El formulario no está disponible en este momento." }, 503, origin);
  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const referralToken = String(form.get("referral_token") ?? "").trim();
  let sellerId: string | null = null;
  let sellerName = "";
  if (referralToken) {
    if (!/^(?:[0-9a-f-]{36}|\+?[0-9().\s-]{8,25})$/i.test(referralToken)) return respond({ error: "El enlace de vendedor no es válido." }, 400, origin);
    const { data: referralOwner, error: referralError } = await admin.rpc("resolve_customer_sale_referral_owner", { p_ref: referralToken });
    if (referralError || !referralOwner) return respond({ error: "El enlace de vendedor venció o ya no está disponible. Pedí uno nuevo." }, 400, origin);
    const { data: referral, error: linkError } = await admin.from("customer_sale_referral_links")
      .select("owner_id").eq("owner_id", referralOwner).gt("expires_at", new Date().toISOString()).maybeSingle();
    if (linkError || !referral) return respond({ error: "El enlace de vendedor venció o ya no está disponible. Pedí uno nuevo." }, 400, origin);
    sellerId = referral.owner_id;
    const [{ data: sellerProfile }, { data: staffProfile }, { data: stockProfile }, { data: verification }] = await Promise.all([
      admin.from("seller_profiles").select("name,active").eq("user_id", sellerId).maybeSingle(),
      admin.from("admin_profiles").select("display_name,role").eq("user_id", sellerId).maybeSingle(),
      admin.from("stock_profiles").select("name,active").eq("user_id", sellerId).maybeSingle(),
      admin.from("staff_sales_verifications").select("is_verified").eq("user_id", sellerId).maybeSingle(),
    ]);
    const isActiveSeller = sellerProfile?.active === true;
    const isAdmin = staffProfile?.role === "admin";
    const hasKnownActiveProfile = isActiveSeller || stockProfile?.active === true || ["supervisor", "custom"].includes(staffProfile?.role);
    if (!isAdmin && (verification?.is_verified !== true || !hasKnownActiveProfile)) {
      return respond({ error: "El enlace de ventas no está habilitado para esta cuenta. Pedí al administrador que otorgue la insignia de verificación." }, 400, origin);
    }
    sellerName = String(sellerProfile?.name || staffProfile?.display_name || "").trim().slice(0, 120);
  }
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
  const frontPath = front ? `dni/${requestId}/front.${mimeExtensions[front.file.type]}` : null;
  const backPath = back ? `dni/${requestId}/back.${mimeExtensions[back.file.type]}` : null;
  const uploadedPaths: string[] = [];
  const documentPaths: Record<string, string | string[]> = {};
  const storage = admin.storage.from(BUCKET);
  try {
    if (front && back && frontPath && backPath) {
      for (const [path, file] of [[frontPath, front], [backPath, back]] as const) {
        const { error } = await storage.upload(path, file.bytes, {
          contentType: file.file.type,
          cacheControl: "0",
          upsert: false,
        });
        if (error) throw error;
        uploadedPaths.push(path);
      }
      documentPaths.dni_front = frontPath;
      documentPaths.dni_back = backPath;
    }
    for (const [key, files] of attachmentFiles) {
      const paths: string[] = [];
      for (const [index, file] of files.entries()) {
        const suffix = files.length > 1 ? `-${index + 1}` : "";
        const path = `sale-requests/${requestId}/${key}${suffix}.${mimeExtensions[file.file.type]}`;
        const { error } = await storage.upload(path, file.bytes, {
          contentType: file.file.type,
          cacheControl: "0",
          upsert: false,
        });
        if (error) throw error;
        uploadedPaths.push(path);
        paths.push(path);
      }
      documentPaths[key] = paths.length === 1 ? paths[0] : paths;
    }

    const fullAddress = customerOnly ? "" : `${street} ${streetNumber}, entre ${betweenStreets}`.slice(0, 200);
    for (let attempt = 0; attempt < 2; attempt += 1) {
      const code = trackingCode();
      const { error } = await admin.from("customer_sale_requests").insert({
        id: requestId,
        seller_id: sellerId,
        seller_name: sellerName,
        tracking_code: code,
        full_name: fullName,
        dni,
        dni_updated: customerOnly ? false : dniUpdated,
        phone,
        alternative_phone: customerOnly ? "" : alternativePhone,
        alternative_contact_relationship: customerOnly ? "" : alternativeRelationship,
        referred_by: customerOnly ? false : referredBy,
        is_electro_variety_customer: isCustomer,
        locality: customerOnly ? "" : locality,
        address: fullAddress,
        street: customerOnly ? "" : street,
        street_number: customerOnly ? "" : streetNumber,
        between_streets: customerOnly ? "" : betweenStreets,
        housing_situation: customerOnly ? "" : String(housingSituation),
        proof_services: customerOnly ? [] : proofServices,
        has_debts: customerOnly ? false : hasDebts,
        income_sources: customerOnly ? [] : incomeSources,
        dni_front_path: frontPath,
        dni_back_path: backPath,
        conditional_details: conditionalDetails,
        document_paths: documentPaths,
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
