-- ============================================================================
-- Slot-booking — rimozione della vecchia configurazione EmailJS
-- Da applicare PRIMA su TEST, poi su PROD. Rieseguibile.
--
-- Le email partono dalla Edge Function booking-email (Brevo), che legge
-- destinatari e contenuti dal DB con la service key. Quindi:
--  1. la tabella booking_email_config (chiavi EmailJS) non serve più;
--  2. email_notifiche esce dalla vista pubblica: serviva solo al browser del
--     prenotante per passarla a EmailJS, ora era leggibile da chiunque senza
--     motivo. Resta nella tabella booking_calendars (GESPP la usa da lì).
-- ============================================================================
begin;

drop table if exists public.booking_email_config;

-- Una vista non può perdere una colonna con "create or replace": va ricreata.
drop view if exists public.booking_calendars_public;
create view public.booking_calendars_public as
    select id, company_id, nome, color, duration_min, schedules, max_per_day, start_date, end_date,
           (pin is not null) as ha_pin  -- rivela solo SE serve un pin, mai il suo valore
    from public.booking_calendars;
grant select on public.booking_calendars_public to anon, authenticated;

commit;

-- Verifica: la prima deve restituire 0 righe, la seconda le colonne della
-- vista SENZA email_notifiche.
select tablename from pg_tables where schemaname='public' and tablename='booking_email_config';
select column_name from information_schema.columns
 where table_schema='public' and table_name='booking_calendars_public' order by ordinal_position;
