-- ============================================================================
--  Platform schema — 001 init
--
--  Conventions, applied everywhere:
--    * Money is BIGINT CENTS. Never float. A "rate" or a percentage is NUMERIC.
--    * A month is a DATE pinned to the 1st, enforced by CHECK.
--    * Mutable tables carry set_by / set_at. Either a human or a sync may write
--      any field (invariant 1) — what is forbidden is doing it silently.
--    * Tables owned by a sync are marked SYNC-OWNED. The app reads them and
--      never writes them; corrections happen in the source system.
--    * Nothing derived is stored, except payment_behaviour which is an explicit
--      recomputable cache.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- enums ----

create type deal_status   as enum ('pipeline','won','active','closed','lost');
create type deal_origin   as enum ('hubspot','manual','import','qbo_backfill');
create type line_kind     as enum ('retainer','search','social','programmatic','hourly','custom');
create type billing_day   as enum ('first','last');
create type comp_kind     as enum ('salary','hourly');
create type cost_kind     as enum ('bill','purchase','journal');
create type snapshot_trig as enum ('won','renewal','month_close','manual');

-- ------------------------------------------------------------- identity ----

create table clients (
  id               uuid primary key default gen_random_uuid(),
  name             text not null unique,
  qbo_customer_id  text unique,
  active           boolean not null default true,
  set_by           text,
  set_at           timestamptz not null default now(),
  created_at       timestamptz not null default now()
);

-- HubSpot company names that mean the same client.
create table client_aliases (
  client_id  uuid not null references clients(id) on delete cascade,
  alias      text not null,
  primary key (client_id, alias)
);
create unique index client_aliases_alias_key on client_aliases (lower(alias));

create table staff (
  id             uuid primary key default gen_random_uuid(),
  name           text not null,
  email          text unique,
  department     text,
  qbtime_user_id text unique,
  active         boolean not null default true,
  set_by         text,
  set_at         timestamptz not null default now()
);

-- Pay and capacity change over time. A month spanning two periods is split by
-- calendar date, so history is never rewritten when an arrangement changes.
-- This is the ONLY source of an hourly cost rate for effort costing. It is
-- deliberately unrelated to payroll expense in the Forecast.
create table comp_periods (
  id              uuid primary key default gen_random_uuid(),
  staff_id        uuid not null references staff(id) on delete cascade,
  starts_on       date not null,
  ends_on         date,                        -- null = open; closed implicitly by the next period
  kind            comp_kind not null,
  annual_cost     bigint not null default 0,   -- cents, salary
  hourly_cost     bigint not null default 0,   -- cents, hourly
  weekly_capacity numeric(5,2) not null default 40,
  set_by          text,
  set_at          timestamptz not null default now(),
  check (ends_on is null or ends_on >= starts_on)
);
create index comp_periods_staff_idx on comp_periods (staff_id, starts_on);

-- ----------------------------------------------------------- commitment ----

create table deals (
  id              uuid primary key default gen_random_uuid(),
  client_id       uuid not null references clients(id) on delete restrict,
  name            text not null,
  status          deal_status not null default 'pipeline',
  origin          deal_origin not null default 'manual',

  -- The flight is the spine. Open-ended retainers are expressed by extending
  -- these dates on renewal, not by a null end.
  flight_start    date,
  flight_end      date,

  hubspot_deal_id text unique,
  qbo_project_id  text,
  jobcode         text,

  promoted_at     timestamptz,   -- when it came through the one-way door
  reviewed_at     timestamptz,   -- when a human confirmed the line items
  set_by          text,
  set_at          timestamptz not null default now(),
  created_at      timestamptz not null default now(),

  check (flight_start is null or flight_start = date_trunc('month', flight_start)::date),
  check (flight_end   is null or flight_end   = date_trunc('month', flight_end)::date),
  check (flight_end is null or flight_start is null or flight_end >= flight_start),
  -- A live deal must have a flight. No close-date fallback, no silent one-month guess.
  check (status not in ('won','active') or (flight_start is not null and flight_end is not null))
);
create index deals_client_idx  on deals (client_id);
create index deals_qbo_idx     on deals (qbo_project_id);
create index deals_flight_idx  on deals (flight_start, flight_end);

create table deal_lines (
  id              uuid primary key default gen_random_uuid(),
  deal_id         uuid not null references deals(id) on delete cascade,
  kind            line_kind not null,
  label           text,
  department      text,

  amount          bigint  not null default 0,   -- cents/month, retainer & custom
  budget          bigint  not null default 0,   -- cents/month, media
  fee_pct         numeric(6,3) not null default 0,
  margin_pct      numeric(6,3),                 -- null = fall back to achieved, then default
  rate            bigint  not null default 0,   -- cents/hour
  hours_per_month numeric(7,2) not null default 0,
  --  ^ COMMITMENT-side hours: a commercial quantity typed into the Forecast.
  --    Not to be confused with assignments.hours (operational). The revenue side
  --    never reads the operational side — see invariant 7.

  billing_day     billing_day not null default 'last',
  set_by          text,
  set_at          timestamptz not null default now()
);
create index deal_lines_deal_idx on deal_lines (deal_id);

-- Per-month overrides. A month present here wins over the flat figure above.
create table deal_line_months (
  deal_line_id uuid not null references deal_lines(id) on delete cascade,
  month        date not null,
  budget       bigint,
  amount       bigint,
  hours        numeric(7,2),
  set_by       text,
  set_at       timestamptz not null default now(),
  primary key (deal_line_id, month),
  check (month = date_trunc('month', month)::date)
);

-- Append-only. Taken when a deal is won, renewed, or a month closes.
-- Replaces the old single 'frozen' value, which could only capture one moment.
create table deal_snapshots (
  id           uuid primary key default gen_random_uuid(),
  deal_id      uuid not null references deals(id) on delete cascade,
  taken_at     timestamptz not null default now(),
  trigger      snapshot_trig not null,
  flight_start date,
  flight_end   date,
  payload      jsonb not null,     -- lines + month-by-month GP as at that moment
  taken_by     text
);
create index deal_snapshots_deal_idx on deal_snapshots (deal_id, taken_at desc);

-- SYNC-OWNED. Replaced wholesale every night. Owns nothing.
create table pipeline_deals (
  hubspot_deal_id text primary key,
  name            text,
  company         text,
  stage           text,
  probability     numeric(4,3),
  amount          bigint,
  close_date      date,
  campaign_start  date,
  campaign_end    date,
  is_won          boolean not null default false,
  jobcode         text,
  qbo_link        text,
  line_items      jsonb not null default '[]',
  url             text,
  synced_at       timestamptz not null default now()
);

-- Permanent. Survives deletion of the deal it created, so a HubSpot deal can
-- never walk back through the one-way door a second time.
create table promotions (
  hubspot_deal_id text primary key,
  deal_id         uuid references deals(id) on delete set null,
  promoted_at     timestamptz not null default now(),
  promoted_by     text,
  source_payload  jsonb not null      -- as-sold record, exactly as HubSpot had it
);

-- ----------------------------------------------------------------- cash ----

create table cash_accounts (            -- SYNC-OWNED except is_operating
  id             text primary key,      -- QBO account id
  name           text not null,
  account_type   text,
  balance        bigint not null default 0,
  as_of          date,
  is_operating   boolean not null default false,   -- ticked in Settings
  synced_at      timestamptz not null default now()
);

create table invoices (                 -- SYNC-OWNED
  id             text primary key,      -- QBO invoice id
  deal_id        uuid references deals(id) on delete set null,
  client_id      uuid references clients(id) on delete set null,
  qbo_project_id text,
  doc_number     text,
  issued_on      date not null,
  due_on         date,                  -- NEW vs the old sync; drives collection
  terms          text,
  total          bigint not null default 0,
  balance        bigint not null default 0,
  excluded       boolean not null default false,
  exclude_reason text,
  synced_at      timestamptz not null default now()
);
create index invoices_client_idx on invoices (client_id, issued_on);
create index invoices_deal_idx   on invoices (deal_id, issued_on);
create index invoices_open_idx   on invoices (due_on) where balance > 0;

create table invoice_lines (            -- SYNC-OWNED
  id          text primary key,
  invoice_id  text not null references invoices(id) on delete cascade,
  line_no     int,
  item_id     text,
  item_name   text,
  description text,
  qty         numeric(12,3),
  unit_price  bigint,
  amount      bigint not null default 0
);

create table payments (                 -- SYNC-OWNED. NEW.
  id         text primary key,          -- QBO payment id
  invoice_id text references invoices(id) on delete set null,
  client_id  uuid references clients(id) on delete set null,
  paid_on    date not null,
  amount     bigint not null default 0,
  synced_at  timestamptz not null default now()
);
create index payments_invoice_idx on payments (invoice_id);

create table bills (                    -- SYNC-OWNED
  id          text primary key,         -- 'bill:123' | 'purchase:456' | 'journal:789'
  kind        cost_kind not null,
  vendor_name text,
  deal_id     uuid references deals(id) on delete set null,
  issued_on   date not null,
  due_on      date,                     -- NEW
  balance     bigint not null default 0,-- NEW; >0 means still outstanding
  terms       text,                     -- NEW
  total       bigint not null default 0,
  synced_at   timestamptz not null default now()
);
create index bills_due_idx on bills (due_on) where balance > 0;

create table bill_lines (               -- SYNC-OWNED
  id             text primary key,
  bill_id        text not null references bills(id) on delete cascade,
  line_no        int,
  item_name      text,
  account_name   text,
  description    text,
  amount         bigint not null default 0,
  qbo_project_id text
);

create table bill_payments (            -- SYNC-OWNED. NEW.
  id        text primary key,
  bill_id   text references bills(id) on delete set null,
  paid_on   date not null,
  amount    bigint not null default 0,
  synced_at timestamptz not null default now()
);

-- Recurring operating costs not tied to a deal.
create table overhead (
  id         uuid primary key default gen_random_uuid(),
  label      text not null,
  category   text,
  amount     bigint not null default 0,
  recurrence text not null default 'monthly',
  starts_on  date,
  ends_on    date,
  set_by     text,
  set_at     timestamptz not null default now()
);

-- Recomputable cache of observed payment behaviour. Distribution, not just a
-- mean: a client paying anywhere from 30 to 95 days is a different risk from
-- one reliably at 55. Scope is 'client' (money in) or 'vendor' (money out).
create table payment_behaviour (
  scope       text not null check (scope in ('client','vendor')),
  ref         text not null,          -- client_id::text, or vendor_name
  sample_n    int  not null default 0,
  p25_lag     int,
  median_lag  int,
  p75_lag     int,
  computed_at timestamptz not null default now(),
  primary key (scope, ref)
);

-- --------------------------------------------------------------- effort ----

-- Planned hours. OPERATIONAL. Never read by anything that computes revenue.
create table assignments (
  id        uuid primary key default gen_random_uuid(),
  staff_id  uuid not null references staff(id) on delete cascade,
  deal_id   uuid not null references deals(id) on delete cascade,
  month     date not null,
  hours     numeric(7,2) not null default 0,
  set_by    text,
  set_at    timestamptz not null default now(),
  unique (staff_id, deal_id, month),
  check (month = date_trunc('month', month)::date)
);
create index assignments_month_idx on assignments (month);

-- SYNC-OWNED. Kept at DAY grain: daily rows roll up to anything, month rows
-- roll up to nothing. The old sync aggregated to month at write time.
create table time_entries (
  id         text primary key,
  staff_id   uuid references staff(id) on delete set null,
  deal_id    uuid references deals(id) on delete set null,
  client_id  uuid references clients(id) on delete set null,
  worked_on  date not null,
  hours      numeric(7,2) not null default 0,
  department text,
  source     text not null default 'qbtime',
  synced_at  timestamptz not null default now()
);
create index time_entries_day_idx   on time_entries (worked_on);
create index time_entries_staff_idx on time_entries (staff_id, worked_on);
create index time_entries_deal_idx  on time_entries (deal_id, worked_on);

create table time_off (
  id        uuid primary key default gen_random_uuid(),
  staff_id  uuid not null references staff(id) on delete cascade,
  starts_on date not null,
  ends_on   date not null,
  kind      text,
  set_by    text,
  set_at    timestamptz not null default now(),
  check (ends_on >= starts_on)
);

-- --------------------------------------------------------------- config ----

create table settings (
  key        text primary key,
  value      jsonb not null,
  set_by     text,
  set_at     timestamptz not null default now()
);

create table item_map (          -- QBO invoice item -> revenue classification
  qbo_item_name text primary key,
  kind          line_kind,
  role          text check (role in ('budget','fee','flat','amount')),
  set_by        text,
  set_at        timestamptz not null default now()
);

create table line_item_map (     -- HubSpot line item -> deal line kind
  hubspot_item_name text primary key,
  kind              line_kind,
  role              text check (role in ('budget','fee','flat','amount')),
  set_by            text,
  set_at            timestamptz not null default now()
);

-- The human judgement that maps QuickBooks projects onto clients and deals.
-- Expensive to reproduce; the API can suggest but cannot decide.
create table qbo_project_links (
  qbo_project_id text primary key,
  client_id      uuid references clients(id) on delete set null,
  deal_id        uuid references deals(id) on delete set null,
  confidence     text check (confidence in ('high','medium','low')),
  matched_by     text,
  matched_at     timestamptz not null default now()
);

-- Sync bookkeeping. Holds the rotating QuickBooks OAuth refresh token, so this
-- table is DELIBERATELY EXCLUDED from the permissive RLS policy below: RLS is
-- enabled with no policy at all, which means only the service role (used by the
-- GitHub Actions syncs, and which bypasses RLS) can read or write it. An
-- authenticated browser session must never be able to select a refresh token.
create table sync_state (
  id            text primary key,       -- 'quickbooks' | 'qbtime' | 'hubspot'
  realm_id      text,
  refresh_token text,
  import_from   date,
  last_run_at   timestamptz,
  last_run_log  jsonb,
  updated_at    timestamptz not null default now()
);
alter table sync_state enable row level security;   -- no policy: service role only

-- ---------------------------------------------------------------- seeds ----

insert into sync_state (id, import_from) values
  ('quickbooks', '2025-01-01'),
  ('qbtime',     '2025-01-01'),
  ('hubspot',    null);

insert into settings (key, value, set_by) values
  ('payroll_cadence',   '"semi_monthly"',            'seed'),  -- 15th and last day, 24 runs
  ('payroll_days',      '[15,-1]',                   'seed'),
  ('programmatic_margin_default', '35',              'seed'),
  ('qbo_history_from',  '"2025-01-01"',              'seed'),
  ('currency',          '"USD"',                     'seed');

-- ------------------------------------------------------------------ rls ----
-- Enabled now so nothing is ever exposed by default. Policies stay permissive
-- for authenticated users until roles are designed; tightening later is then a
-- policy change rather than a migration.

do $$
declare t text;
begin
  foreach t in array array[
    'clients','client_aliases','staff','comp_periods','deals','deal_lines',
    'deal_line_months','deal_snapshots','pipeline_deals','promotions',
    'cash_accounts','invoices','invoice_lines','payments','bills','bill_lines',
    'bill_payments','overhead','payment_behaviour','assignments','time_entries',
    'time_off','settings','item_map','line_item_map','qbo_project_links'
  ]
  loop
    execute format('alter table %I enable row level security', t);
    execute format(
      'create policy %I on %I for all to authenticated using (true) with check (true)',
      t || '_auth_all', t);
  end loop;
end $$;
