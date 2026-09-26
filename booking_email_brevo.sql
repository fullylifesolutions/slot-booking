-- ============================================================================
-- Slot-booking — anti-doppio-invio per la Edge Function "booking-email" (Brevo)
-- Da applicare PRIMA su TEST, poi su PROD. Idempotente (rieseguibile).
--
-- Una colonna per destinatario: se l'invio al cliente riesce e quello al
-- consulente fallisce, un nuovo tentativo rimanda solo al consulente, senza
-- duplicare la mail al cliente. Valorizzata = email partita (o in partenza:
-- la funzione la prenota prima dell'invio e la rimette a null se Brevo
-- risponde errore).
-- ============================================================================

alter table public.booking_slots
    add column if not exists email_cliente_inviata_at    timestamptz,
    add column if not exists email_consulente_inviata_at timestamptz;

-- Le prenotazioni già esistenti hanno avuto (o mancato) la loro mail con
-- EmailJS: le segniamo come già gestite, così la nuova funzione non può
-- essere usata per rimandarle a posteriori.
update public.booking_slots
   set email_cliente_inviata_at    = coalesce(email_cliente_inviata_at,    booked_at, now()),
       email_consulente_inviata_at = coalesce(email_consulente_inviata_at, booked_at, now())
 where booked = true
   and (email_cliente_inviata_at is null or email_consulente_inviata_at is null);

-- Il ruolo della service key (con cui gira la Edge Function) in questi
-- progetti non ha grant automatici sulle tabelle — stesso problema già
-- visto con consent_config in GESPP (commit b521806). La funzione legge la
-- prenotazione + il calendario e aggiorna le due colonne sopra.
-- service_role esiste solo lato server: nessuna esposizione verso anon.
grant select, update on public.booking_slots     to service_role;
grant select         on public.booking_calendars to service_role;
