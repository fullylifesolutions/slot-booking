-- ============================================================================
-- Slot-booking — più calendari per la stessa azienda (servizi diversi)
-- Da applicare PRIMA su TEST, poi su PROD, e PRIMA di pubblicare la versione
-- di GESPP che permette "+ Nuovo calendario". Idempotente (rieseguibile).
--
-- I calendari di un'azienda sono indipendenti (orari, durata, limite
-- giornaliero propri). Il pool "Liberi Professionisti" (company_id null)
-- resta unico: ora lo garantisce anche il DB, non solo l'interfaccia.
-- RLS e permessi invariati.
-- ============================================================================

-- 1) via il vincolo "un calendario per azienda"
alter table public.booking_calendars
    drop constraint if exists booking_calendars_company_id_key;

-- 2) al massimo un calendario con company_id null (Liberi Professionisti)
create unique index if not exists uq_booking_calendars_pool
    on public.booking_calendars ((company_id is null))
    where company_id is null;
