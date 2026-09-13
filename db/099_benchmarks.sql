-- ============================================================================
--  099 — The benchmark library: real campaigns → hours per driver → the hours a
--  new scope will take.
--
--  Estimating hours is the hardest part of scoping. The model here is built
--  from EMG's own campaigns, in the platform: a human ENROLS a live deal,
--  picks the platforms it runs on, assigns each platform to a TEAM (a
--  staff.department — Paid Media pools search and social), and uploads the
--  platform exports. The browser parses them (app/assets/parsers/*) into
--  per-month DRIVER counts — things that move hours: change events, live
--  campaigns / ad sets / ad groups, ads live and refreshed, spend, markets,
--  platforms, meetings, reports, creatives delivered. Nothing is invented on
--  the server: uploads land as they were parsed, and the actual hours are
--  joined from time_entries at read time (never copied), using the same rule
--  hours_page counts by (attribution not excluded / timeoff, 090/091), only
--  for months already over (measured = month fully over).
--
--    benchmark_deals          the curated library: only enrolled deals count
--    benchmark_uploads        one per (deal, platform, team) upload — a
--                             re-upload of the same platform + team REPLACES
--                             the previous one, so a fixed export never
--                             double-counts
--    benchmark_upload_months  the parsed driver counts per month per upload
--    v_benchmark_observations drivers summed per (deal, department, month)
--                             across that department's platforms
--    v_benchmark_observed     + the department's counted hours that month,
--                             the deal's line kinds and client — the rows
--                             every coefficient is fitted on
--
--  benchmark_coefficients(kind, department, client) — per driver key: n,
--    deals, hours_per_unit = Σhours / Σdriver (the ratio estimator: robust
--    at small n, and the number a person can sanity-check), plus regression
--    slope / intercept / r² and the driver's mean / sd for the comparables.
--    CLIENT-SPECIFIC first: when the client has ≥ 2 observations for that
--    kind and department, its own coefficients are used (Boris).
--  benchmark_comparables(kind, department, drivers) — the nearest real
--    campaign-months by standardised distance over the shared driver keys.
--  benchmark_models — a fitted multi-driver model per (department, kinds),
--    fitted client-side (scope-math.js fitModel, non-negative least squares)
--    once a department has enough observations, saved through
--    save_benchmark_model; the estimator prefers it when present.
--  scope_estimate_hours(scope_id, by) — for every scope line month that
--    carries drivers: per department, model estimate if a model exists,
--    otherwise the MEDIAN of the single-driver estimates (driver ×
--    hours_per_unit) over the drivers both sides know — an ensemble of
--    proxies for the same hours. Catalog products on a line (structure.
--    products) add their setup hours (first flight month) and monthly hours.
--    Writes scope_dept_months with source benchmark / catalog; a MANUAL row
--    is never overwritten. quick_check (097) is rewritten whole to estimate
--    hours the same way when the caller types none.
--  benchmark_page() — everything the bench mode shows in one payload.
--
--  Fixture: db/099_fixture_test.sql. Parsers: app/assets/parsers/.
-- ============================================================================

insert into settings (key, value, set_by) values
  ('scope_platform_team_defaults',
   '{"google_ads":"Paid Media","meta":"Paid Media","dsp":"Programmatic","calendar":"Planning & Strategy","reporting":"Planning & Strategy","creative":"Creative"}'::jsonb,
   'migration-099'),
  ('scope_driver_order',
   '["changes","active_campaigns","ad_sets","ad_groups","ads_live","creatives_refreshed","spend","markets","platforms","meetings","reports","creatives_delivered"]'::jsonb,
   'migration-099'),
  ('scope_model_min_observations', '12'::jsonb, 'migration-099')
on conflict (key) do nothing;

create table if not exists benchmark_deals (
  deal_id     uuid primary key references deals(id) on delete cascade,
  enrolled_by text,
  enrolled_at timestamptz not null default now(),
  notes       text
);

create table if not exists benchmark_uploads (
  id          uuid primary key default gen_random_uuid(),
  deal_id     uuid not null references deals(id) on delete cascade,
  platform    text not null check (platform in ('google_ads', 'meta', 'dsp', 'calendar', 'reporting', 'creative', 'other')),
  department  text not null,
  filename    text,
  parser      text,
  month_from  date,
  month_to    date,
  row_count   int,
  summary     jsonb,
  uploaded_by text,
  uploaded_at timestamptz not null default now()
);
create index if not exists benchmark_uploads_deal_idx on benchmark_uploads (deal_id, department, platform);

create table if not exists benchmark_upload_months (
  upload_id uuid not null references benchmark_uploads(id) on delete cascade,
  month     date not null,
  drivers   jsonb not null default '{}'::jsonb,
  primary key (upload_id, month),
  check (month = date_trunc('month', month)::date)
);

create table if not exists benchmark_models (
  id           uuid primary key default gen_random_uuid(),
  department   text not null,
  kinds        text[] not null,
  coefficients jsonb not null,      -- {"intercept": h, "changes": h_per_unit, ...}
  n            int,
  r2           numeric,
  fitted_by    text,
  fitted_at    timestamptz not null default now(),
  unique (department, kinds)
);

do $$
declare t text;
begin
  foreach t in array array['benchmark_deals', 'benchmark_uploads', 'benchmark_upload_months', 'benchmark_models'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists %I on %I', t || '_auth_all', t);
    execute format('create policy %I on %I for all to authenticated using (true) with check (true)', t || '_auth_all', t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
    execute format('grant all on %I to service_role', t);
  end loop;
end $$;

comment on table benchmark_uploads is
  'One parsed platform export for one enrolled deal, assigned to one team (department). Re-uploading the same deal + platform + department replaces the earlier upload. Raw files are not stored; the browser parses them.';
comment on table benchmark_upload_months is
  'Per-month driver counts of one upload: {"changes": 210, "active_campaigns": 12, "spend": 8500000, ...} (spend in cents).';

-- ---------------------------------------------------------------------------
--  the observations: drivers summed per (deal, department, month), then joined
--  to counted hours for closed months
-- ---------------------------------------------------------------------------
create or replace view v_benchmark_observations as
select u.deal_id, u.department, um.month,
       (select jsonb_object_agg(k, v) from (
          select kv.key as k, sum((kv.value)::numeric) as v
          from benchmark_uploads u2
          join benchmark_upload_months um2 on um2.upload_id = u2.id
          cross join lateral jsonb_each_text(um2.drivers) kv
          where u2.deal_id = u.deal_id and u2.department = u.department and um2.month = um.month
            and kv.value ~ '^-?\d+(\.\d+)?$'
          group by kv.key) x) as drivers,
       count(distinct u.platform) as platforms
from benchmark_uploads u
join benchmark_upload_months um on um.upload_id = u.id
group by u.deal_id, u.department, um.month;

create or replace view v_benchmark_observed as
select o.deal_id, d.name as deal_name, d.client_id, o.department, o.month,
       o.drivers || jsonb_build_object('platforms', o.platforms) as drivers,
       coalesce((select sum(te.hours) from time_entries te
                 left join staff s on s.id = te.staff_id
                 where te.deal_id = o.deal_id
                   and te.worked_on >= o.month and te.worked_on < (o.month + interval '1 month')::date
                   and coalesce(s.department, te.department, '(no department)') = o.department
                   and coalesce(te.attribution, '') not in ('excluded', 'timeoff')), 0)::numeric as hours,
       coalesce((select array_agg(distinct dl.kind::text order by dl.kind::text) from deal_lines dl where dl.deal_id = o.deal_id), '{}'::text[]) as deal_kinds
from v_benchmark_observations o
join benchmark_deals bd on bd.deal_id = o.deal_id
join deals d on d.id = o.deal_id
where o.month < date_trunc('month', current_date)::date;

comment on view v_benchmark_observed is
  'The rows every benchmark coefficient is fitted on: enrolled deals only, closed months only, drivers summed across the department''s platforms, hours = the department''s counted time_entries that month (090/091 rule; 0 when none), deal_kinds, client_id.';

-- ---------------------------------------------------------------------------
--  record_benchmark_observations: one upload + its months, replacing any
--  earlier upload of the same deal + platform + department
-- ---------------------------------------------------------------------------
create or replace function record_benchmark_observations(p_upload jsonb, p_rows jsonb, p_by text)
returns jsonb
language plpgsql
as $$
declare
  v_deal uuid := (p_upload ->> 'deal_id')::uuid;
  v_platform text := p_upload ->> 'platform';
  v_dept text := p_upload ->> 'department';
  v_id uuid; v_n int := 0; v_replaced int; r jsonb;
begin
  if v_deal is null or v_platform is null or v_dept is null then
    return jsonb_build_object('ok', false, 'reason', 'deal_id, platform and department are required');
  end if;
  insert into benchmark_deals (deal_id, enrolled_by) values (v_deal, p_by) on conflict (deal_id) do nothing;
  with del as (delete from benchmark_uploads where deal_id = v_deal and platform = v_platform and department = v_dept returning 1)
  select count(*) into v_replaced from del;
  insert into benchmark_uploads (deal_id, platform, department, filename, parser, month_from, month_to, row_count, summary, uploaded_by)
  select v_deal, v_platform, v_dept, p_upload ->> 'filename', p_upload ->> 'parser',
         (select min((x ->> 'month')::date) from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x),
         (select max((x ->> 'month')::date) from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) x),
         (p_upload ->> 'row_count')::int, p_upload -> 'summary', p_by
  returning id into v_id;
  for r in select value from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) loop
    if jsonb_typeof(r -> 'drivers') <> 'object' then continue; end if;
    insert into benchmark_upload_months (upload_id, month, drivers)
    values (v_id, date_trunc('month', (r ->> 'month')::date)::date, r -> 'drivers')
    on conflict (upload_id, month) do update set drivers = benchmark_upload_months.drivers || excluded.drivers;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('ok', true, 'upload_id', v_id, 'months_written', v_n, 'replaced', v_replaced);
end;
$$;

comment on function record_benchmark_observations(jsonb, jsonb, text) is
  'Stores one parsed upload ({deal_id, platform, department, filename, parser, row_count, summary}) and its months ([{month, drivers}]), enrolling the deal, replacing any earlier upload of the same deal + platform + department.';

-- ---------------------------------------------------------------------------
--  coefficients: per driver key, for one kind × department (client first)
-- ---------------------------------------------------------------------------
create or replace function benchmark_coefficients(p_kind text, p_department text, p_client_id uuid default null)
returns jsonb
language sql
stable
as $$
with base as (
  select * from v_benchmark_observed o
  where o.department = p_department and p_kind = any(o.deal_kinds)
),
client_n as (select count(*) as n from base where p_client_id is not null and client_id = p_client_id),
pick as (
  select case when (select n from client_n) >= 2 then 'client' else 'company' end as scope
),
rows_ as (
  select b.* from base b
  where (select scope from pick) = 'company' or b.client_id = p_client_id
),
kv as (
  select r.deal_id, r.month, r.hours, e.key as driver, (e.value)::numeric as x
  from rows_ r cross join lateral jsonb_each_text(r.drivers) e
  where e.value ~ '^-?\d+(\.\d+)?$'
),
per_driver as (
  select driver,
         count(*) as n, count(distinct deal_id) as deals_n,
         sum(hours) as sum_hours, sum(x) as sum_x,
         -- 8 dp: spend is in cents, so hours per cent is ~0.00003 — 4 dp would round it to nothing
         case when sum(x) > 0 then round(sum(hours) / sum(x), 8) end as hours_per_unit,
         round(regr_slope(hours, x)::numeric, 4) as slope,
         round(regr_intercept(hours, x)::numeric, 4) as intercept,
         round(regr_r2(hours, x)::numeric, 4) as r2,
         round(avg(x), 4) as mean_x, round(coalesce(stddev_samp(x), 0), 4) as sd_x
  from kv group by driver
)
select jsonb_build_object(
  'kind', p_kind, 'department', p_department,
  'scope', (select scope from pick),
  'n', (select count(*) from rows_),
  'deals_n', (select count(distinct deal_id) from rows_),
  'base_hours_per_month', (select round(avg(hours), 2) from rows_),
  'drivers', coalesce((select jsonb_agg(jsonb_build_object(
      'driver', driver, 'n', n, 'deals_n', deals_n, 'hours_per_unit', hours_per_unit,
      'slope', slope, 'intercept', intercept, 'r2', r2, 'mean', mean_x, 'sd', sd_x)
      order by driver) from per_driver where sum_x > 0), '[]'::jsonb));
$$;

comment on function benchmark_coefficients(text, text, uuid) is
  'Hours-per-driver coefficients for one line kind × department from v_benchmark_observed, client-specific when the client has ≥ 2 observations: per driver n, deals, hours_per_unit = Σhours/Σdriver (the ratio estimator), regression slope/intercept/r², mean, sd.';

create or replace function benchmark_comparables(p_kind text, p_department text, p_drivers jsonb, p_limit int default 8)
returns jsonb
language sql
stable
as $$
with base as (
  select * from v_benchmark_observed o where o.department = p_department and p_kind = any(o.deal_kinds)
),
keys as (
  select e.key, (e.value)::numeric as target
  from jsonb_each_text(coalesce(p_drivers, '{}'::jsonb)) e where e.value ~ '^-?\d+(\.\d+)?$'
),
sd as (
  select k.key, nullif(stddev_samp((b.drivers ->> k.key)::numeric), 0) as sd
  from keys k join base b on (b.drivers ->> k.key) ~ '^-?\d+(\.\d+)?$'
  group by k.key
),
dist as (
  select b.deal_id, b.deal_name, b.month, b.hours, b.drivers,
         sqrt(sum(power(((b.drivers ->> k.key)::numeric - k.target) / coalesce(s.sd, 1), 2))) as distance,
         count(*) as shared
  from base b
  join keys k on (b.drivers ->> k.key) ~ '^-?\d+(\.\d+)?$'
  left join sd s on s.key = k.key
  group by b.deal_id, b.deal_name, b.month, b.hours, b.drivers
)
select coalesce((select jsonb_agg(jsonb_build_object(
    'deal_id', deal_id, 'deal_name', deal_name, 'month', month, 'hours', hours, 'drivers', drivers,
    'distance', round(distance, 3), 'shared', shared)
    order by distance, month desc) from (select * from dist order by distance, month desc limit greatest(p_limit, 1)) t), '[]'::jsonb);
$$;

comment on function benchmark_comparables(text, text, jsonb, int) is
  'The nearest real campaign-months for a set of expected drivers: standardised Euclidean distance over the driver keys both sides have.';

create or replace function save_benchmark_model(p_department text, p_kinds text[], p_coefficients jsonb, p_n int, p_r2 numeric, p_by text)
returns jsonb
language plpgsql
as $$
declare v_id uuid;
begin
  insert into benchmark_models (department, kinds, coefficients, n, r2, fitted_by)
  values (p_department, p_kinds, p_coefficients, p_n, p_r2, p_by)
  on conflict (department, kinds) do update
    set coefficients = excluded.coefficients, n = excluded.n, r2 = excluded.r2, fitted_by = excluded.fitted_by, fitted_at = now()
  returning id into v_id;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ---------------------------------------------------------------------------
--  estimate_dept_hours: ONE line-month's drivers → hours for ONE department.
--  Model when one covers this department and kind; otherwise the median of the
--  single-driver estimates over the drivers both sides know (n ≥ 2).
-- ---------------------------------------------------------------------------
create or replace function estimate_dept_hours(p_kind text, p_department text, p_client_id uuid, p_drivers jsonb)
returns table (hours numeric, method text, n int)
language sql
stable
as $$
with model as (
  select m.* from benchmark_models m
  where m.department = p_department and p_kind = any(m.kinds)
  order by m.fitted_at desc limit 1
),
model_est as (
  select greatest(coalesce((m.coefficients ->> 'intercept')::numeric, 0)
         + coalesce((select sum((m.coefficients ->> e.key)::numeric * (e.value)::numeric)
                     from jsonb_each_text(coalesce(p_drivers, '{}'::jsonb)) e
                     where (m.coefficients ->> e.key) ~ '^-?\d+(\.\d+)?$' and e.value ~ '^-?\d+(\.\d+)?$'), 0), 0) as hours,
         m.n
  from model m
),
coef as (select benchmark_coefficients(p_kind, p_department, p_client_id) as c),
single as (
  select (e.value)::numeric * (d ->> 'hours_per_unit')::numeric as est, (d ->> 'n')::int as n
  from coef, jsonb_array_elements(coef.c -> 'drivers') d
  join jsonb_each_text(coalesce(p_drivers, '{}'::jsonb)) e on e.key = d ->> 'driver'
  where e.value ~ '^-?\d+(\.\d+)?$' and (d ->> 'hours_per_unit') is not null and (d ->> 'n')::int >= 2
)
select case when exists (select 1 from model_est) then (select round(hours, 2) from model_est)
            else (select round(percentile_cont(0.5) within group (order by est)::numeric, 2) from single) end as hours,
       case when exists (select 1 from model_est) then 'model'
            when exists (select 1 from single) then 'ratio:' || (select c ->> 'scope' from coef) else 'none' end as method,
       case when exists (select 1 from model_est) then (select n from model_est) else (select coalesce(max(n), 0)::int from single) end as n;
$$;

-- ---------------------------------------------------------------------------
--  scope_estimate_hours: fill the demand grid from the benchmarks + catalog
-- ---------------------------------------------------------------------------
create or replace function scope_estimate_hours(p_scope_id uuid, p_by text)
returns jsonb
language plpgsql
as $$
declare
  v_client uuid; r record; e record; v_written int := 0; v_detail jsonb := '[]'::jsonb; d text; v_h numeric;
begin
  select client_id into v_client from scopes where id = p_scope_id;
  if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;

  -- a private name: a caller's own temp table named _est must not be touched
  drop table if exists _sce_est;
  create temp table _sce_est (department text, month date, hours numeric, source text) on commit drop;

  -- benchmarks: every line month with drivers, every department that has data for the kind
  for r in
    select sd.id as scope_deal_id, sl.kind::text as kind, slm.month, slm.drivers
    from scope_deals sd
    join scope_lines sl on sl.scope_deal_id = sd.id
    join scope_line_months slm on slm.scope_line_id = sl.id
    where sd.scope_id = p_scope_id and jsonb_typeof(slm.drivers) = 'object' and slm.drivers <> '{}'::jsonb
      and sd.flight_start is not null and sd.flight_end is not null
      and slm.month between date_trunc('month', sd.flight_start) and date_trunc('month', sd.flight_end)
  loop
    for d in
      select distinct o.department from v_benchmark_observed o where r.kind = any(o.deal_kinds)
      union select m.department from benchmark_models m where r.kind = any(m.kinds)
    loop
      select * into e from estimate_dept_hours(r.kind, d, v_client, r.drivers);
      if e.hours is not null and e.hours > 0 then
        insert into _sce_est values (d, r.month, e.hours, 'benchmark');
        v_detail := v_detail || jsonb_build_object('department', d, 'month', r.month, 'kind', r.kind, 'hours', e.hours, 'method', e.method, 'n', e.n);
      end if;
    end loop;
  end loop;

  -- catalog products on lines: setup in the first flight month, monthly every month
  for r in
    select sd.flight_start, sd.flight_end, (pr ->> 'product_id')::uuid as product_id, coalesce((pr ->> 'qty')::numeric, 1) as qty
    from scope_deals sd
    join scope_lines sl on sl.scope_deal_id = sd.id
    cross join lateral jsonb_array_elements(case when jsonb_typeof(sl.structure -> 'products') = 'array' then sl.structure -> 'products' else '[]'::jsonb end) pr
    where sd.scope_id = p_scope_id and sd.flight_start is not null and sd.flight_end is not null
  loop
    for e in
      select k.key as department, (k.value)::numeric as h, 'setup' as which from products p, jsonb_each_text(p.setup_hours) k where p.id = r.product_id
      union all
      select k.key, (k.value)::numeric, 'monthly' from products p, jsonb_each_text(p.monthly_hours) k where p.id = r.product_id
    loop
      if e.which = 'setup' then
        insert into _sce_est values (e.department, date_trunc('month', r.flight_start)::date, e.h * r.qty, 'catalog');
      else
        insert into _sce_est
        select e.department, gs::date, e.h * r.qty, 'catalog'
        from generate_series(date_trunc('month', r.flight_start), date_trunc('month', r.flight_end), interval '1 month') gs;
      end if;
    end loop;
  end loop;

  -- write: sum per (department, month); a manual row is never overwritten
  for r in select department, month, sum(hours) as hours,
                  case when bool_or(source = 'benchmark') then 'benchmark' else 'catalog' end as source
           from _sce_est group by department, month loop
    insert into scope_dept_months (scope_id, department, month, hours, source)
    values (p_scope_id, r.department, r.month, round(r.hours, 2), r.source)
    on conflict (scope_id, department, month) do update
      set hours = excluded.hours, source = excluded.source
      where scope_dept_months.source <> 'manual';
    if found then v_written := v_written + 1; end if;
  end loop;

  return jsonb_build_object('ok', true, 'rows_written', v_written, 'detail', v_detail);
end;
$$;

comment on function scope_estimate_hours(uuid, text) is
  'Fills scope_dept_months from the benchmarks (per line month with drivers: model if one exists for the department and kind, else the median single-driver estimate, client coefficients first) plus catalog products'' setup + monthly hours. Never overwrites a manual row.';

-- ---------------------------------------------------------------------------
--  quick_check, 097 rewritten WHOLE: hours from the benchmarks when none typed
-- ---------------------------------------------------------------------------
create or replace function quick_check(p_kind text, p_budget_c bigint, p_fee_pct numeric, p_months int,
                                       p_hours jsonb, p_amount_c bigint default 0, p_margin_pct numeric default null)
returns jsonb
language sql
stable
as $$
with k as (
  select greatest(coalesce(p_months, 1), 1) as n,
         coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_profit_per_hour'), 150) * 100 as target_c,
         coalesce(p_margin_pct, (select (value #>> '{}')::numeric from settings where key = 'programmatic_margin_default'), 35) as margin,
         date_trunc('month', current_date)::date as cur
),
gp1 as (
  select case p_kind
    when 'search' then round(line_fee(p_budget_c, p_fee_pct, '{}'::jsonb))
    when 'social' then round(line_fee(p_budget_c, p_fee_pct, '{}'::jsonb))
    when 'programmatic' then round(p_budget_c * (select margin from k) / 100 + line_fee(p_budget_c, p_fee_pct, '{}'::jsonb))
    else coalesce(p_amount_c, 0) end as gp_month
),
typed as (
  select key as department, value::numeric as hours, 'typed' as method from jsonb_each_text(coalesce(p_hours, '{}'::jsonb))
  where value ~ '^-?\d+(\.\d+)?$' and value::numeric > 0
),
-- 099: no typed hours → estimate per department from spend, the one driver a
-- quick check has (spend in cents, as the uploads store it)
estimated as (
  select o.department, e.hours, e.method
  from (select distinct department from v_benchmark_observed o where p_kind = any(o.deal_kinds)) o
  cross join lateral estimate_dept_hours(p_kind, o.department, null, jsonb_build_object('spend', p_budget_c)) e
  where not exists (select 1 from typed) and e.hours is not null and e.hours > 0
),
hrs as (select * from typed union all select * from estimated),
lab as (
  select sum(h.hours) as hours,
         sum(round(h.hours * coalesce(band_rate(h.department, null, (select cur from k)), 0))) as cost,
         bool_or(band_rate(h.department, null, (select cur from k)) is null) as unpriced
  from hrs h
)
select jsonb_build_object(
  'months', (select n from k),
  'gp_month', (select gp_month from gp1)::bigint,
  'gp', ((select gp_month from gp1) * (select n from k))::bigint,
  'hours_month', coalesce((select hours from lab), 0),
  'hours_by_dept', coalesce((select jsonb_object_agg(department, hours) from hrs), '{}'::jsonb),
  'hours_method', coalesce((select string_agg(distinct method, ', ') from hrs), 'none'),
  'labor_month', coalesce((select cost from lab), 0)::bigint,
  'labor', (coalesce((select cost from lab), 0) * (select n from k))::bigint,
  'pal_month', ((select gp_month from gp1) - coalesce((select cost from lab), 0))::bigint,
  'per_hour_c', case when coalesce((select hours from lab), 0) > 0
                     then round(((select gp_month from gp1) - coalesce((select cost from lab), 0)) / (select hours from lab)) end,
  'target_c', (select target_c from k),
  'status', case
    when coalesce((select hours from lab), 0) = 0 then 'unclear'
    when coalesce((select unpriced from lab), false) then 'unclear'
    when (select gp_month from gp1) - (select cost from lab) < 0 then 'no_go'
    when round(((select gp_month from gp1) - (select cost from lab)) / (select hours from lab)) >= (select target_c from k) then 'go'
    else 'no_go' end
);
$$;

comment on function quick_check(text, bigint, numeric, int, jsonb, bigint, numeric) is
  'The list view''s 30-second answer: monthly gp from the shared primitives; hours typed per department, or (099) estimated per department from spend via the benchmarks; labor at department averages; pal, profit per hour vs target, status.';

-- ---------------------------------------------------------------------------
--  benchmark_page: the bench mode in one round trip
-- ---------------------------------------------------------------------------
create or replace function benchmark_page()
returns jsonb
language sql
stable
as $$
with obs as (select * from v_benchmark_observed),
pairs as (select distinct k as kind, department from obs, unnest(deal_kinds) k)
select jsonb_build_object(
  'enrolled', coalesce((select jsonb_agg(jsonb_build_object(
      'deal_id', bd.deal_id, 'name', d.name, 'client_id', d.client_id, 'client_name', c.name,
      'flight_start', d.flight_start, 'flight_end', d.flight_end, 'status', d.status,
      'kinds', (select coalesce(array_agg(distinct dl.kind::text), '{}') from deal_lines dl where dl.deal_id = d.id),
      'enrolled_by', bd.enrolled_by, 'enrolled_at', bd.enrolled_at,
      'uploads', coalesce((select jsonb_agg(jsonb_build_object(
          'id', u.id, 'platform', u.platform, 'department', u.department, 'filename', u.filename, 'parser', u.parser,
          'month_from', u.month_from, 'month_to', u.month_to, 'row_count', u.row_count, 'uploaded_by', u.uploaded_by, 'uploaded_at', u.uploaded_at)
          order by u.uploaded_at desc) from benchmark_uploads u where u.deal_id = d.id), '[]'::jsonb),
      'months_observed', (select count(*) from obs o where o.deal_id = d.id))
      order by c.name, d.name) from benchmark_deals bd join deals d on d.id = bd.deal_id left join clients c on c.id = d.client_id), '[]'::jsonb),
  'deals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'name', d.name, 'client_id', d.client_id, 'client_name', c.name,
      'flight_start', d.flight_start, 'flight_end', d.flight_end,
      'kinds', (select coalesce(array_agg(distinct dl.kind::text), '{}') from deal_lines dl where dl.deal_id = d.id),
      'enrolled', exists (select 1 from benchmark_deals bd where bd.deal_id = d.id))
      order by c.name, d.name) from deals d left join clients c on c.id = d.client_id
      where d.status in ('won', 'active') and not d.hidden), '[]'::jsonb),
  'observations', coalesce((select jsonb_agg(jsonb_build_object(
      'deal_id', deal_id, 'deal_name', deal_name, 'client_id', client_id, 'department', department, 'month', month,
      'drivers', drivers, 'hours', hours, 'deal_kinds', deal_kinds) order by deal_name, department, month) from obs), '[]'::jsonb),
  'coefficients', coalesce((select jsonb_agg(benchmark_coefficients(p.kind, p.department, null) order by p.kind, p.department) from pairs p), '[]'::jsonb),
  'models', coalesce((select jsonb_agg(to_jsonb(m) order by m.department) from benchmark_models m), '[]'::jsonb),
  'departments', coalesce((select jsonb_agg(distinct s.department) from staff s where s.active and s.tracks_capacity and s.department is not null), '[]'::jsonb),
  'settings', jsonb_build_object(
      'platform_team_defaults', coalesce((select value from settings where key = 'scope_platform_team_defaults'), '{}'::jsonb),
      'driver_order', coalesce((select value from settings where key = 'scope_driver_order'), '[]'::jsonb),
      'model_min_observations', coalesce((select (value #>> '{}')::int from settings where key = 'scope_model_min_observations'), 12))
);
$$;

comment on function benchmark_page() is
  'Bench mode payload: enrolled deals with their uploads, live deals to enrol, every observation (drivers + hours), company-wide coefficients per kind × department, models, departments, knobs.';
