// ============================================================================
//  SLOT-BOOKING — EDGE FUNCTION "booking-email"
//  Invia le due email di conferma prenotazione (cliente + consulente) via
//  Brevo, al posto di EmailJS dal browser.
//
//  Anti-relay: dal client arriva SOLO la chiave della prenotazione
//  (calendar_id, data, ora) più il client_code come prova di possesso.
//  Destinatari e contenuti vengono riletti dal DB con la service key: chi
//  chiama non può scegliere né a chi scrivere né cosa scrivere.
//
//  Anti-doppio-invio: una colonna per destinatario
//  (booking_slots.email_cliente_inviata_at / email_consulente_inviata_at).
//  La colonna viene "prenotata" con un update condizionato (… is null)
//  PRIMA dell'invio, così due chiamate concorrenti non inviano due volte;
//  se l'invio a Brevo fallisce la colonna torna a null, così un nuovo
//  tentativo è possibile e lo stato in DB riflette ciò che è partito davvero.
//
//  Secret (mai nel codice): BREVO_API_KEY, BREVO_SENDER, più la service key
//  (SERVICE_KEY come in edge_consenso.ts, con fallback sulla variabile
//  SUPABASE_SERVICE_ROLE_KEY iniettata automaticamente da Supabase).
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const SENDER_NAME = "Fullylife Solutions";
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^\d{2}:\d{2}(:\d{2})?$/;

type Esito = "inviata" | "gia_inviata" | "assente" | "errore";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ errore: "Metodo non consentito." }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ errore: "Richiesta non valida." }, 400);
  }
  const { calendar_id, data, ora, client_code } = body as Record<string, string>;
  if (
    typeof calendar_id !== "string" || !UUID_RE.test(calendar_id) ||
    typeof data !== "string" || !DATE_RE.test(data) ||
    typeof ora !== "string" || !TIME_RE.test(ora) ||
    typeof client_code !== "string" || !client_code.trim()
  ) {
    return json({ errore: "Parametri mancanti o non validi." }, 400);
  }

  const brevoKey = Deno.env.get("BREVO_API_KEY");
  const brevoSender = Deno.env.get("BREVO_SENDER");
  const serviceKey = Deno.env.get("SERVICE_KEY") ?? Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!brevoKey || !brevoSender || !serviceKey) {
    console.error("booking-email: secret mancanti (BREVO_API_KEY / BREVO_SENDER / service key)");
    return json({ errore: "Servizio email non configurato." }, 500);
  }

  const supabase = createClient(Deno.env.get("SUPABASE_URL")!, serviceKey);

  // La prenotazione deve esistere E appartenere a chi presenta il client_code.
  // Nessuna distinzione tra "non esiste" e "codice sbagliato" nella risposta,
  // per non permettere di sondare quali slot sono prenotati.
  const { data: slot, error: slotError } = await supabase
    .from("booking_slots")
    .select(
      "id, data, ora, booker_nome, booker_cognome, booker_email, note, client_code, " +
        "email_cliente_inviata_at, email_consulente_inviata_at, " +
        "booking_calendars ( nome, duration_min, email_notifiche )",
    )
    .eq("calendar_id", calendar_id)
    .eq("data", data)
    .eq("ora", ora)
    .eq("booked", true)
    .eq("client_code", client_code.trim().toUpperCase())
    .maybeSingle();

  if (slotError) {
    console.error("booking-email: lettura prenotazione fallita:", slotError);
    return json({ errore: "Errore nella lettura della prenotazione." }, 500);
  }
  if (!slot) return json({ errore: "Prenotazione non trovata." }, 403);

  // deno-lint-ignore no-explicit-any
  const cal = (slot as any).booking_calendars as { nome: string; duration_min: number; email_notifiche: string | null } | null;
  if (!cal) {
    console.error("booking-email: calendario non trovato per slot", slot.id);
    return json({ errore: "Errore nella lettura della prenotazione." }, 500);
  }

  const [dy, dm, dd] = String(slot.data).split("-");
  const v = {
    company_name: cal.nome,
    booking_date: `${dd}/${dm}/${dy}`,
    booking_time: String(slot.ora).slice(0, 5),
    duration: String(cal.duration_min),
    booker_name: `${slot.booker_nome ?? ""} ${slot.booker_cognome ?? ""}`.trim(),
    ref_code: slot.client_code as string,
    booking_notes: (slot.note as string | null)?.trim() || "Nessuna nota",
  };

  const invia = (to: string, toName: string, subject: string, html: string) =>
    sendBrevo(brevoKey, brevoSender, to, toName, subject, html);

  const cliente = await inviaUnaVolta(
    supabase, slot.id, "email_cliente_inviata_at", slot.email_cliente_inviata_at, slot.booker_email,
    () => invia(slot.booker_email!, v.booker_name, `Prenotazione confermata — ${v.company_name}`, htmlCliente(v)),
  );
  const consulente = await inviaUnaVolta(
    supabase, slot.id, "email_consulente_inviata_at", slot.email_consulente_inviata_at, cal.email_notifiche,
    () => invia(cal.email_notifiche!, "Consulente", `Nuova prenotazione — ${v.booker_name} (${v.booking_date})`, htmlConsulente(v)),
  );

  const ok = cliente !== "errore" && consulente !== "errore";
  return json({ ok, cliente, consulente }, ok ? 200 : 502);
});

// Invia al più una volta per colonna: prenota la colonna (update condizionato
// su "is null"), invia, e in caso di errore la rilascia.
async function inviaUnaVolta(
  // deno-lint-ignore no-explicit-any
  supabase: any,
  slotId: string,
  colonna: "email_cliente_inviata_at" | "email_consulente_inviata_at",
  giaInviataAt: string | null,
  destinatario: string | null,
  send: () => Promise<void>,
): Promise<Esito> {
  if (!destinatario || !destinatario.includes("@")) return "assente";
  if (giaInviataAt) return "gia_inviata";

  const { data: claimed, error: claimError } = await supabase
    .from("booking_slots")
    .update({ [colonna]: new Date().toISOString() })
    .eq("id", slotId)
    .is(colonna, null)
    .select("id");
  if (claimError) {
    console.error(`booking-email: prenotazione colonna ${colonna} fallita:`, claimError);
    return "errore";
  }
  if (!claimed || claimed.length === 0) return "gia_inviata"; // un'altra chiamata concorrente l'ha già presa

  try {
    await send();
    return "inviata";
  } catch (e) {
    console.error(`booking-email: invio ${colonna} fallito per slot ${slotId}:`, (e as Error)?.message ?? e);
    const { error: releaseError } = await supabase
      .from("booking_slots")
      .update({ [colonna]: null })
      .eq("id", slotId);
    if (releaseError) {
      // Unico caso residuo di stato incoerente: segnato come inviato ma non partito.
      console.error(`booking-email: ATTENZIONE rilascio ${colonna} fallito per slot ${slotId} — mail NON inviata ma segnata come inviata:`, releaseError);
    }
    return "errore";
  }
}

async function sendBrevo(apiKey: string, sender: string, to: string, toName: string, subject: string, htmlContent: string) {
  const res = await fetch("https://api.brevo.com/v3/smtp/email", {
    method: "POST",
    headers: { "api-key": apiKey, "Content-Type": "application/json", "Accept": "application/json" },
    body: JSON.stringify({
      sender: { email: sender, name: SENDER_NAME },
      to: [{ email: to, name: toName }],
      subject,
      htmlContent,
    }),
  });
  if (!res.ok) throw new Error(`Brevo ${res.status}: ${await res.text()}`);
}

// ── Template ────────────────────────────────────────────────────────────────
// Tutti i valori passano da esc(): nome, cognome e note li scrive il
// prenotante nel form pubblico, non vanno mai interpolati come HTML grezzo.

type Vars = Record<"company_name" | "booking_date" | "booking_time" | "duration" | "booker_name" | "ref_code" | "booking_notes", string>;

function esc(s: string) {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

function righe(r: [string, string][]) {
  return r.map(([k, val]) =>
    `<tr><td style="padding:4px 16px 4px 0;color:#666;white-space:nowrap;vertical-align:top;">${esc(k)}</td>` +
    `<td style="padding:4px 0;color:#222;">${esc(val).replace(/\n/g, "<br>")}</td></tr>`
  ).join("");
}

function layout(inner: string) {
  return `<!DOCTYPE html><html lang="it"><body style="margin:0;padding:24px;background:#f5f5f7;font-family:Arial,Helvetica,sans-serif;font-size:15px;line-height:1.5;color:#222;">` +
    `<div style="max-width:560px;margin:0 auto;background:#fff;border-radius:8px;padding:28px;">${inner}</div></body></html>`;
}

function htmlCliente(v: Vars) {
  return layout(
    `<p style="margin:0 0 12px;">Gentile ${esc(v.booker_name)},</p>` +
    `<p style="margin:0 0 12px;">la tua prenotazione è confermata:</p>` +
    `<table style="border-collapse:collapse;margin:0 0 16px;">${righe([
      ["Azienda", v.company_name],
      ["Data", v.booking_date],
      ["Ora", v.booking_time],
      ["Durata", `${v.duration} minuti`],
    ])}</table>` +
    `<p style="margin:0 0 4px;">Il tuo codice di riferimento è: <strong style="font-family:monospace;font-size:16px;">${esc(v.ref_code)}</strong></p>` +
    `<p style="margin:0 0 20px;color:#555;">Conservalo — ti servirà se vuoi modificare o cancellare la prenotazione.</p>` +
    `<p style="margin:0;">A presto.<br>Team Fullylife Solutions</p>`,
  );
}

function htmlConsulente(v: Vars) {
  return layout(
    `<p style="margin:0 0 12px;">Nuova prenotazione ricevuta:</p>` +
    `<table style="border-collapse:collapse;">${righe([
      ["Cliente", v.booker_name],
      ["Azienda", v.company_name],
      ["Data", v.booking_date],
      ["Ora", v.booking_time],
      ["Durata", `${v.duration} minuti`],
      ["Codice", v.ref_code],
      ["Note del cliente", v.booking_notes],
    ])}</table>`,
  );
}

function json(payload: unknown, status: number) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
