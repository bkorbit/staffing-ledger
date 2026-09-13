-- ============================================================================
--  098 — The product catalog: one table behind HubSpot line items, QuickBooks
--  invoice items and the default hours a product takes.
--
--  Until now the HubSpot item names were a hardcoded VALUES list inside
--  hs_line_item_map (078) and the two human tables from 001 (item_map,
--  line_item_map) were never read. A different agency has different products,
--  and EMG's own list changes — so the catalog moves into Settings:
--
--    products         what EMG sells, in ledger terms: name, line kind, role
--                     (budget | fee | flat | amount — the same roles 001's maps
--                     used), the department that usually does it, and default
--                     hours by department: setup_hours (one-off, first flight
--                     month) and monthly_hours (every flight month). Analytics
--                     and Creative work is scoped from these (099 adds them to
--                     the demand grid), refined by benchmarks where a deal has
--                     logged hours against such a line.
--    product_aliases  how each SOURCE spells a product: source hubspot | qbo,
--                     external_name (matched on the segment after the last
--                     colon, trimmed, lowercased — HubSpot names arrive
--                     folder-prefixed), product_id, and EXCLUDED. An excluded
--                     alias is a human decision that the item is not a ledger
--                     line at all (a travel reimbursement, a pass-through
--                     nobody scopes): hs_flight_lines skips it silently and
--                     flights the rest. An UNMAPPED name still blocks the
--                     whole flighting, as 078 decided — silence there would
--                     hide a real product.
--
--  hs_line_item_map(p_name) is rewritten to read the aliases (STABLE now, not
--  IMMUTABLE — it reads a table). hs_flight_lines is reproduced WHOLE from 078
--  with one change, marked `098`: excluded items are dropped before the
--  unmapped check and the aggregation. Everything 078_fixture_test asserts
--  still holds (re-run it after this migration in the bed).
--
--  Seeded with the twelve names 078 carried, as both hubspot and qbo aliases
--  (Boris: the QuickBooks item names are mostly the same). Edited on
--  Settings › Scoping.
--
--  Fixture: db/098_fixture_test.sql (+ re-run 078_fixture_test.sql).
-- ============================================================================

create table if not exists products (
  id            uuid primary key default gen_random_uuid(),
  name          text not null unique,
  kind          line_kind not null,
  role          text not null check (role in ('budget', 'fee', 'flat', 'amount')),
  department    text,
  setup_hours   jsonb not null default '{}'::jsonb,    -- {"Analytics": 8}  one-off, first flight month
  monthly_hours jsonb not null default '{}'::jsonb,    -- {"Analytics": 2}  every flight month
  active        boolean not null default true,
  set_by        text,
  set_at        timestamptz not null default now()
);

create table if not exists product_aliases (
  id            uuid primary key default gen_random_uuid(),
  source        text not null check (source in ('hubspot', 'qbo')),
  external_name text not null,
  product_id    uuid references products(id) on delete set null,
  excluded      boolean not null default false,
  set_by        text,
  set_at        timestamptz not null default now()
);
create unique index if not exists product_aliases_source_name_uidx on product_aliases (source, lower(btrim(external_name)));

do $$
declare t text;
begin
  foreach t in array array['products', 'product_aliases'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_auth_all', t);
    execute format('create policy %I on %I for all to authenticated using (true) with check (true)', t || '_auth_all', t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
  end loop;
end $$;

comment on table products is
  'The catalog: what is sold, as a ledger line kind + role, with the default hours it takes by department (setup once, monthly every flight month). Human-owned, edited on Settings › Scoping. hs_line_item_map and scope_estimate_hours read it.';
comment on table product_aliases is
  'How each source (hubspot | qbo) spells a product. excluded = not a ledger line at all: hs_flight_lines skips it silently. An unmapped name still blocks flighting (078).';

-- the twelve names 078 carried, as products + hubspot + qbo aliases
insert into products (name, kind, role, department, set_by) values
  ('Programmatic media',      'programmatic', 'budget', 'Programmatic',        'migration-098'),
  ('Programmatic buying fee', 'programmatic', 'fee',    'Programmatic',        'migration-098'),
  ('Paid search media',       'search',       'budget', 'Paid Media',          'migration-098'),
  ('Paid search fee',         'search',       'fee',    'Paid Media',          'migration-098'),
  ('Paid social media',       'social',       'budget', 'Paid Media',          'migration-098'),
  ('Paid social fee',         'social',       'fee',    'Paid Media',          'migration-098'),
  ('Paid search hourly',      'retainer',     'flat',   'Paid Media',          'migration-098'),
  ('Paid social hourly',      'retainer',     'flat',   'Paid Media',          'migration-098'),
  ('Creative retainer',       'retainer',     'flat',   'Creative',            'migration-098'),
  ('Creative services',       'retainer',     'flat',   'Creative',            'migration-098'),
  ('Planning',                'retainer',     'flat',   'Planning & Strategy', 'migration-098'),
  ('Dashboard',               'retainer',     'flat',   'Analytics',           'migration-098')
on conflict (name) do nothing;

insert into product_aliases (source, external_name, product_id, set_by)
select s.source, p.name, p.id, 'migration-098'
from products p cross join (values ('hubspot'), ('qbo')) s(source)
where p.set_by = 'migration-098'
on conflict do nothing;

-- ---------------------------------------------------------------------------
--  hs_line_item_map: the same answer shape as 078, from the catalog.
-- ---------------------------------------------------------------------------
create or replace function hs_line_item_map(p_name text)
returns text[]
language sql
stable
as $$
  select array[p.kind::text, p.role]
  from product_aliases a
  join products p on p.id = a.product_id
  where a.source = 'hubspot' and not a.excluded and p.active
    -- both sides lose their folder prefix, so an alias typed with or without
    -- "Media:" matches an item that arrives with or without it
    and lower(btrim(regexp_replace(a.external_name, '^.*:', ''))) = lower(btrim(regexp_replace(coalesce(p_name, ''), '^.*:', '')))
  limit 1;
$$;

comment on function hs_line_item_map(text) is
  'HubSpot line-item product name -> ARRAY[ledger kind, role] (budget|fee|flat|amount) from product_aliases (source hubspot) + products, or null when unmapped or excluded. Matches the segment after the last colon, case- and whitespace-insensitive. 098: reads the catalog instead of a hardcoded list.';

create or replace function hs_line_item_excluded(p_name text)
returns boolean
language sql
stable
as $$
  select exists (
    select 1 from product_aliases a
    where a.source = 'hubspot' and a.excluded
      and lower(btrim(regexp_replace(a.external_name, '^.*:', ''))) = lower(btrim(regexp_replace(coalesce(p_name, ''), '^.*:', ''))));
$$;

comment on function hs_line_item_excluded(text) is
  'True when a human marked this HubSpot item name excluded in the catalog: hs_flight_lines drops it silently instead of blocking the flight.';

-- ---------------------------------------------------------------------------
--  hs_flight_lines: 078 verbatim, except `098` — excluded items are dropped
--  before the unmapped check and before the aggregation.
-- ---------------------------------------------------------------------------
create or replace function hs_flight_lines(p_items jsonb, p_start date, p_end date)
returns jsonb
language plpgsql
stable
as $$
declare
  v_months  date[];
  v_n       int;
  v_unmapped text;
  v_lines   jsonb := '[]'::jsonb;
  v_months_obj jsonb;
  v_per     bigint;
  v_flat    bigint;
  v_items   jsonb;
  r         record;
  i         int;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('lines', '[]'::jsonb, 'reason', 'no line items');
  end if;

  -- 098: an item a human excluded in the catalog is not a ledger line; drop it
  -- here so it neither blocks nor flights
  select coalesce(jsonb_agg(li order by ord), '[]'::jsonb) into v_items
  from jsonb_array_elements(p_items) with ordinality as t(li, ord)
  where not hs_line_item_excluded(li->>'name');
  if jsonb_array_length(v_items) = 0 then
    return jsonb_build_object('lines', '[]'::jsonb, 'reason', 'every line item is excluded in the catalog');
  end if;

  -- the covered months, first-of-month, capped at 48 the way the JS was
  -- (a runaway flight should not write four years of override rows)
  select array_agg(m order by m) into v_months
  from (
    select g::date as m
    from generate_series(date_trunc('month', p_start), date_trunc('month', p_end), interval '1 month') g
    limit 48
  ) s;
  v_n := coalesce(array_length(v_months, 1), 0);
  if v_n = 0 then
    return jsonb_build_object('lines', '[]'::jsonb, 'reason', 'no flight months');
  end if;

  -- one unmapped item and nothing is flighted; name the first one, in item order
  select li->>'name' into v_unmapped
  from jsonb_array_elements(v_items) with ordinality as t(li, ord)
  where hs_line_item_map(li->>'name') is null
  order by ord
  limit 1;
  if found then
    return jsonb_build_object('lines', '[]'::jsonb,
      'reason', 'unmapped line item: ' || coalesce(nullif(v_unmapped, ''), '?'));
  end if;

  for r in
    select (hs_line_item_map(x.name))[1] as kind,
           sum(case when (hs_line_item_map(x.name))[2] = 'budget' then x.cents else 0 end) as budget,
           sum(case when (hs_line_item_map(x.name))[2] = 'fee'    then x.cents else 0 end) as fee,
           sum(case when (hs_line_item_map(x.name))[2] in ('flat', 'amount') then x.cents else 0 end) as flat
    from (
      select li->>'name' as name,
             -- a non-numeric amount is worth zero, not an aborted promotion
             case when coalesce(li->>'amount', '') ~ '^\s*-?\d+(\.\d+)?\s*$'
                  then round(btrim(li->>'amount')::numeric * 100)::bigint
                  else 0 end as cents,
             ord
      from jsonb_array_elements(v_items) with ordinality as t(li, ord)
    ) x
    group by 1
    order by min(x.ord)
  loop
    if r.kind = 'retainer' then
      -- everything retainer-ish is one flat monthly figure, whatever role it arrived in
      v_flat := r.flat + r.fee + r.budget;
      if v_flat > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'kind', 'retainer', 'amount', round(v_flat::numeric / v_n),
          'fee_pct', 0, 'months', null));
      end if;
    elsif r.budget > 0 then
      v_per := floor(r.budget::numeric / v_n)::bigint;
      v_months_obj := '{}'::jsonb;
      for i in 1 .. v_n loop
        v_months_obj := v_months_obj || jsonb_build_object(
          to_char(v_months[i], 'YYYY-MM-DD'),
          case when i = v_n then r.budget - v_per * (v_n - 1) else v_per end);
      end loop;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'kind', r.kind, 'amount', 0,
        'fee_pct', case when r.fee > 0 then round(r.fee::numeric / r.budget * 100, 2) else 0 end,
        'months', v_months_obj));
    elsif r.fee > 0 then
      -- a fee with no media: a flat monthly amount is the honest shape
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'kind', 'retainer', 'amount', round(r.fee::numeric / v_n),
        'fee_pct', 0, 'months', null));
    end if;
  end loop;

  if jsonb_array_length(v_lines) = 0 then
    return jsonb_build_object('lines', '[]'::jsonb, 'reason', 'items sum to nothing');
  end if;
  return jsonb_build_object('lines', v_lines, 'reason', null);
end;
$$;

comment on function hs_flight_lines(jsonb, date, date) is
  'HubSpot line items -> {lines, reason} for the promotion door''s automatic flighting. 098: items excluded in the catalog are dropped first; one UNMAPPED item still means no lines. Budgets spread evenly with the remainder on the last month. The single implementation (078). Cases: db/078_fixture_test.sql + db/098_fixture_test.sql.';
