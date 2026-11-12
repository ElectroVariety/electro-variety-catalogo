(function () {
  const { PDFDocument, StandardFonts, rgb } = window.PDFLib || {};
  const PAGE_WIDTH = 595.28, PAGE_HEIGHT = 841.89, MARGIN = 38;
  const GRAPHITE = rgb(.145, .169, .208), BLUE = rgb(0, .435, .776);
  const PALE_BLUE = rgb(.906, .953, 1), SILVER = rgb(.72, .765, .82), MUTED = rgb(.37, .41, .47), WHITE = rgb(1, 1, 1);
  const labels = {
    dni_front: "Frente del DNI", dni_front_path: "Frente del DNI", dni_back: "Dorso del DNI", dni_back_path: "Dorso del DNI",
    service_holder_dni_front: "Frente del DNI del titular del servicio", service_holder_dni_back: "Dorso del DNI del titular del servicio",
    proof_other: "Otro comprobante", service_proof: "Comprobante de domicilio", utility_bill: "Comprobante de domicilio", income_proof: "Comprobante de ingresos",
    rental_contract: "Contrato de alquiler", wallet_statement: "Resumen de billetera virtual", salary_receipt: "Recibo de sueldo",
    income_proof_self_employed: "Comprobante de ingresos · trabajo independiente", income_proof_allowance: "Comprobante de ingresos · asignación", income_proof_retirement: "Comprobante de ingresos · jubilación", income_proof_pension: "Comprobante de ingresos · pensión", income_proof_cooperative: "Comprobante de ingresos · cooperativa",
    business_photo: "Foto del comercio", business_photos: "Fotos del comercio", business_video: "Video del comercio",
  };
  const housingLabels = { own: "Vivienda propia", rent_contract: "Alquilo por contrato", rent_verbal: "Alquilo de palabra" };
  const serviceLabels = { edesur: "Edesur", metrogas: "Metrogas", water: "Agua", other: "Otro", none_in_name: "Ninguno a mi nombre" };
  const incomeLabels = { formal_job: "Trabajo en blanco", informal_job: "Trabajo en negro", self_employed: "Trabajo por cuenta propia", business: "Tengo un comercio", allowance: "Cobro una asignación", retirement: "Cobro una jubilación", pension: "Cobro una pensión", cooperative: "Cobro de una cooperativa", other: "Otros ingresos" };
  const statusLabels = { pending: "Pendiente", contacted: "Contactado", converted: "Venta confirmada", cancelled: "Cancelada", approved: "Aprobada", rejected: "Rechazada" };
  const clean = value => String(value ?? "—").replace(/[\u0000-\u001f]/g, " ").replace(/—/g, "-").replace(/[^\u0000-\u00ff]/g, "?").trim() || "—";
  const amountValue = value => {
    if (typeof value === "number") return Number.isSafeInteger(value) && value >= 0 ? value : 0;
    const digits = String(value ?? "").replace(/\D/g, "");
    const amount = Number(digits);
    return Number.isSafeInteger(amount) ? amount : 0;
  };
  const money = value => "$ " + new Intl.NumberFormat("es-AR", { maximumFractionDigits: 0 }).format(amountValue(value));
  const formatDni = value => {
    const normalized = String(value ?? "").trim().replace(/[.\s-]/g, "").toUpperCase();
    const match = normalized.match(/^([A-Z]?)(\d{7,8})$/);
    if (!match) return clean(value);
    const [, prefix, digits] = match;
    return prefix + digits.replace(/\B(?=(\d{3})+(?!\d))/g, ".");
  };
  const yesNo = value => value === true ? "Sí" : value === false ? "No" : "No informado";
  const wrap = (value, font, size, width) => {
    const lines = [];
    for (const paragraph of clean(value).split(/\r?\n/)) {
      let line = "";
      for (const word of paragraph.split(/\s+/).filter(Boolean)) {
        const next = line ? `${line} ${word}` : word;
        if (line && font.widthOfTextAtSize(next, size) > width) { lines.push(line); line = word; }
        else line = next;
      }
      lines.push(line || " ");
    }
    return lines;
  };
  const pretty = value => clean(value).replaceAll("_", " ");
  const docPaths = request => {
    const all = { ...(request.document_paths && typeof request.document_paths === "object" ? request.document_paths : {}) };
    if (request.dni_front_path) all.dni_front_path = request.dni_front_path;
    if (request.dni_back_path) all.dni_back_path = request.dni_back_path;
    const seen = new Set();
    return Object.entries(all).flatMap(([key, value]) => (Array.isArray(value) ? value : [value]).filter(path => typeof path === "string" && path && !seen.has(path) && seen.add(path)).map((path, index) => ({ key, path, index })));
  };
  const formatDate = value => value ? new Date(value).toLocaleString("es-AR") : "—";

  async function drawApplication(pdf, request, attachments) {
    const regular = pdf.__regular, bold = pdf.__bold;
    let page, y = 0;
    const draw = (text, x, baseline, size, font = regular, color = GRAPHITE, maxWidth = PAGE_WIDTH - x - MARGIN) => page.drawText(clean(text), { x, y: baseline, size, font, color, maxWidth });
    const newPage = (cover = false) => {
      page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
      page.drawRectangle({ x: 0, y: 0, width: PAGE_WIDTH, height: PAGE_HEIGHT, color: WHITE });
      if (cover) {
        page.drawCircle({ x: MARGIN + 29, y: PAGE_HEIGHT - 62, size: 28, borderColor: BLUE, borderWidth: 1.5, color: WHITE });
        page.drawText("EV", { x: MARGIN + 14, y: PAGE_HEIGHT - 68, size: 15, font: bold, color: BLUE });
        draw("ELECTRO VARIETY", MARGIN + 70, PAGE_HEIGHT - 52, 12, bold);
        draw("SOLICITUDES DE COMPRA", MARGIN + 70, PAGE_HEIGHT - 69, 8, regular, MUTED);
        const heroY = PAGE_HEIGHT - 195;
        page.drawRectangle({ x: MARGIN, y: heroY, width: PAGE_WIDTH - MARGIN * 2, height: 92, color: GRAPHITE });
        page.drawRectangle({ x: PAGE_WIDTH - MARGIN - 8, y: heroY, width: 8, height: 92, color: BLUE });
        draw(`SOLICITUD DE COMPRA | ${statusLabels[request.status] || request.status || "Pendiente"}`, MARGIN + 17, heroY + 71, 8, bold, rgb(.61, .83, 1));
        draw("Solicitud de compra", MARGIN + 17, heroY + 47, 20, bold, WHITE);
        draw(request.full_name, MARGIN + 17, heroY + 28, 12, bold, WHITE);
        draw(`Solicitud #${request.tracking_code || String(request.id || "").slice(0, 8)} | ${formatDate(request.created_at)}`, MARGIN + 17, heroY + 12, 7.5, regular, WHITE);
        y = heroY - 24;
      } else {
        draw(`ELECTRO VARIETY | ${request.full_name || "Solicitud de compra"}`, MARGIN, PAGE_HEIGHT - 27, 8, bold, MUTED);
        page.drawLine({ start: { x: MARGIN, y: PAGE_HEIGHT - 34 }, end: { x: PAGE_WIDTH - MARGIN, y: PAGE_HEIGHT - 34 }, thickness: .6, color: SILVER });
        y = PAGE_HEIGHT - 51;
      }
      return page;
    };
    newPage(true);
    const ensureRoom = height => { if (y - height < 38) newPage(); };
    const drawFields = fields => {
      const gap = 10, fieldWidth = (PAGE_WIDTH - MARGIN * 2 - gap) / 2;
      for (let index = 0; index < fields.length; index += 2) {
        const row = fields.slice(index, index + 2).map(([label, value]) => ({ label: clean(label), lines: wrap(value, bold, 9.2, fieldWidth - 20) }));
        const rowHeight = Math.max(40, ...row.map(item => 20 + item.lines.length * 12));
        ensureRoom(rowHeight + 7);
        row.forEach((item, column) => {
          const x = MARGIN + column * (fieldWidth + gap);
          page.drawRectangle({ x, y: y - rowHeight, width: fieldWidth, height: rowHeight, color: WHITE, borderColor: SILVER, borderWidth: .6 });
          page.drawText(item.label, { x: x + 9, y: y - 13, size: 7.5, font: regular, color: MUTED, maxWidth: fieldWidth - 18 });
          item.lines.forEach((line, lineIndex) => page.drawText(line, { x: x + 9, y: y - 27 - lineIndex * 12, size: 9.2, font: bold, color: GRAPHITE, maxWidth: fieldWidth - 18 }));
        });
        y -= rowHeight + 7;
      }
    };
    const drawSection = (number, title, fields) => {
      ensureRoom(50); y -= 7;
      page.drawRectangle({ x: MARGIN, y: y - 19, width: 24, height: 24, color: PALE_BLUE });
      page.drawText(number, { x: MARGIN + 3, y: y - 11, size: 7.5, font: bold, color: BLUE });
      page.drawText(clean(title), { x: MARGIN + 33, y: y - 11, size: 12, font: bold, color: GRAPHITE });
      y -= 31; drawFields(fields);
    };
    const identity = attachments.filter(file => ["dni_front", "dni_front_path", "dni_back", "dni_back_path"].includes(file.key));
    if (identity.length) {
      const identityPage = newPage();
      identityPage.drawText("FRENTE Y DORSO DE TU DNI", { x: MARGIN, y: PAGE_HEIGHT - 52, size: 13, font: bold, color: GRAPHITE });
      const top = PAGE_HEIGHT - 72, bottom = 34, rowHeight = (top - bottom) / identity.length, imageWidth = PAGE_WIDTH - MARGIN * 2;
      for (const [index, file] of identity.entries()) {
        const label = labels[file.key] || pretty(file.key), bytes = new Uint8Array(await file.blob.arrayBuffer()), name = file.name.toLowerCase(), rowTop = top - index * rowHeight;
        if (name.endsWith(".pdf")) {
          const cover = addPdfCover(pdf, { ...file, requestName: request.full_name }, label, regular, bold);
          try { const source = await PDFDocument.load(bytes); (await pdf.copyPages(source, source.getPageIndices())).forEach(sourcePage => pdf.addPage(sourcePage)); }
          catch { cover.drawText("No se pudo representar este documento PDF.", { x: MARGIN + 16, y: PAGE_HEIGHT - 130, size: 8, font: regular, color: MUTED, maxWidth: imageWidth - 32 }); }
          continue;
        }
        try {
          const mime = name.endsWith(".png") ? "image/png" : name.endsWith(".webp") ? "image/webp" : "image/jpeg";
          const converted = await imageJpeg(bytes, mime, true), image = await pdf.embedJpg(converted.bytes);
          identityPage.drawText(clean(label), { x: MARGIN, y: rowTop - 8, size: 10, font: bold, color: BLUE, maxWidth: imageWidth });
          const maxHeight = rowHeight - 18, scale = Math.min(imageWidth / image.width, maxHeight / image.height), width = image.width * scale, height = image.height * scale;
          identityPage.drawImage(image, { x: (PAGE_WIDTH - width) / 2, y: rowTop - 18 - height, width, height });
        } catch {
          identityPage.drawText(clean(label), { x: MARGIN, y: rowTop - 8, size: 9, font: bold, color: GRAPHITE, maxWidth: imageWidth });
          identityPage.drawText("No se pudo incorporar una vista previa.", { x: MARGIN, y: rowTop - 26, size: 8, font: regular, color: MUTED, maxWidth: imageWidth });
        }
      }
      newPage();
    }
    const conditional = request.conditional_details && typeof request.conditional_details === "object" ? request.conditional_details : {};
    const proofServices = Array.isArray(request.proof_services) ? request.proof_services : [];
    const incomes = Array.isArray(request.income_sources) ? request.income_sources : [];
    const items = Array.isArray(request.items) ? request.items : [];
    const customerOnly = conditional.customer_only === "true" || request.is_electro_variety_customer === true;
    const itemFields = items.flatMap((item, index) => [[`Producto ${index + 1}`, item.product_name], ["Cantidad", `${Number(item.quantity) || 0} unidad(es)`], ["Cuotas", `${Number(item.installment_count) || 0} ${item.frequency === "quincenal" ? "quincenales" : "mensuales"}`], ["Valor de cada cuota", money(item.installment_amount)]]);
    drawSection("01", "Tu compra", itemFields.length ? itemFields : [["Productos solicitados", "Sin productos informados"]]);
    drawSection("02", "Datos personales", [
      ["Nombre y apellido", request.full_name], ["DNI", formatDni(request.dni)],
      ...(!customerOnly ? [["DNI actualizado", yesNo(request.dni_updated)], ["Teléfono personal", request.phone], ["Teléfono alternativo", request.alternative_phone], ["Vínculo con el contacto alternativo", request.alternative_contact_relationship], ["Vino recomendado por alguien", yesNo(request.referred_by)], ["Es cliente de Electro Variety", yesNo(request.is_electro_variety_customer)]] : [["Teléfono personal", request.phone]]),
      ...Object.entries(conditional).filter(([key, value]) => ["referrer_full_name", "referrer_phone", "referrer_relationship"].includes(key) && String(value || "").trim()).map(([key, value]) => [({ referrer_full_name: "Nombre de quien recomendó", referrer_phone: "Teléfono de quien recomendó", referrer_relationship: "Vínculo con quien recomendó" })[key], value]),
    ]);
    if (!customerOnly) {
      drawSection("03", "Domicilio", [["Calle y número", [request.street, request.street_number].filter(Boolean).join(" ") || request.address], ["Entre calles", request.between_streets], ["Localidad", request.locality], ["Situación de vivienda", housingLabels[request.housing_situation] || request.housing_situation]]);
      drawSection("04", "Comprobante de domicilio", [
        ["Servicios o comprobantes declarados", proofServices.map(service => serviceLabels[service] || service).join(", ") || "Ninguno informado"],
        ...(proofServices.some(service => ["edesur", "metrogas", "water"].includes(service)) ? [["Servicio a nombre de la persona", conditional.service_owner === "yes" ? "Sí" : conditional.service_owner === "no" ? "No" : "No informado"]] : []),
        ...[["Nombre del titular", "service_holder_name"], ["DNI del titular", "service_holder_dni"], ["Vínculo con el titular", "service_holder_relationship"]].filter(([, key]) => conditional[key]).map(([label, key]) => [label, key === "service_holder_dni" ? formatDni(conditional[key]) : conditional[key]]),
      ]);
      drawSection("05", "Situación financiera", [["Tiene deudas actualmente", yesNo(request.has_debts)], ...(request.has_debts ? [["Motivo de la deuda", conditional.debt_reason], ["Monto aproximado de la deuda", money(conditional.debt_amount)]] : [])]);
      ensureRoom(55); y -= 7;
      page.drawRectangle({ x: MARGIN, y: y - 19, width: 24, height: 24, color: PALE_BLUE });
      page.drawText("06", { x: MARGIN + 3, y: y - 11, size: 7.5, font: bold, color: BLUE });
      page.drawText("Trabajo e ingresos", { x: MARGIN + 33, y: y - 11, size: 12, font: bold, color: GRAPHITE }); y -= 31;
      if (!incomes.length) drawFields([["Fuentes de ingreso", "Sin datos de ingresos"]]);
      const incomeDetailKeys = {
        formal_job: ["income_formal_job", "occupation_formal"],
        informal_job: ["income_informal_job", "occupation_informal", "wallet_provider"],
        self_employed: ["income_self_employed", "self_employed_activity"],
        business: ["income_business", "business_name", "business_activity", "business_address", "business_duration", "business_revenue", "business_profit"],
        allowance: ["income_allowance", "benefit_allowance"],
        retirement: ["income_retirement", "benefit_retirement"],
        pension: ["income_pension", "benefit_pension"],
        cooperative: ["income_cooperative", "benefit_cooperative"],
        other: ["income_other", "other_income_description"],
      };
      const detailLabels = { occupation_formal: "Ocupación / actividad", occupation_informal: "Ocupación / actividad", wallet_provider: "Billetera virtual utilizada", self_employed_activity: "Actividad independiente", business_name: "Nombre del comercio", business_activity: "Actividad comercial", business_address: "Dirección del comercio", business_duration: "Antigüedad del comercio", business_revenue: "Facturación mensual aproximada", business_profit: "Ganancia mensual aproximada", other_income_description: "Descripción de otros ingresos", benefit_allowance: "Beneficio o institución", benefit_retirement: "Beneficio o institución", benefit_pension: "Beneficio o institución", benefit_cooperative: "Beneficio o institución" };
      for (const source of incomes) {
        const label = incomeLabels[source] || pretty(source), details = (incomeDetailKeys[source] || [`income_${source}`]).filter(key => String(conditional[key] || "").trim()).map(key => [detailLabels[key] || (key.startsWith("income_") ? "Ingreso mensual aproximado" : pretty(key)), ["income_formal_job", "income_informal_job", "income_self_employed", "income_business", "income_allowance", "income_retirement", "income_pension", "income_cooperative", "income_other", "business_revenue", "business_profit"].includes(key) ? money(conditional[key]) : conditional[key]]);
        ensureRoom(55); page.drawText(clean(label), { x: MARGIN, y, size: 9, font: bold, color: BLUE }); y -= 9;
        drawFields(details.length ? details : [["Información declarada", "Ver formulario de solicitud"]]); y -= 6;
      }
    }
    drawSection(customerOnly ? "03" : "07", "Consentimientos", [["Tratamiento de datos", request.privacy_accepted === true ? "Aceptado" : "No informado"], ["Datos usados para responder la solicitud", request.privacy_accepted === true ? "Aceptado" : "No informado"]]);
    if (request.notes) drawSection(customerOnly ? "04" : "08", "Comentario para el equipo", [["Comentario", request.notes]]);
    if (request.seller_name) drawFields([["Vendedor/a", request.seller_name], ["Código de seguimiento", request.tracking_code]]);

  }

  function addPdfCover(pdf, file, label, regular, bold) {
    const cover = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
    cover.drawRectangle({ x: 0, y: 0, width: PAGE_WIDTH, height: PAGE_HEIGHT, color: WHITE });
    cover.drawText(clean(`ELECTRO VARIETY | ${file.requestName || "Solicitud de compra"}`), { x: MARGIN, y: PAGE_HEIGHT - 27, size: 8, font: bold, color: MUTED });
    cover.drawLine({ start: { x: MARGIN, y: PAGE_HEIGHT - 34 }, end: { x: PAGE_WIDTH - MARGIN, y: PAGE_HEIGHT - 34 }, thickness: .6, color: SILVER });
    cover.drawRectangle({ x: MARGIN, y: PAGE_HEIGHT - 150, width: PAGE_WIDTH - MARGIN * 2, height: 92, color: PALE_BLUE, borderColor: SILVER, borderWidth: .8 });
    cover.drawText(clean(label), { x: MARGIN + 16, y: PAGE_HEIGHT - 83, size: 13, font: bold, color: GRAPHITE, maxWidth: PAGE_WIDTH - MARGIN * 2 - 32 });
    cover.drawText(clean(file.name), { x: MARGIN + 16, y: PAGE_HEIGHT - 108, size: 9, font: regular, color: MUTED, maxWidth: PAGE_WIDTH - MARGIN * 2 - 32 });
    return cover;
  }
  async function imageJpeg(bytes, mime, rotate = false) {
    const bitmap = await createImageBitmap(new Blob([bytes], { type: mime }), { imageOrientation: "from-image" });
    const turn = rotate && bitmap.height > bitmap.width, canvas = document.createElement("canvas");
    canvas.width = turn ? bitmap.height : bitmap.width; canvas.height = turn ? bitmap.width : bitmap.height;
    const context = canvas.getContext("2d"); if (!context) throw new Error("No se pudo procesar una imagen adjunta.");
    context.fillStyle = "#fff"; context.fillRect(0, 0, canvas.width, canvas.height);
    if (turn) { context.translate(canvas.width / 2, canvas.height / 2); context.rotate(-Math.PI / 2); context.drawImage(bitmap, -bitmap.width / 2, -bitmap.height / 2); }
    else context.drawImage(bitmap, 0, 0);
    bitmap.close(); const blob = await new Promise((resolve, reject) => canvas.toBlob(result => result ? resolve(result) : reject(new Error("No se pudo convertir una imagen adjunta.")), "image/jpeg", .9));
    return { bytes: new Uint8Array(await blob.arrayBuffer()), width: canvas.width, height: canvas.height };
  }
  async function videoFrame(bytes, mime) {
    const url = URL.createObjectURL(new Blob([bytes], { type: mime }));
    try {
      const video = document.createElement("video"); video.muted = true; video.playsInline = true; video.preload = "metadata"; video.src = url;
      await new Promise((resolve, reject) => { video.onloadeddata = resolve; video.onerror = () => reject(new Error("No se pudo leer el video adjunto.")); setTimeout(() => reject(new Error("Se agotó el tiempo de espera del video.")), 10000); });
      const canvas = document.createElement("canvas"); canvas.width = video.videoWidth || 640; canvas.height = video.videoHeight || 360;
      canvas.getContext("2d").drawImage(video, 0, 0);
      const image = await new Promise(resolve => canvas.toBlob(resolve, "image/jpeg", .88));
      return new Uint8Array(await image.arrayBuffer());
    } finally { URL.revokeObjectURL(url); }
  }
  function attachmentPage(pdf, title, filename, regular, bold) {
    const page = pdf.addPage([PAGE_WIDTH, PAGE_HEIGHT]);
    page.drawRectangle({ x: 0, y: 0, width: PAGE_WIDTH, height: PAGE_HEIGHT, color: WHITE });
    page.drawText("ELECTRO VARIETY | Solicitud de compra", { x: MARGIN, y: PAGE_HEIGHT - 27, size: 8, font: bold, color: MUTED });
    page.drawLine({ start: { x: MARGIN, y: PAGE_HEIGHT - 34 }, end: { x: PAGE_WIDTH - MARGIN, y: PAGE_HEIGHT - 34 }, thickness: .6, color: SILVER });
    page.drawText(clean(title), { x: MARGIN, y: PAGE_HEIGHT - 60, size: 13, font: bold, color: GRAPHITE, maxWidth: PAGE_WIDTH - MARGIN * 2 });
    page.drawText(clean(filename), { x: MARGIN, y: PAGE_HEIGHT - 77, size: 8, font: regular, color: MUTED, maxWidth: PAGE_WIDTH - MARGIN * 2 });
    return page;
  }
  async function appendAttachment(pdf, file, regular, bold) {
    const bytes = new Uint8Array(await file.blob.arrayBuffer()), lower = file.name.toLowerCase(), label = labels[file.key] || pretty(file.key);
    const mime = file.blob.type || (lower.endsWith(".pdf") ? "application/pdf" : lower.endsWith(".png") ? "image/png" : lower.endsWith(".webp") ? "image/webp" : lower.endsWith(".mp4") ? "video/mp4" : lower.endsWith(".mov") ? "video/quicktime" : "image/jpeg");
    if (mime === "application/pdf" || lower.endsWith(".pdf")) {
      const cover = addPdfCover(pdf, { ...file, requestName: file.requestName }, label, regular, bold);
      try { const source = await PDFDocument.load(bytes); (await pdf.copyPages(source, source.getPageIndices())).forEach(page => pdf.addPage(page)); }
      catch { cover.drawText("No se pudo representar este documento PDF.", { x: MARGIN + 16, y: PAGE_HEIGHT - 130, size: 8, font: regular, color: MUTED, maxWidth: PAGE_WIDTH - MARGIN * 2 - 32 }); }
      return;
    }
    if (mime.startsWith("video/")) {
      const cover = addPdfCover(pdf, file, label, regular, bold);
      try {
        const preview = await videoFrame(bytes, mime), image = await pdf.embedJpg(preview), scale = Math.min((PAGE_WIDTH - MARGIN * 2) / image.width, (PAGE_HEIGHT - 260) / image.height);
        cover.drawImage(image, { x: (PAGE_WIDTH - image.width * scale) / 2, y: PAGE_HEIGHT - 170 - image.height * scale, width: image.width * scale, height: image.height * scale });
        cover.drawText("Vista previa. Se muestra el primer fotograma del video.", { x: MARGIN, y: 45, size: 8, font: regular, color: MUTED });
      } catch { cover.drawText("No se pudo generar una vista previa del video.", { x: MARGIN + 16, y: PAGE_HEIGHT - 130, size: 9, font: regular, color: MUTED, maxWidth: PAGE_WIDTH - MARGIN * 2 - 32 }); }
      return;
    }
    try {
      let image, imageWidth, imageHeight;
      if (mime === "image/png") { image = await pdf.embedPng(bytes); imageWidth = image.width; imageHeight = image.height; }
      else { const converted = await imageJpeg(bytes, mime); image = await pdf.embedJpg(converted.bytes); imageWidth = converted.width; imageHeight = converted.height; }
      const page = attachmentPage(pdf, label, file.name, regular, bold), maxWidth = PAGE_WIDTH - MARGIN * 2, maxHeight = PAGE_HEIGHT - 145, scale = Math.min(maxWidth / imageWidth, maxHeight / imageHeight);
      page.drawImage(image, { x: (PAGE_WIDTH - imageWidth * scale) / 2, y: Math.max(40, (PAGE_HEIGHT - imageHeight * scale) / 2 - 20), width: imageWidth * scale, height: imageHeight * scale });
    } catch {
      const page = attachmentPage(pdf, label, file.name, regular, bold);
      page.drawText("No se pudo incorporar la vista previa del archivo.", { x: MARGIN, y: PAGE_HEIGHT - 100, size: 9, font: regular, color: MUTED });
    }
  }

  async function create(request, db) {
    if (!PDFDocument) throw new Error("No se pudo cargar el generador de PDF. Actualizá la página e intentá otra vez.");
    const pdf = await PDFDocument.create();
    pdf.setTitle(`Solicitud de compra ${request.tracking_code || ""}`); pdf.setAuthor("Electro Variety"); pdf.setSubject(`Solicitud ${request.tracking_code || request.id || ""}`);
    pdf.__regular = await pdf.embedFont(StandardFonts.Helvetica); pdf.__bold = await pdf.embedFont(StandardFonts.HelveticaBold);
    const files = [];
    for (const item of docPaths(request)) {
      const { data, error } = await db.storage.from("customer-sale-private").download(item.path);
      if (error || !data) throw new Error(`No se pudo incluir el archivo adjunto ${pretty(item.key)}. Revisá el acceso e intentá nuevamente.`);
      files.push({ ...item, blob: data, name: item.path.split("/").pop() || labels[item.key] || "archivo", requestName: request.full_name });
    }
    await drawApplication(pdf, request, files);
    const regular = pdf.__regular, bold = pdf.__bold;
    for (const file of files.filter(item => !["dni_front", "dni_front_path", "dni_back", "dni_back_path"].includes(item.key))) await appendAttachment(pdf, file, regular, bold);
    const pages = pdf.getPages();
    pages.forEach((current, index) => { const { width } = current.getSize(); current.drawText(`${index + 1} / ${pages.length}`, { x: width - MARGIN - 35, y: 20, size: 7, font: regular, color: MUTED }); });
    return new Blob([await pdf.save()], { type: "application/pdf" });
  }
  async function open(request, db) {
    const win = window.open("about:blank", "_blank");
    if (!win) throw new Error("Permití ventanas emergentes para abrir el PDF.");
    win.opener = null; win.document.write("<!doctype html><title>Preparando PDF...</title><p style='font:16px Arial;padding:24px'>Preparando la solicitud y sus archivos adjuntos...</p>");
    try { const blob = await create(request, db); win.location.href = URL.createObjectURL(blob); }
    catch (error) { win.close(); throw error; }
  }
  window.EVCustomerSalePdf = { create, open };
})();
