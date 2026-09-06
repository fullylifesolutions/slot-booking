-- ============================================================================
--  SLOT-BOOKING — schema Supabase (sostituisce Firestore)
--
--  Estende lo schema GESPP esistente (companies/persons/app_users/
--  consultant_company/is_admin già presenti in quel progetto). Da eseguire
--  DOPO lo schema GESPP.
--
--  Modello: un "calendario" (booking_calendars) è o il calendario di
--  un'azienda (company_id valorizzato, un solo calendario per azienda) o il
--  calendario condiviso "Liberi Professionisti" (company_id null — più
--  righe con company_id null sono permesse dal vincolo unique, Postgres non
--  considera due NULL uguali: va garantito un solo pool a livello
--  applicativo, es. l'interfaccia di gestione impedisce di crearne un
--  secondo, non un vincolo DB).
--
--  Uno "slot" (booking_slots) esiste come riga SOLO quando è prenotato o
--  bloccato manualmente — gli orari disponibili non prenotati sono
--  calcolati al volo dal frontend a partire da schedules+duration_min,
--  esattamente come nel sistema Firestore precedente (generateSlots()):
--  non pre-generare una riga per ogni slot possibile.
-- ============================================================================

create table public.booking_calendars (
    id              uuid primary key default gen_random_uuid(),
    company_id      uuid references public.companies(id) on delete cascade, -- null = pool "Liberi Professionisti"
    nome            text not null,
    color           text default '#7c6fcd',
    duration_min    integer not null default 30,
    schedules       jsonb not null default '[]', -- [{day:1-7, ranges:[{start:'09:00',end:'18:00'}]}]
    max_per_day     integer,
    start_date      date,
    end_date        date,
    pin             text,                -- MAI esposto via select diretta pubblica, solo via verifica_pin_calendario()
    email_notifiche text,
    note            text,
    created_at      timestamptz not null default now(),
    unique (company_id)
);
create index idx_calendars_company on public.booking_calendars(company_id);

create table public.booking_slots (
    id              uuid primary key default gen_random_uuid(),
    calendar_id     uuid not null references public.booking_calendars(id) on delete cascade,
    data            date not null,
    ora             time not null,
    booked          boolean not null default false,
    booker_nome     text,
    booker_cognome  text,
    booker_email    text,
    note            text,
    booked_at       timestamptz,
    client_code     text,                -- NON univoco: condiviso da tutte le prenotazioni dello stesso
                                          -- cliente (un cliente prenota tipicamente 6+ slot), mostrato
                                          -- al prenotante per gestirle/cancellarle tutte insieme
    blocked         boolean not null default false,
    created_at      timestamptz not null default now(),
    -- Il vincolo unique fa da lock anti-doppia-prenotazione: due insert
    -- concorrenti sullo stesso (calendar_id,data,ora) non possono
    -- coesistere, il secondo fallisce invece di sovrascrivere il primo
    -- (più sicuro del comportamento precedente su Firestore, dove un
    -- setDoc concorrente avrebbe potuto sovrascrivere silenziosamente).
    unique (calendar_id, data, ora)
);
create index idx_slots_calendar on public.booking_slots(calendar_id);
create index idx_slots_client_code on public.booking_slots(client_code);

-- ----------------------------------------------------------------------------
-- Viste pubbliche: solo le colonne non sensibili, mai pin/booker_*.
-- Create SENZA security_invoker (default: eseguono con i privilegi del
-- proprietario) DI PROPOSITO — a differenza di emittenti_disponibili()/
-- prossimo_numero() nel gestionale (dove security invoker era voluto per
-- tenere attiva la RLS come seconda linea di difesa), qui vogliamo che
-- CHIUNQUE (anche anonimo) veda tutti i calendari/slot attivi a
-- prescindere da quale consulente li possiede — è un calendario pubblico
-- di prenotazione, non ha senso filtrarlo per consulente. La segretezza
-- di pin/booker_* è garantita a livello di struttura della vista (quelle
-- colonne non ci sono, nessuna configurazione di sicurezza potrebbe
-- comunque esporle), non da un filtro di righe.
-- ----------------------------------------------------------------------------
-- email_notifiche e' inclusa: serve al browser del prenotante per passarla
-- a EmailJS come destinatario della notifica al consulente (l'invio parte
-- dal client, non c'e' un server intermedio). E' l'indirizzo di lavoro del
-- consulente, non un dato del prenotante ne' un segreto come il pin.
create view public.booking_calendars_public as
    select id, company_id, nome, color, duration_min, schedules, max_per_day, start_date, end_date,
           (pin is not null) as ha_pin,  -- rivela solo SE serve un pin, mai il suo valore
           email_notifiche
    from public.booking_calendars;

create view public.booking_slots_public as
    select id, calendar_id, data, ora, booked, blocked
    from public.booking_slots;

-- ----------------------------------------------------------------------------
-- RLS
-- ----------------------------------------------------------------------------
alter table public.booking_calendars enable row level security;
alter table public.booking_slots     enable row level security;

-- Consulenti: stesso criterio di companies_read (admin o consultant_company)
-- per i calendari aziendali; chiunque sia un utente attivo di app_users per
-- il pool "Liberi Professionisti" (company_id null), come deciso in sessione.
--
-- "to authenticated" e' necessario, non opzionale: senza un ruolo esplicito
-- la policy si applica di default anche ad anon, e Postgres deve VALUTARE
-- la sua condizione per combinarla in OR con slots_public_insert anche
-- quando anon sta solo facendo l'insert pubblico di prenotazione — la
-- valutazione tocca consultant_company, su cui anon non ha mai avuto
-- select, quindi fallisce con "permission denied for table
-- consultant_company" invece di essere semplicemente scartata come falsa.
create policy calendars_consultant_all on public.booking_calendars
    for all to authenticated using (
        public.is_admin()
        or (company_id is not null and exists (
            select 1 from public.consultant_company cc
            where cc.company_id = booking_calendars.company_id and cc.consultant_id = auth.uid()
        ))
        or (company_id is null and exists (
            select 1 from public.app_users u where u.id = auth.uid() and u.attivo
        ))
    )
    with check (
        public.is_admin()
        or (company_id is not null and exists (
            select 1 from public.consultant_company cc
            where cc.company_id = booking_calendars.company_id and cc.consultant_id = auth.uid()
        ))
        or (company_id is null and exists (
            select 1 from public.app_users u where u.id = auth.uid() and u.attivo
        ))
    );

-- Slot: stesso criterio, applicato tramite il calendario padre. "to
-- authenticated" per lo stesso motivo di calendars_consultant_all sopra.
create policy slots_consultant_all on public.booking_slots
    for all to authenticated using (
        exists (
            select 1 from public.booking_calendars bc
            where bc.id = booking_slots.calendar_id and (
                public.is_admin()
                or (bc.company_id is not null and exists (
                    select 1 from public.consultant_company cc
                    where cc.company_id = bc.company_id and cc.consultant_id = auth.uid()
                ))
                or (bc.company_id is null and exists (
                    select 1 from public.app_users u where u.id = auth.uid() and u.attivo
                ))
            )
        )
    )
    with check (
        exists (
            select 1 from public.booking_calendars bc
            where bc.id = booking_slots.calendar_id and (
                public.is_admin()
                or (bc.company_id is not null and exists (
                    select 1 from public.consultant_company cc
                    where cc.company_id = bc.company_id and cc.consultant_id = auth.uid()
                ))
                or (bc.company_id is null and exists (
                    select 1 from public.app_users u where u.id = auth.uid() and u.attivo
                ))
            )
        )
    );

-- Prenotazione pubblica: chiunque (anche anonimo) può INSERIRE una nuova
-- prenotazione. Nessun select pubblico sulla tabella reale: la pagina di
-- prenotazione legge da booking_slots_public.
create policy slots_public_insert on public.booking_slots
    for insert to anon, authenticated
    with check (
        booked = true
        and client_code is not null
        and booker_nome is not null
        and booker_cognome is not null
        and booker_email is not null
    );

grant select on public.booking_calendars_public to anon, authenticated;
grant select on public.booking_slots_public to anon, authenticated;
grant insert on public.booking_slots to anon, authenticated;
grant select, insert, update, delete on public.booking_calendars, public.booking_slots to authenticated;

-- ----------------------------------------------------------------------------
-- Funzioni per operazioni pubbliche che richiedono dati sensibili:
-- verifica PIN (mai il valore, solo vero/falso), ricerca di TUTTE le
-- prenotazioni di un cliente (un client_code raggruppa tipicamente 6+
-- slot) e cancellazione di UNA riga specifica scelta dal cliente tra le
-- sue — mai una select libera sulla tabella, che esporrebbe nome/email
-- di tutti i prenotanti. cancella_prenotazione richiede sia l'id della
-- riga sia il client_code corretto: sapere un id (uuid, non indovinabile
-- per forza bruta) non basta da solo a cancellare la prenotazione di
-- qualcun altro.
-- ----------------------------------------------------------------------------
create or replace function public.verifica_pin_calendario(p_calendar_id uuid, p_pin text)
returns boolean
language sql security definer set search_path = public
as $$
    select exists(
        select 1 from public.booking_calendars
        where id = p_calendar_id and (pin is null or pin = p_pin)
    );
$$;
grant execute on function public.verifica_pin_calendario(uuid, text) to anon, authenticated;

create or replace function public.trova_prenotazioni_cliente(p_client_code text)
returns table(id uuid, calendar_id uuid, calendar_nome text, data date, ora time, booker_nome text, booker_cognome text)
language sql security definer set search_path = public
as $$
    select s.id, s.calendar_id, c.nome, s.data, s.ora, s.booker_nome, s.booker_cognome
    from public.booking_slots s
    join public.booking_calendars c on c.id = s.calendar_id
    where s.client_code = p_client_code and s.booked = true
    order by s.data, s.ora;
$$;
grant execute on function public.trova_prenotazioni_cliente(text) to anon, authenticated;

create or replace function public.cancella_prenotazione(p_id uuid, p_client_code text)
returns boolean
language plpgsql security definer set search_path = public
as $$
declare
    v_id uuid;
begin
    select id into v_id from public.booking_slots
        where id = p_id and client_code = p_client_code and booked = true;
    if v_id is null then
        return false;
    end if;
    delete from public.booking_slots where id = v_id;
    return true;
end;
$$;
grant execute on function public.cancella_prenotazione(uuid, text) to anon, authenticated;

-- ----------------------------------------------------------------------------
-- Configurazione EmailJS (una riga sola) per le email di conferma prenotazione.
-- Non è un segreto: la "public key" EmailJS è pensata per stare lato client,
-- come la anon key di Supabase — leggibile pubblicamente per design, così la
-- pagina di prenotazione (anonima) può inviare l'email di conferma da sola.
-- L'email del consulente da notificare è invece per-calendario
-- (booking_calendars.email_notifiche), non più un unico indirizzo globale
-- come nella versione Firestore: ogni azienda avvisa il proprio consulente.
-- ----------------------------------------------------------------------------
create table public.booking_email_config (
    id              integer primary key default 1 check (id = 1), -- riga singola
    pubkey          text,
    service_id      text,
    tpl_client      text,
    tpl_consultant  text
);
insert into public.booking_email_config (id) values (1) on conflict (id) do nothing;

alter table public.booking_email_config enable row level security;

create policy email_config_read on public.booking_email_config
    for select to anon, authenticated using (true);

create policy email_config_write on public.booking_email_config
    for update to authenticated using (
        public.is_admin() or exists (select 1 from public.app_users u where u.id = auth.uid() and u.attivo)
    ) with check (
        public.is_admin() or exists (select 1 from public.app_users u where u.id = auth.uid() and u.attivo)
    );

grant select on public.booking_email_config to anon, authenticated;
grant update on public.booking_email_config to authenticated;
