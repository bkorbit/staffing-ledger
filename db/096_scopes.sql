-- ============================================================================
--  096 — Scoping: the tables, the fee/rebate/margin primitives, save and create.
--
--  A scope is the question "is this deal viable?" asked before the deal
--  exists: which channels, what structure (flat fee, marginal bands, whole-
--  spend bands, minimum, cap, rebate, programmatic fee+margin or CPM), how
--  many hours it will take per department per month, who will do them, and
--  whether GP − rebate − labor clears the company's profit-per-hour target
--  with people who are actually free. Decided with Boris, 13 Sep 2026; the
--  plan lives in ~/.claude/plans/i-want-to-start-iridescent-sonnet.md.
--
--  Shape:
--    scopes            the question. family_id groups SCENARIOS of one target
--                      (alternative structures compared side by side);
--                      status draft → proposed → approved → promoted; version
--                      counts saves. Only emails in settings
--                      scope_approver_emails may approve (trigger below).
--    scope_deals       a scope can hold SEVERAL future deals (a retainer
--                      renewal + a Q4 campaign for one client). Each carries
--                      its origin (hubspot mirror row / existing deal to
--                      re-scope / new), exact flight dates and how it will
--                      promote (through promote_approval, as a new manual
--                      deal, or by extending the source deal — 100).
--    scope_lines       the commercial lines, same columns deal_lines has plus
--                      `structure` jsonb (bands, min/cap, rebate, programmatic
--                      model) and hours_included / overage_rate for retainers
--                      (terms-only). scope_line_months = per-month cells, as
--                      deal_line_months, plus `drivers` for the benchmarks (098).
--    scope_dept_months DEMAND: hours needed per department per month (typed,
--                      from benchmarks, from the catalog, or from actuals).
--    scope_staff_months SUPPLY: named people (staff_id) or placeholders
--                      (staff_id null, department × comp band). Demand not
--                      covered by either is "unassigned" and is still priced
--                      (department average) so the verdict never undercounts.
--    scope_versions    append-only snapshot of the whole scope on every save /
--                      approve / unapprove / promote, with an optional label,
--                      so different structures can be compared over time.
--    assignments       deal_id becomes nullable and scope_id is added: an
--                      APPROVED scope reserves its named hours here before the
--                      deal exists (deal_id null, scope_id set), so capacity
--                      sees them; promotion relinks deal_id. hours_page already
--                      filters deal_id is not null where that matters (090).
--
--  Money primitives — ONE copy each, twinned digit-for-digit in
--  app/assets/scope-math.js (tested by scripts/test/scope-math.test.mjs on
--  the same numbers as 097_fixture_test.sql):
--    line_fee(budget, fee_pct, structure) → numeric, UNROUNDED. flat =
--      budget × fee_pct / 100 exactly, so round(line_fee(...)) equals today's
--      round(budget * fee_pct / 100) and the 099 view stays byte-identical for
--      every existing line. marginal = each slice at its own rate; whole = the
--      band the month's spend lands in prices all of it (boundary inclusive:
--      budget <= upto stays in the band). Bands apply to EACH MONTH's spend
--      (Boris). fee_min then fee_cap (cap wins). Callers round ONCE.
--    line_rebate(budget, fee, pct, basis) → numeric: 'media' = % of the
--      month's media, 'fee' = % of the fee. The client invoices EMG and it is
--      booked COGS Other: it reduces GP, never billable (Boris).
--    prog_suggest_margin(fee_pct, target_gp_pct): the backend margin the
--      programmatic team should set so GP / REVENUE ≥ target — historical GP%
--      reads against revenue, so the instruction is measured the same way:
--      m = target × (100 + fee) / 100 − fee, floored at 0, ½-pt independent
--      (3dp). CPM billing is margin-only: margin_pct = 100 − platform share,
--      fee_pct = 0, so the existing view math already prices it.
--
--  Labor primitives (cost never leaves SQL as a per-person number — 097):
--    staff_band(staff_id, on) — the comp band a person's burdened hourly cost
--      falls in (settings scope_comp_bands: ascending upto_c, last null).
--    band_rate(department, band, on) — mean staff_hourly_cost of active,
--      tracks_capacity people in that department and band on the date;
--      falls back to the department mean, then the company mean; null when
--      there is nobody to price against (the verdict then says "unpriced").
--    hire_hourly_cost / contractor_hourly_cost(department) — from settings
--      scope_hire_costs {dept: {annual_c, contractor_hourly_c}}; annual_c is
--      the FULLY LOADED annual cost Boris types (no re-implementation of the
--      burden stack), ÷ (52 × 40).
--
--  Fixture: db/097_fixture_test.sql covers the primitives and save/create
--  together with 097's functions (one bed, one result set).
-- ============================================================================

-- ---------------------------------------------------------------- settings --
insert into settings (key, value, set_by) values
  ('scope_target_profit_per_hour', '150'::jsonb, 'migration-096'),
  ('scope_prog_target_gp_pct',     '40'::jsonb,  'migration-096'),
  ('scope_cpm_platform_share_pct', '50'::jsonb,  'migration-096'),
  ('scope_approver_emails',        '["boris@elitemedia.group"]'::jsonb, 'migration-096'),
  ('scope_comp_bands',
   '[{"name":"Band 1","upto_c":4500},{"name":"Band 2","upto_c":7500},{"name":"Band 3","upto_c":11500},{"name":"Band 4","upto_c":null}]'::jsonb,
   'migration-096'),
  ('scope_hire_costs',             '{}'::jsonb,  'migration-096'),
  ('scope_hire_fte_share_pct',     '50'::jsonb,  'migration-096'),
  ('scope_hire_min_months',        '2'::jsonb,   'migration-096')
on conflict (key) do nothing;

-- ---------------------------------------------------------- structure check --
create or replace function structure_is_valid(p jsonb)
returns boolean
language plpgsql
immutable
as $$
declare
  v_mode text; v_prev bigint := -1; v_upto bigint; b jsonb; v_n int; i int; v_basis text; v_model text;
begin
  if p is null then return true; end if;
  if jsonb_typeof(p) <> 'object' then return false; end if;
  v_mode := coalesce(p #>> '{fee,mode}', 'flat');
  if v_mode not in ('flat', 'marginal', 'whole') then return false; end if;
  if v_mode <> 'flat' then
    if jsonb_typeof(p #> '{fee,bands}') <> 'array' then return false; end if;
    v_n := jsonb_array_length(p #> '{fee,bands}');
    if v_n = 0 then return false; end if;
    for i in 0 .. v_n - 1 loop
      b := p #> '{fee,bands}' -> i;
      if (b ->> 'pct') is null or (b ->> 'pct')::numeric < 0 or (b ->> 'pct')::numeric > 100 then return false; end if;
      v_upto := nullif(b ->> 'upto', '')::bigint;
      if i < v_n - 1 then
        if v_upto is null or v_upto <= v_prev then return false; end if;   -- ascending, only the last open
        v_prev := v_upto;
      elsif v_upto is not null and v_upto <= v_prev then return false;
      end if;
    end loop;
  end if;
  if (p ->> 'fee_min') is not null and (p ->> 'fee_min')::numeric < 0 then return false; end if;
  if (p ->> 'fee_cap') is not null and (p ->> 'fee_cap')::numeric < 0 then return false; end if;
  if p ? 'rebate' and jsonb_typeof(p -> 'rebate') = 'object' then
    if (p #>> '{rebate,pct}')::numeric < 0 or (p #>> '{rebate,pct}')::numeric > 100 then return false; end if;
    v_basis := coalesce(p #>> '{rebate,basis}', 'media');
    if v_basis not in ('media', 'fee') then return false; end if;
  end if;
  if p ? 'prog' and jsonb_typeof(p -> 'prog') = 'object' then
    v_model := coalesce(p #>> '{prog,model}', 'fee_margin');
    if v_model not in ('fee_margin', 'cpm') then return false; end if;
    if v_model = 'cpm' and ((p #>> '{prog,platform_share_pct}')::numeric < 0 or (p #>> '{prog,platform_share_pct}')::numeric > 100) then return false; end if;
  end if;
  return true;
exception when others then
  return false;
end;
$$;

comment on function structure_is_valid(jsonb) is
  'Check constraint for scope_lines.structure (and deal_lines.structure from 099): fee.mode flat|marginal|whole with ascending bands (only the last open), 0–100 pcts, non-negative min/cap, rebate pct 0–100 with basis media|fee, prog model fee_margin|cpm. Garbage returns false, never raises.';

-- --------------------------------------------------------------- the tables --
create table if not exists scopes (
  id               uuid primary key default gen_random_uuid(),
  family_id        uuid not null default gen_random_uuid(),
  name             text not null,
  scenario         text not null default 'Base',
  client_id        uuid references clients(id) on delete set null,
  status           text not null default 'draft'
                   check (status in ('draft', 'proposed', 'approved', 'promoted')),
  version          int  not null default 0,        -- = number of snapshots taken; the first save makes it 1
  approved_by      text,
  approved_at      timestamptz,
  promoted_at      timestamptz,
  payment_net_days int  not null default 30,
  notes            text,
  terms_text       text,
  set_by           text,
  set_at           timestamptz not null default now(),
  created_at       timestamptz not null default now()
);
create index if not exists scopes_family_idx on scopes (family_id);
create index if not exists scopes_client_idx on scopes (client_id);

create table if not exists scope_deals (
  id                uuid primary key default gen_random_uuid(),
  scope_id          uuid not null references scopes(id) on delete cascade,
  ord               int  not null default 0,
  name              text not null,
  origin_kind       text not null check (origin_kind in ('hubspot', 'deal', 'new')),
  hubspot_deal_id   text,
  source_deal_id    uuid references deals(id) on delete set null,
  flight_start      date,
  flight_end        date,
  promote_mode      text not null default 'new' check (promote_mode in ('hubspot', 'new', 'extend')),
  qbo_project_id    text references qbo_projects(id),
  promoted_deal_id  uuid references deals(id) on delete set null,
  check (flight_start is null or flight_end is null or flight_end >= flight_start)
);
create index if not exists scope_deals_scope_idx on scope_deals (scope_id, ord);
create index if not exists scope_deals_hubspot_idx on scope_deals (hubspot_deal_id) where hubspot_deal_id is not null;

create table if not exists scope_lines (
  id              uuid primary key default gen_random_uuid(),
  scope_deal_id   uuid not null references scope_deals(id) on delete cascade,
  ord             int  not null default 0,
  kind            line_kind not null,
  label           text,
  amount          bigint not null default 0,
  budget          bigint not null default 0,
  fee_pct         numeric(6,3) not null default 0,
  margin_pct      numeric(6,3),
  rate            bigint not null default 0,
  hours_per_month numeric(7,2) not null default 0,
  hours_included  numeric(7,2),
  overage_rate    bigint,
  media_funding   media_funding not null default 'client',
  billing_day     billing_day not null default 'last',
  structure       jsonb not null default '{}'::jsonb check (structure_is_valid(structure)),
  set_by          text,
  set_at          timestamptz not null default now()
);
create index if not exists scope_lines_deal_idx on scope_lines (scope_deal_id, ord);

create table if not exists scope_line_months (
  scope_line_id uuid not null references scope_lines(id) on delete cascade,
  month         date not null,
  budget        bigint,
  amount        bigint,
  hours         numeric(7,2),
  drivers       jsonb,
  primary key (scope_line_id, month),
  check (month = date_trunc('month', month)::date)
);

create table if not exists scope_dept_months (
  scope_id   uuid not null references scopes(id) on delete cascade,
  department text not null,
  month      date not null,
  hours      numeric(7,2) not null default 0,
  source     text not null default 'manual' check (source in ('manual', 'benchmark', 'actuals', 'catalog')),
  primary key (scope_id, department, month),
  check (month = date_trunc('month', month)::date)
);

create table if not exists scope_staff_months (
  id         uuid primary key default gen_random_uuid(),
  scope_id   uuid not null references scopes(id) on delete cascade,
  staff_id   uuid references staff(id) on delete cascade,     -- null = placeholder
  department text not null,
  band       text,                                             -- placeholders only
  month      date not null,
  hours      numeric(7,2) not null default 0,
  source     text not null default 'manual' check (source in ('manual', 'auto')),
  check (month = date_trunc('month', month)::date)
);
-- a person may hold one MANUAL and one AUTO row per month: auto_staff_scope
-- (097) replaces only its own layer, so the two must be separate rows
create unique index if not exists scope_staff_months_named_uidx
  on scope_staff_months (scope_id, staff_id, month, source) where staff_id is not null;
create unique index if not exists scope_staff_months_placeholder_uidx
  on scope_staff_months (scope_id, department, coalesce(band, ''), month) where staff_id is null;

create table if not exists scope_versions (
  id        uuid primary key default gen_random_uuid(),
  scope_id  uuid not null references scopes(id) on delete cascade,
  version   int  not null,
  reason    text not null check (reason in ('save', 'approve', 'unapprove', 'promote')),
  label     text,
  payload   jsonb not null,
  saved_by  text,
  saved_at  timestamptz not null default now(),
  unique (scope_id, version)
);

do $$
declare t text;
begin
  foreach t in array array['scopes', 'scope_deals', 'scope_lines', 'scope_line_months',
                           'scope_dept_months', 'scope_staff_months', 'scope_versions'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_auth_all', t);
    execute format('create policy %I on %I for all to authenticated using (true) with check (true)', t || '_auth_all', t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
  end loop;
end $$;

-- -------------------------------------------------------------- assignments --
alter table assignments alter column deal_id drop not null;
alter table assignments add column if not exists scope_id uuid references scopes(id) on delete cascade;
alter table assignments drop constraint if exists assignments_target_check;
alter table assignments add constraint assignments_target_check check (deal_id is not null or scope_id is not null);
create unique index if not exists assignments_scope_uidx
  on assignments (staff_id, scope_id, month) where deal_id is null;
create index if not exists assignments_scope_idx on assignments (scope_id) where scope_id is not null;

comment on table assignments is
  'Planned hours. OPERATIONAL. Never read by anything that computes revenue. 096: deal_id is nullable — an APPROVED scope reserves its named hours with deal_id null and scope_id set (set_by scope:approve) so capacity sees them before the deal exists; promotion relinks deal_id. Seed rows carry set_by seed:trailing-actuals (095).';

-- --------------------------------------------------------- money primitives --
create or replace function line_fee(p_budget bigint, p_fee_pct numeric, p_structure jsonb)
returns numeric
language sql
immutable
as $$
with s as (select coalesce(p_structure, '{}'::jsonb) as st),
mode as (select coalesce((select st #>> '{fee,mode}' from s), 'flat') as m),
bands as (
  select t.ord,
         (t.b ->> 'pct')::numeric as pct,
         nullif(t.b ->> 'upto', '')::bigint as upto,
         coalesce(lag(nullif(t.b ->> 'upto', '')::bigint) over (order by t.ord), 0) as lo
  from s, jsonb_array_elements(case when jsonb_typeof(st #> '{fee,bands}') = 'array'
                                    then st #> '{fee,bands}' else '[]'::jsonb end)
         with ordinality as t(b, ord)
),
raw as (
  select case (select m from mode)
    when 'flat'     then coalesce(p_budget, 0) * coalesce(p_fee_pct, 0) / 100
    when 'marginal' then coalesce((select sum(greatest(least(coalesce(p_budget, 0), coalesce(upto, coalesce(p_budget, 0))) - lo, 0) * pct / 100)
                                   from bands), 0)
    when 'whole'    then coalesce((select coalesce(p_budget, 0) * pct / 100 from bands
                                   where coalesce(p_budget, 0) > lo and (upto is null or coalesce(p_budget, 0) <= upto)
                                   order by ord limit 1), 0)
  end as fee
),
floored as (
  select greatest(fee, coalesce((select nullif(st ->> 'fee_min', '')::numeric from s), fee)) as fee from raw
),
capped as (
  select least(fee, coalesce((select nullif(st ->> 'fee_cap', '')::numeric from s), fee)) as fee from floored
)
select fee from capped;
$$;

comment on function line_fee(bigint, numeric, jsonb) is
  'The fee on one month''s media spend, UNROUNDED numeric — callers round once. flat: budget × fee_pct / 100 (byte-identical to the pre-096 view math when rounded). marginal: each band slice at its own pct; whole: the band the spend lands in (budget <= upto, inclusive) prices all of it. Then fee_min (floor, applies even at zero spend), then fee_cap (cap wins). JS twin: lineFee in app/assets/scope-math.js.';

create or replace function line_rebate(p_budget bigint, p_fee numeric, p_pct numeric, p_basis text)
returns numeric
language sql
immutable
as $$
  select case
    when coalesce(p_pct, 0) = 0 then 0
    when coalesce(p_basis, 'media') = 'media' then coalesce(p_budget, 0) * p_pct / 100
    when p_basis = 'fee' then coalesce(p_fee, 0) * p_pct / 100
    else 0 end;
$$;

comment on function line_rebate(bigint, numeric, numeric, text) is
  'Rebate EMG pays back to the client, UNROUNDED: basis media = % of the month''s media budget; basis fee = % of the fee (for non-media kinds the fee is the line''s GP). Booked COGS Other: reduces GP, never billable. JS twin: lineRebate.';

create or replace function prog_suggest_margin(p_fee_pct numeric, p_target_gp_pct numeric)
returns numeric
language sql
immutable
as $$
  select round(greatest(coalesce(p_target_gp_pct, 0) * (100 + coalesce(p_fee_pct, 0)) / 100 - coalesce(p_fee_pct, 0), 0), 3);
$$;

comment on function prog_suggest_margin(numeric, numeric) is
  'Backend margin % the programmatic team should target so GP / revenue ≥ target: target × (100 + fee) / 100 − fee, floored at 0. JS twin: progSuggestMargin.';

-- --------------------------------------------------------- labor primitives --
create or replace function staff_band(p_staff_id uuid, p_on date)
returns text
language sql
stable
as $$
  with rate as (select staff_hourly_cost(p_staff_id, p_on) as r),
  bands as (
    select t.ord, t.b ->> 'name' as name, nullif(t.b ->> 'upto_c', '')::bigint as upto_c
    from settings s, jsonb_array_elements(s.value) with ordinality as t(b, ord)
    where s.key = 'scope_comp_bands' and jsonb_typeof(s.value) = 'array'
  )
  select b.name from rate, bands b
  where rate.r is not null and (b.upto_c is null or rate.r <= b.upto_c)
  order by b.ord limit 1;
$$;

comment on function staff_band(uuid, date) is
  'Comp band (settings scope_comp_bands, thresholds on burdened hourly cost in cents, ascending, last open) a person falls in on a date. Null when they have no rate.';

create or replace function band_rate(p_department text, p_band text, p_on date)
returns bigint
language sql
stable
as $$
  with people as (
    select s.id, s.department, staff_hourly_cost(s.id, p_on) as rate
    from staff s
    where s.active and s.tracks_capacity and not s.exclude_hours
      and (s.start_date is null or s.start_date <= p_on)
      and (s.end_date is null or s.end_date >= p_on)
  ),
  priced as (select * from people where rate is not null),
  in_band as (
    select rate from priced p
    where p.department = p_department and p_band is not null and staff_band(p.id, p_on) = p_band
  ),
  in_dept as (select rate from priced where department = p_department)
  select coalesce(
    (select round(avg(rate))::bigint from in_band),
    (select round(avg(rate))::bigint from in_dept),
    (select round(avg(rate))::bigint from priced));
$$;

comment on function band_rate(text, text, date) is
  'Cents/hour for a placeholder: mean staff_hourly_cost of active tracks_capacity people in the department AND band on the date; falls back to the department mean, then the company mean; null if nobody can be priced. Never exposed per person.';

create or replace function hire_hourly_cost(p_department text)
returns bigint
language sql
stable
as $$
  select round(((s.value -> p_department ->> 'annual_c')::numeric) / (52 * 40))::bigint
  from settings s where s.key = 'scope_hire_costs'
    and (s.value -> p_department ->> 'annual_c') is not null;
$$;

create or replace function contractor_hourly_cost(p_department text)
returns bigint
language sql
stable
as $$
  select (s.value -> p_department ->> 'contractor_hourly_c')::bigint
  from settings s where s.key = 'scope_hire_costs'
    and (s.value -> p_department ->> 'contractor_hourly_c') is not null;
$$;

comment on function hire_hourly_cost(text) is
  'Cents/hour of a hypothetical new hire in a department: settings scope_hire_costs[dept].annual_c (the fully loaded annual cost Boris types) ÷ (52 × 40). Null until Settings has a figure for that department.';

-- -------------------------------------------------- approval guard trigger --
create or replace function scope_is_approver(p_email text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from settings s, jsonb_array_elements_text(s.value) e
    where s.key = 'scope_approver_emails' and jsonb_typeof(s.value) = 'array'
      and lower(btrim(e)) = lower(btrim(coalesce(p_email, ''))));
$$;

create or replace function scopes_status_guard()
returns trigger
language plpgsql
as $$
begin
  if new.status = 'approved' and old.status is distinct from 'approved' then
    if not scope_is_approver(new.approved_by) then
      raise exception 'only an approver (settings scope_approver_emails) can approve a scope; approved_by = %', coalesce(new.approved_by, 'null');
    end if;
    if new.approved_at is null then new.approved_at := now(); end if;
  end if;
  if new.status = 'promoted' and old.status is distinct from 'promoted' and old.status <> 'approved' then
    raise exception 'a scope must be approved before it is promoted';
  end if;
  return new;
end;
$$;

drop trigger if exists scopes_status_guard on scopes;
create trigger scopes_status_guard
  before update of status on scopes
  for each row execute function scopes_status_guard();

comment on function scopes_status_guard() is
  'Row trigger: status → approved requires approved_by in settings scope_approver_emails (holds for bare SQL and PostgREST, not only the button); promoted only from approved.';

-- -------------------------------------------------------- versions helper --
-- The payload a version stores = the editable state of the scope (row +
-- deals + lines + months + demand + supply). scope_page (097) embeds the same
-- shape, so a version can be diffed against the live scope or re-saved.
create or replace function scope_state(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
select jsonb_build_object(
  'id', s.id, 'family_id', s.family_id, 'name', s.name, 'scenario', s.scenario,
  'client_id', s.client_id, 'status', s.status, 'version', s.version,
  'approved_by', s.approved_by, 'approved_at', s.approved_at, 'promoted_at', s.promoted_at,
  'payment_net_days', s.payment_net_days, 'notes', s.notes, 'terms_text', s.terms_text,
  'set_by', s.set_by, 'set_at', s.set_at, 'created_at', s.created_at,
  'deals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', sd.id, 'ord', sd.ord, 'name', sd.name, 'origin_kind', sd.origin_kind,
      'hubspot_deal_id', sd.hubspot_deal_id, 'source_deal_id', sd.source_deal_id,
      'flight_start', sd.flight_start, 'flight_end', sd.flight_end,
      'promote_mode', sd.promote_mode, 'qbo_project_id', sd.qbo_project_id,
      'promoted_deal_id', sd.promoted_deal_id,
      'lines', coalesce((select jsonb_agg(jsonb_build_object(
          'id', sl.id, 'ord', sl.ord, 'kind', sl.kind, 'label', sl.label,
          'amount', sl.amount, 'budget', sl.budget, 'fee_pct', sl.fee_pct, 'margin_pct', sl.margin_pct,
          'rate', sl.rate, 'hours_per_month', sl.hours_per_month,
          'hours_included', sl.hours_included, 'overage_rate', sl.overage_rate,
          'media_funding', sl.media_funding, 'billing_day', sl.billing_day, 'structure', sl.structure,
          'months', coalesce((select jsonb_object_agg(slm.month::text, jsonb_build_object(
              'budget', slm.budget, 'amount', slm.amount, 'hours', slm.hours, 'drivers', slm.drivers))
              from scope_line_months slm where slm.scope_line_id = sl.id), '{}'::jsonb))
          order by sl.ord, sl.set_at) from scope_lines sl where sl.scope_deal_id = sd.id), '[]'::jsonb))
      order by sd.ord) from scope_deals sd where sd.scope_id = s.id), '[]'::jsonb),
  'dept_months', coalesce((select jsonb_agg(jsonb_build_object(
      'department', d.department, 'month', d.month, 'hours', d.hours, 'source', d.source)
      order by d.department, d.month) from scope_dept_months d where d.scope_id = s.id), '[]'::jsonb),
  'staff_months', coalesce((select jsonb_agg(jsonb_build_object(
      'id', m.id, 'staff_id', m.staff_id, 'department', m.department, 'band', m.band,
      'month', m.month, 'hours', m.hours, 'source', m.source)
      order by m.department, m.staff_id nulls last, m.month) from scope_staff_months m where m.scope_id = s.id), '[]'::jsonb)
) from scopes s where s.id = p_scope_id;
$$;

create or replace function scope_snapshot(p_scope_id uuid, p_reason text, p_label text, p_by text)
returns int
language plpgsql
as $$
declare v int;
begin
  update scopes set version = version + 1 where id = p_scope_id returning version into v;
  insert into scope_versions (scope_id, version, reason, label, payload, saved_by)
  values (p_scope_id, v, p_reason, p_label, scope_state(p_scope_id), p_by);
  return v;
end;
$$;

-- ------------------------------------------------------------- save_scope --
-- Replaces the editable state from one payload (the shape scope_state
-- returns), in one transaction, then snapshots a version. Refused for an
-- approved or promoted scope — un-approve first — and for a bad payload
-- (returns {ok:false, reason}, nothing written).
create or replace function save_scope(p_payload jsonb, p_by text, p_label text default null)
returns jsonb
language plpgsql
as $$
declare
  v_id uuid; v_status text; v_deal jsonb; v_line jsonb; v_deal_id uuid; v_line_id uuid;
  v_structure jsonb; v_margin numeric; v_fee numeric; v_share numeric; v_version int;
  k text; v jsonb; v_row jsonb;
begin
  v_id := nullif(p_payload ->> 'id', '')::uuid;
  if v_id is null then
    insert into scopes (name, scenario, client_id, payment_net_days, notes, set_by)
    values (coalesce(nullif(p_payload ->> 'name', ''), 'New scope'),
            coalesce(nullif(p_payload ->> 'scenario', ''), 'Base'),
            nullif(p_payload ->> 'client_id', '')::uuid,
            coalesce((p_payload ->> 'payment_net_days')::int, 30),
            p_payload ->> 'notes', p_by)
    returning id into v_id;
  else
    perform pg_advisory_xact_lock(hashtext('save_scope'), hashtext(v_id::text));
    select status into v_status from scopes where id = v_id for update;
    if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;
    if v_status in ('approved', 'promoted') then
      return jsonb_build_object('ok', false, 'reason', 'an ' || v_status || ' scope is read-only — un-approve it first');
    end if;
    update scopes set
      name = coalesce(nullif(p_payload ->> 'name', ''), name),
      scenario = coalesce(nullif(p_payload ->> 'scenario', ''), scenario),
      client_id = case when p_payload ? 'client_id' then nullif(p_payload ->> 'client_id', '')::uuid else client_id end,
      payment_net_days = coalesce((p_payload ->> 'payment_net_days')::int, payment_net_days),
      notes = case when p_payload ? 'notes' then p_payload ->> 'notes' else notes end,
      set_by = p_by, set_at = now()
    where id = v_id;
    delete from scope_deals where scope_id = v_id;
    delete from scope_dept_months where scope_id = v_id;
    delete from scope_staff_months where scope_id = v_id;
  end if;

  for v_deal in select * from jsonb_array_elements(coalesce(p_payload -> 'deals', '[]'::jsonb)) loop
    insert into scope_deals (id, scope_id, ord, name, origin_kind, hubspot_deal_id, source_deal_id,
                             flight_start, flight_end, promote_mode, qbo_project_id, promoted_deal_id)
    values (coalesce(nullif(v_deal ->> 'id', '')::uuid, gen_random_uuid()), v_id,
            coalesce((v_deal ->> 'ord')::int, 0),
            coalesce(nullif(v_deal ->> 'name', ''), 'Deal'),
            coalesce(v_deal ->> 'origin_kind', 'new'),
            nullif(v_deal ->> 'hubspot_deal_id', ''),
            nullif(v_deal ->> 'source_deal_id', '')::uuid,
            nullif(v_deal ->> 'flight_start', '')::date,
            nullif(v_deal ->> 'flight_end', '')::date,
            coalesce(v_deal ->> 'promote_mode', case when v_deal ->> 'origin_kind' = 'hubspot' then 'hubspot'
                                                     when v_deal ->> 'origin_kind' = 'deal' then 'extend' else 'new' end),
            nullif(v_deal ->> 'qbo_project_id', ''),
            nullif(v_deal ->> 'promoted_deal_id', '')::uuid)
    returning id into v_deal_id;

    for v_line in select * from jsonb_array_elements(coalesce(v_deal -> 'lines', '[]'::jsonb)) loop
      v_structure := coalesce(v_line -> 'structure', '{}'::jsonb);
      if jsonb_typeof(v_structure) <> 'object' then v_structure := '{}'::jsonb; end if;
      v_margin := nullif(v_line ->> 'margin_pct', '')::numeric;
      v_fee := coalesce(nullif(v_line ->> 'fee_pct', '')::numeric, 0);
      -- CPM billing is margin-only: margin_pct = 100 − platform share, fee 0,
      -- so the shared view math (gp = budget × margin, billable = budget) prices it
      if v_line ->> 'kind' = 'programmatic' and v_structure #>> '{prog,model}' = 'cpm' then
        v_share := coalesce(nullif(v_structure #>> '{prog,platform_share_pct}', '')::numeric,
                            (select (value #>> '{}')::numeric from settings where key = 'scope_cpm_platform_share_pct'), 50);
        v_margin := 100 - v_share;
        v_fee := 0;
      end if;
      insert into scope_lines (id, scope_deal_id, ord, kind, label, amount, budget, fee_pct, margin_pct, rate,
                               hours_per_month, hours_included, overage_rate, media_funding, billing_day, structure, set_by)
      values (coalesce(nullif(v_line ->> 'id', '')::uuid, gen_random_uuid()), v_deal_id,
              coalesce((v_line ->> 'ord')::int, 0),
              (v_line ->> 'kind')::line_kind,
              nullif(v_line ->> 'label', ''),
              coalesce((v_line ->> 'amount')::bigint, 0),
              coalesce((v_line ->> 'budget')::bigint, 0),
              v_fee, v_margin,
              coalesce((v_line ->> 'rate')::bigint, 0),
              coalesce((v_line ->> 'hours_per_month')::numeric, 0),
              nullif(v_line ->> 'hours_included', '')::numeric,
              nullif(v_line ->> 'overage_rate', '')::bigint,
              coalesce(nullif(v_line ->> 'media_funding', ''), 'client')::media_funding,
              coalesce(nullif(v_line ->> 'billing_day', ''),
                       case when v_line ->> 'kind' in ('retainer', 'creative', 'custom') then 'first' else 'last' end)::billing_day,
              v_structure, p_by)
      returning id into v_line_id;

      if jsonb_typeof(v_line -> 'months') = 'object' then
        for k, v in select * from jsonb_each(v_line -> 'months') loop
          insert into scope_line_months (scope_line_id, month, budget, amount, hours, drivers)
          values (v_line_id, k::date,
                  nullif(v ->> 'budget', '')::bigint, nullif(v ->> 'amount', '')::bigint,
                  nullif(v ->> 'hours', '')::numeric,
                  case when jsonb_typeof(v -> 'drivers') = 'object' then v -> 'drivers' end);
        end loop;
      end if;
    end loop;
  end loop;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload -> 'dept_months', '[]'::jsonb)) loop
    insert into scope_dept_months (scope_id, department, month, hours, source)
    values (v_id, v_row ->> 'department', (v_row ->> 'month')::date,
            coalesce((v_row ->> 'hours')::numeric, 0), coalesce(v_row ->> 'source', 'manual'))
    on conflict (scope_id, department, month) do update set hours = excluded.hours, source = excluded.source;
  end loop;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload -> 'staff_months', '[]'::jsonb)) loop
    if coalesce((v_row ->> 'hours')::numeric, 0) <= 0 then continue; end if;
    insert into scope_staff_months (scope_id, staff_id, department, band, month, hours, source)
    values (v_id, nullif(v_row ->> 'staff_id', '')::uuid, v_row ->> 'department',
            nullif(v_row ->> 'band', ''), (v_row ->> 'month')::date,
            (v_row ->> 'hours')::numeric, coalesce(v_row ->> 'source', 'manual'));
  end loop;

  v_version := scope_snapshot(v_id, 'save', p_label, p_by);
  return jsonb_build_object('ok', true, 'scope_id', v_id, 'version', v_version);
exception when others then
  return jsonb_build_object('ok', false, 'reason', sqlerrm);
end;
$$;

comment on function save_scope(jsonb, text, text) is
  'Atomic save of one scope from the scope_state shape: replaces deals/lines/months/demand/supply, normalises CPM programmatic lines (margin = 100 − share, fee 0), bumps version and appends a scope_versions row with the label. Refused ({ok:false}) for approved/promoted scopes and for invalid payloads — nothing is written then.';

-- ------------------------------------------------------------ create_scope --
-- Seeds a scope from its entry point and returns {ok, scope_id}.
--   hubspot   p_ref = hubspot_deal_id: flight + lines from the mirror row via
--             hs_flight_lines (the ONE copy of the flighting math, 078)
--   deal      p_ref = deals.id: copies its lines + months, prefills demand and
--             supply from the trailing actuals of the people who work it
--   new       blank, one empty deal
--   client    p_ref = clients.id: blank, on that client
--   scenario  p_ref = scopes.id: deep copy into the same family, status draft
create or replace function create_scope(p_origin_kind text, p_ref text, p_name text, p_by text, p_scenario text default null)
returns jsonb
language plpgsql
as $$
declare
  v_id uuid; v_deal_id uuid; v_line_id uuid; m pipeline_deals%rowtype; d deals%rowtype; src scopes%rowtype;
  v_fl jsonb; ln jsonb; v_client uuid; v_name text; r record; v_cur date := date_trunc('month', current_date)::date;
  v_lookback int; v_state jsonb;
begin
  if p_origin_kind = 'hubspot' then
    select * into m from pipeline_deals where hubspot_deal_id = p_ref;
    if not found then return jsonb_build_object('ok', false, 'reason', 'not in the HubSpot mirror'); end if;
    select client_id into v_client from promotion_approvals where hubspot_deal_id = p_ref;
    if v_client is null then
      select c.id into v_client from clients c
      where lower(c.name) = lower(coalesce(m.company, '')) limit 1;
    end if;
    if v_client is null then
      select ca.client_id into v_client from client_aliases ca
      where lower(ca.alias) = lower(coalesce(m.company, '')) limit 1;
    end if;
    v_name := coalesce(nullif(p_name, ''), nullif(m.name, ''), 'HubSpot deal');
    insert into scopes (name, scenario, client_id, set_by) values (v_name, coalesce(p_scenario, 'Base'), v_client, p_by) returning id into v_id;
    insert into scope_deals (scope_id, ord, name, origin_kind, hubspot_deal_id, flight_start, flight_end, promote_mode)
    values (v_id, 0, v_name, 'hubspot', m.hubspot_deal_id, m.campaign_start, m.campaign_end, 'hubspot')
    returning id into v_deal_id;
    if m.campaign_start is not null and m.campaign_end is not null then
      v_fl := hs_flight_lines(m.line_items, date_trunc('month', m.campaign_start)::date, date_trunc('month', m.campaign_end)::date);
      for ln in select value from jsonb_array_elements(coalesce(v_fl -> 'lines', '[]'::jsonb)) loop
        insert into scope_lines (scope_deal_id, ord, kind, amount, budget, fee_pct, billing_day, set_by)
        values (v_deal_id, (select count(*) from scope_lines where scope_deal_id = v_deal_id),
                (ln ->> 'kind')::line_kind, (ln ->> 'amount')::bigint, 0, (ln ->> 'fee_pct')::numeric,
                (case when ln ->> 'kind' = 'retainer' then 'first' else 'last' end)::billing_day, 'create:hubspot')
        returning id into v_line_id;
        if jsonb_typeof(ln -> 'months') = 'object' then
          insert into scope_line_months (scope_line_id, month, budget)
          select v_line_id, key::date, (value #>> '{}')::bigint from jsonb_each(ln -> 'months');
        end if;
      end loop;
      if v_fl ->> 'reason' is not null then
        update scopes set notes = 'HubSpot line items: ' || (v_fl ->> 'reason') where id = v_id;
      end if;
    end if;

  elsif p_origin_kind = 'deal' then
    select * into d from deals where id = p_ref::uuid;
    if not found then return jsonb_build_object('ok', false, 'reason', 'deal not found'); end if;
    v_name := coalesce(nullif(p_name, ''), d.name || ' — re-scope');
    insert into scopes (name, scenario, client_id, set_by) values (v_name, coalesce(p_scenario, 'Base'), d.client_id, p_by) returning id into v_id;
    insert into scope_deals (scope_id, ord, name, origin_kind, source_deal_id, flight_start, flight_end, promote_mode, qbo_project_id)
    values (v_id, 0, d.name, 'deal', d.id, d.flight_start, d.flight_end, 'extend', d.qbo_project_id)
    returning id into v_deal_id;
    for r in select * from deal_lines where deal_id = d.id order by set_at, id loop
      insert into scope_lines (scope_deal_id, ord, kind, label, amount, budget, fee_pct, margin_pct, rate, hours_per_month,
                               media_funding, billing_day, set_by)
      values (v_deal_id, (select count(*) from scope_lines where scope_deal_id = v_deal_id),
              r.kind, r.label, r.amount, r.budget, r.fee_pct, r.margin_pct, r.rate, r.hours_per_month,
              r.media_funding, r.billing_day, 'create:deal')
      returning id into v_line_id;
      insert into scope_line_months (scope_line_id, month, budget, amount, hours)
      select v_line_id, month, budget, amount, hours from deal_line_months where deal_line_id = r.id;
    end loop;
    -- who works it today: the seed's own averaging rule (095), per person,
    -- for every flight month from this one on; demand = the department sums
    v_lookback := coalesce((select (value #>> '{}')::int from settings where key = 'assignments_seed_lookback_months'), 3);
    insert into scope_staff_months (scope_id, staff_id, department, month, hours, source)
    select v_id, b.staff_id, coalesce(s.department, '(no department)'), gs::date, b.avg_hours, 'manual'
    from assignments_seed_basis(v_lookback) b
    join staff s on s.id = b.staff_id
    cross join lateral generate_series(greatest(v_cur, date_trunc('month', d.flight_start)::date),
                                       date_trunc('month', d.flight_end), interval '1 month') gs
    where b.deal_id = d.id and d.flight_end >= v_cur;
    insert into scope_dept_months (scope_id, department, month, hours, source)
    select scope_id, department, month, sum(hours), 'actuals'
    from scope_staff_months where scope_id = v_id group by scope_id, department, month;

  elsif p_origin_kind = 'client' then
    select id into v_client from clients where id = p_ref::uuid;
    if v_client is null then return jsonb_build_object('ok', false, 'reason', 'client not found'); end if;
    v_name := coalesce(nullif(p_name, ''), (select name from clients where id = v_client) || ' — scope');
    insert into scopes (name, scenario, client_id, set_by) values (v_name, coalesce(p_scenario, 'Base'), v_client, p_by) returning id into v_id;
    insert into scope_deals (scope_id, ord, name, origin_kind, promote_mode) values (v_id, 0, v_name, 'new', 'new');

  elsif p_origin_kind = 'scenario' then
    select * into src from scopes where id = p_ref::uuid;
    if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;
    v_state := scope_state(src.id);
    -- strip ids so save_scope inserts fresh rows into the same family
    v_state := v_state - 'id' - 'status' - 'version' - 'approved_by' - 'approved_at' - 'promoted_at' - 'terms_text';
    v_state := jsonb_set(v_state, '{scenario}', to_jsonb(coalesce(nullif(p_scenario, ''),
                 'Scenario ' || ((select count(*) + 1 from scopes where family_id = src.family_id)::text))));
    if p_name is not null and p_name <> '' then v_state := jsonb_set(v_state, '{name}', to_jsonb(p_name)); end if;
    v_state := jsonb_set(v_state, '{deals}', (
      select coalesce(jsonb_agg((dl - 'id' - 'promoted_deal_id') || jsonb_build_object('lines',
        (select coalesce(jsonb_agg(l - 'id'), '[]'::jsonb) from jsonb_array_elements(dl -> 'lines') l))), '[]'::jsonb)
      from jsonb_array_elements(v_state -> 'deals') dl));
    v_state := jsonb_set(v_state, '{staff_months}', (
      select coalesce(jsonb_agg(sm - 'id'), '[]'::jsonb) from jsonb_array_elements(v_state -> 'staff_months') sm));
    v_fl := save_scope(v_state, p_by, 'scenario of ' || src.scenario);
    if not (v_fl ->> 'ok')::boolean then return v_fl; end if;
    v_id := (v_fl ->> 'scope_id')::uuid;
    update scopes set family_id = src.family_id where id = v_id;
    return jsonb_build_object('ok', true, 'scope_id', v_id);

  else
    v_name := coalesce(nullif(p_name, ''), 'New scope');
    insert into scopes (name, scenario, set_by) values (v_name, coalesce(p_scenario, 'Base'), p_by) returning id into v_id;
    insert into scope_deals (scope_id, ord, name, origin_kind, promote_mode) values (v_id, 0, v_name, 'new', 'new');
  end if;

  perform scope_snapshot(v_id, 'save', 'created from ' || p_origin_kind, p_by);
  return jsonb_build_object('ok', true, 'scope_id', v_id);
end;
$$;

comment on function create_scope(text, text, text, text, text) is
  'Seeds a scope from its entry point (hubspot mirror row via hs_flight_lines; existing deal with lines + trailing-actual staffing; blank; client; or a scenario copy into the same family) and snapshots version 1. Returns {ok, scope_id}.';
