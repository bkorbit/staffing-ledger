-- ============================================================================
--  106 — Scoping under 100 ms: remember every rate, compute every building
--  block once, skip history that cannot matter, one round trip per action —
--  and a way to delete a scope.
--
--  Where a scope page spent its time (measured in the PGlite bed on a 55-person
--  roster, a 6-month flight, 4 lines, 30 named person-months):
--    scope_page 1228 ms = scope_verdict 610 (client_detail 425 of it)
--                       + scope_existing_deals 428 (project_detail per deal)
--                       + scope_labor / scope_staffing / scope_months computed
--                         TWICE (once by the page, once inside the verdict)
--                       + staff_rates_months 126 (the burden stack, per person-month)
--
--  Now:
--    staff_rate_cache                the memo of staff_hourly_cost(person, month 1st):
--      staff_rate_cache_fill(f0, f1)   VOLATILE, inserts the missing person-months
--                                      (called by the page, the queue, quick check,
--                                      every action — PostgREST runs STABLE
--                                      functions read-only, so the fill lives in
--                                      the volatile entry points)
--      cached_hourly_cost(staff, m)    a hit, else the live burden stack
--      staff_rates_months              reads the cache, falls back live — always
--                                      right, fast when warm
--      invalidation triggers           comp_periods / staff → that person's rows;
--                                      a burden setting, workers_comp_rates,
--                                      suta_rates → everything. A stale rate is
--                                      impossible; a cold cache only costs time.
--    scope_verdict_calc(id, econ, labor, staffing)   the 105 verdict on inputs the
--      page has already computed; scope_verdict(id) is the one-argument wrapper.
--      scope_page computes scope_months / scope_labor / scope_staffing ONCE.
--    client_detail / project_detail    only when the window reaches a CLOSED month
--      (measured rows joined flight months only; a future-only flight never used
--      them — same output, none of the cost).
--    scope_act(action, id, by, args)   save / propose / draft / approve / unapprove /
--      auto_staff / estimate / promote / create / delete, returning the fresh
--      scope_page in the same round trip.
--    scoping_list()                    the list view's eight requests as one.
--    delete_scope(id, by)              draft / proposed by anyone, approved by an
--      approver (its reserved hours leave Hour Planning), promoted never.
--    indexes                           scope_versions (scope_id), scopes (family_id),
--                                      scopes (status), assignments (deal_id, month).
--
--  Fixture: db/106_fixture_test.sql; then re-run 097, 101, 103, 104, 105 — the
--  same scopes must price to the cent through the rewritten functions.
-- ============================================================================

-- ---------------------------------------------------------------------------
--  the rate memo
-- ---------------------------------------------------------------------------
create table if not exists staff_rate_cache (
  staff_id    uuid not null references staff(id) on delete cascade,
  month       date not null check (month = date_trunc('month', month)::date),
  rate        bigint,                       -- null = staff_hourly_cost said null (no comp period)
  computed_at timestamptz not null default now(),
  primary key (staff_id, month)
);
alter table staff_rate_cache enable row level security;
drop policy if exists staff_rate_cache_auth_all on staff_rate_cache;
create policy staff_rate_cache_auth_all on staff_rate_cache for all to authenticated using (true) with check (true);
grant select, insert, update, delete on staff_rate_cache to authenticated, service_role;

comment on table staff_rate_cache is
  'Memo of staff_hourly_cost(person, first of month) — 106. Filled lazily by staff_rate_cache_fill, read by staff_rates_months / cached_hourly_cost with a live fallback, emptied by triggers on every input of the burden stack. Never a source of truth; delete from it freely.';

create index if not exists scope_versions_scope_idx on scope_versions (scope_id, version desc);
create index if not exists scopes_family_idx on scopes (family_id);
create index if not exists scopes_status_idx on scopes (status);
create index if not exists assignments_deal_month_idx on assignments (deal_id, month) where deal_id is not null;

create or replace function staff_rate_cache_fill(p_from date, p_to date)
returns int
language plpgsql
as $$
declare v_n int;
begin
  if p_from is null or p_to is null then return 0; end if;
  insert into staff_rate_cache (staff_id, month, rate)
  select s.id, m.month, staff_hourly_cost(s.id, m.month)
  from staff s
  cross join (select gs::date as month from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') gs) m
  where s.active and s.tracks_capacity and not s.exclude_hours
    and (s.start_date is null or s.start_date <= m.month)
    and (s.end_date is null or s.end_date >= m.month)
    and not exists (select 1 from staff_rate_cache c where c.staff_id = s.id and c.month = m.month)
  on conflict (staff_id, month) do nothing;
  get diagnostics v_n = row_count;
  return v_n;
end;
$$;

comment on function staff_rate_cache_fill(date, date) is
  'Insert the missing (plannable person, month) rates for the range — one burden-stack call each, once. Called from the VOLATILE entry points (scope_page, approvals_queue, quick_check, scope_act); a STABLE function runs read-only under PostgREST.';

create or replace function cached_hourly_cost(p_staff_id uuid, p_month date)
returns bigint
language sql
stable
as $$
  select case when exists (select 1 from staff_rate_cache c where c.staff_id = p_staff_id and c.month = p_month)
              then (select c.rate from staff_rate_cache c where c.staff_id = p_staff_id and c.month = p_month)
              else staff_hourly_cost(p_staff_id, p_month) end;
$$;

comment on function cached_hourly_cost(uuid, date) is
  'staff_hourly_cost(person, month) from the memo when present (null rates included), computed live otherwise. Same answer either way.';

create or replace function staff_rates_months(p_from date, p_to date)
returns table (staff_id uuid, department text, month date, rate bigint, band text)
language sql
stable
as $$
with months as (
  select gs::date as month from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') gs
),
bands as (
  select t.ord, t.b ->> 'name' as name, nullif(t.b ->> 'upto_c', '')::bigint as upto_c
  from settings s, jsonb_array_elements(s.value) with ordinality as t(b, ord)
  where s.key = 'scope_comp_bands' and jsonb_typeof(s.value) = 'array'
),
people as (
  -- 106: the memo first; the live burden stack only for a person-month it lacks
  select s.id as staff_id, s.department, m.month,
         case when c.staff_id is not null then c.rate else staff_hourly_cost(s.id, m.month) end as rate
  from staff s cross join months m
  left join staff_rate_cache c on c.staff_id = s.id and c.month = m.month
  where s.active and s.tracks_capacity and not s.exclude_hours
    and (s.start_date is null or s.start_date <= m.month)
    and (s.end_date is null or s.end_date >= m.month)
)
select p.staff_id, p.department, p.month, p.rate,
       (select b.name from bands b where p.rate is not null and (b.upto_c is null or p.rate <= b.upto_c) order by b.ord limit 1) as band
from people p;
$$;

comment on function staff_rates_months(date, date) is
  'Every active tracks_capacity non-excluded person employed in each month of the range, with staff_hourly_cost(person, month) (from staff_rate_cache when memoised — 106) and the comp band that rate falls in. The population and semantics of band_rate() / staff_band().';

-- the memo is emptied by every input of the burden stack
create or replace function staff_rate_cache_invalidate()
returns trigger
language plpgsql
as $$
begin
  if tg_table_name = 'comp_periods' then
    if tg_op in ('UPDATE', 'DELETE') then delete from staff_rate_cache where staff_id = old.staff_id; end if;
    if tg_op in ('INSERT', 'UPDATE') then delete from staff_rate_cache where staff_id = new.staff_id; end if;
  elsif tg_table_name = 'staff' then
    if tg_op in ('UPDATE', 'DELETE') then delete from staff_rate_cache where staff_id = old.id; end if;
    if tg_op in ('INSERT', 'UPDATE') then delete from staff_rate_cache where staff_id = new.id; end if;
  elsif tg_table_name = 'settings' then
    if (tg_op in ('UPDATE', 'DELETE') and old.key in (
          'fica_ss_rate', 'fica_medicare_rate', 'fica_ss_wage_base', 'futa_rate', 'futa_wage_base',
          'k401_match_rate', 'health_insurance_monthly_cost', 'health_insurance_start_date', 'workers_comp_rate',
          'suta_rate', 'suta_wage_base', 'hi_disability_monthly_cost', 'ny_disability_monthly_cost', 'peo_admin_fee_monthly'))
       or (tg_op in ('INSERT', 'UPDATE') and new.key in (
          'fica_ss_rate', 'fica_medicare_rate', 'fica_ss_wage_base', 'futa_rate', 'futa_wage_base',
          'k401_match_rate', 'health_insurance_monthly_cost', 'health_insurance_start_date', 'workers_comp_rate',
          'suta_rate', 'suta_wage_base', 'hi_disability_monthly_cost', 'ny_disability_monthly_cost', 'peo_admin_fee_monthly'))
    then delete from staff_rate_cache; end if;
  else
    delete from staff_rate_cache;   -- workers_comp_rates, suta_rates
  end if;
  return null;
end;
$$;

drop trigger if exists staff_rate_cache_inv_comp on comp_periods;
create trigger staff_rate_cache_inv_comp after insert or update or delete on comp_periods
  for each row execute function staff_rate_cache_invalidate();
drop trigger if exists staff_rate_cache_inv_staff on staff;
create trigger staff_rate_cache_inv_staff after update or delete on staff
  for each row execute function staff_rate_cache_invalidate();
drop trigger if exists staff_rate_cache_inv_settings on settings;
create trigger staff_rate_cache_inv_settings after insert or update or delete on settings
  for each row execute function staff_rate_cache_invalidate();
drop trigger if exists staff_rate_cache_inv_wc on workers_comp_rates;
create trigger staff_rate_cache_inv_wc after insert or update or delete on workers_comp_rates
  for each statement execute function staff_rate_cache_invalidate();
drop trigger if exists staff_rate_cache_inv_suta on suta_rates;
create trigger staff_rate_cache_inv_suta after insert or update or delete on suta_rates
  for each statement execute function staff_rate_cache_invalidate();

-- ---------------------------------------------------------------------------
--  scope_labor (105) — the fallback for a person outside the plannable roster
--  goes through the memo too
-- ---------------------------------------------------------------------------
create or replace function scope_labor(p_scope_id uuid)
returns table (
  month date, hours numeric, cost bigint,
  named_hours numeric, placeholder_hours numeric, unassigned_hours numeric, unpriced_hours numeric,
  cost_lo bigint, cost_hi bigint
) as $$
with flight as (
  select min(month) as f0, max(month) as f1 from (
    select month from scope_dept_months where scope_id = p_scope_id
    union select month from scope_staff_months where scope_id = p_scope_id) x
),
-- 105: ONE burden-stack call per person-month for the whole flight (106: memoised)
rates as materialized (
  select r.* from flight, staff_rates_months(f0, f1) r where f0 is not null
),
named as (
  select m.staff_id, m.department, m.month, sum(m.hours) as hours
  from scope_staff_months m where m.scope_id = p_scope_id and m.staff_id is not null
  group by m.staff_id, m.department, m.month
),
-- a named person who is inactive / excluded is still priced: the rates table
-- only carries plannable people, so fall back to the direct call for the few
named_rates as materialized (
  select n.staff_id, n.month,
         coalesce((select r.rate from rates r where r.staff_id = n.staff_id and r.month = n.month),
                  cached_hourly_cost(n.staff_id, n.month)) as rate
  from (select distinct staff_id, month from named) n
),
placeholders as (
  select m.department, m.band, m.month, sum(m.hours) as hours
  from scope_staff_months m where m.scope_id = p_scope_id and m.staff_id is null
  group by m.department, m.band, m.month
),
demand as (
  select department, month, hours from scope_dept_months where scope_id = p_scope_id
),
supplied as (
  select department, month, sum(hours) as hours from (
    select department, month, hours from named
    union all
    select department, month, hours from placeholders) u
  group by department, month
),
unassigned as (
  select d.department, d.month, greatest(d.hours - coalesce(s.hours, 0), 0) as hours
  from demand d left join supplied s on s.department = d.department and s.month = d.month
  where d.hours - coalesce(s.hours, 0) > 0
),
-- band_rate()'s ladder from the table: department + band → department → company
dept_band as (
  select department, band, month, round(avg(rate))::bigint as rate from rates where rate is not null group by department, band, month
),
dept_all as (
  select department, month, round(avg(rate))::bigint as rate from rates where rate is not null group by department, month
),
company as (
  select month, round(avg(rate))::bigint as rate from rates where rate is not null group by month
),
band_extremes as (
  select department, month, min(rate) as lo, max(rate) as hi from dept_band group by department, month
),
rows_ as (
  select n.month, n.hours, r.rate, 'named' as src, n.department
  from named n join named_rates r on r.staff_id = n.staff_id and r.month = n.month
  union all
  select p.month, p.hours,
         coalesce((select db.rate from dept_band db where db.department = p.department and db.band is not distinct from p.band and db.month = p.month and p.band is not null),
                  (select da.rate from dept_all da where da.department = p.department and da.month = p.month),
                  (select c.rate from company c where c.month = p.month)) as rate,
         'placeholder', p.department
  from placeholders p
  union all
  select u.month, u.hours,
         coalesce((select da.rate from dept_all da where da.department = u.department and da.month = u.month),
                  (select c.rate from company c where c.month = u.month)) as rate,
         'unassigned', u.department
  from unassigned u
),
months as (select distinct month from rows_)
select m.month,
  coalesce((select sum(hours) from rows_ r where r.month = m.month), 0)::numeric as hours,
  coalesce((select sum(round(hours * rate)) from rows_ r where r.month = m.month and r.rate is not null), 0)::bigint as cost,
  coalesce((select sum(hours) from rows_ r where r.month = m.month and r.src = 'named'), 0)::numeric as named_hours,
  coalesce((select sum(hours) from rows_ r where r.month = m.month and r.src = 'placeholder'), 0)::numeric as placeholder_hours,
  coalesce((select sum(hours) from rows_ r where r.month = m.month and r.src = 'unassigned'), 0)::numeric as unassigned_hours,
  coalesce((select sum(hours) from rows_ r where r.month = m.month and r.rate is null), 0)::numeric as unpriced_hours,
  (coalesce((select sum(round(hours * rate)) from rows_ r where r.month = m.month and r.src = 'named' and r.rate is not null), 0)
   + coalesce((select sum(round(r.hours * coalesce(be.lo, r.rate))) from rows_ r
               left join band_extremes be on be.department = r.department and be.month = r.month
               where r.month = m.month and r.src <> 'named' and coalesce(be.lo, r.rate) is not null), 0))::bigint as cost_lo,
  (coalesce((select sum(round(hours * rate)) from rows_ r where r.month = m.month and r.src = 'named' and r.rate is not null), 0)
   + coalesce((select sum(round(r.hours * coalesce(be.hi, r.rate))) from rows_ r
               left join band_extremes be on be.department = r.department and be.month = r.month
               where r.month = m.month and r.src <> 'named' and coalesce(be.hi, r.rate) is not null), 0))::bigint as cost_hi
from months m
order by m.month;
$$ language sql stable;

-- ---------------------------------------------------------------------------
--  scope_verdict_calc — the 105 verdict on inputs the caller already has.
--  p_econ = the scope_months rows, p_labor = the scope_labor rows, p_staffing
--  = scope_staffing's jsonb. The client roll-up's MEASURED side (client_detail)
--  is fetched only when a flight month is already closed: measured rows join
--  flight months, and a future-only flight never met one.
-- ---------------------------------------------------------------------------
create or replace function scope_verdict_calc(p_scope_id uuid, p_econ jsonb, p_labor jsonb, p_staffing jsonb)
returns jsonb
language sql
stable
as $$
with sc as (select * from scopes where id = p_scope_id),
knobs as (
  select coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_profit_per_hour'), 150) * 100 as target_c,
         coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_utilization_pct'), 80) as util,
         -- 103: the minimum-fee margin — the scope's preset, else the first preset
         coalesce((select (p ->> 'pct')::numeric from settings s, jsonb_array_elements(s.value) p
                   where s.key = 'scope_min_margin_presets' and p ->> 'name' = (select min_margin_preset from sc)),
                  (select (p ->> 'pct')::numeric from settings s, jsonb_array_elements(s.value) p
                   where s.key = 'scope_min_margin_presets' and p ->> 'name' = 'Slight margin'),
                  0) as min_margin_pct
),
econ as (
  select month, sum(gp) as gp, sum(rebate) as rebate, sum(billable) as billable, sum(pass_through) as pass_through,
         sum(fee) as fee   -- 103: what the client is charged, the number a minimum compares to
  from jsonb_to_recordset(coalesce(p_econ, '[]'::jsonb))
       as e(month date, gp bigint, rebate bigint, billable bigint, pass_through bigint, fee bigint)
  group by month
),
lab as (
  select * from jsonb_to_recordset(coalesce(p_labor, '[]'::jsonb))
       as l(month date, hours numeric, cost bigint, named_hours numeric, placeholder_hours numeric,
            unassigned_hours numeric, unpriced_hours numeric, cost_lo bigint, cost_hi bigint)
),
months as (select month from econ union select month from lab),
per as (
  select m.month,
         coalesce(e.gp, 0)::bigint as gp, coalesce(e.rebate, 0)::bigint as rebate, coalesce(e.billable, 0)::bigint as billable,
         coalesce(l.hours, 0) as hours, coalesce(l.cost, 0)::bigint as labor,
         coalesce(l.cost_lo, 0)::bigint as labor_lo, coalesce(l.cost_hi, 0)::bigint as labor_hi,
         coalesce(l.placeholder_hours, 0) + coalesce(l.unassigned_hours, 0) as open_hours,
         coalesce(l.unpriced_hours, 0) as unpriced_hours,
         coalesce(e.gp, 0) - coalesce(e.rebate, 0) - coalesce(l.cost, 0) as pal,
         -- 103: the fee that covers this month's labor (unassigned hours included) at the preset margin
         coalesce(e.fee, 0)::bigint as fee,
         case when (select min_margin_pct from knobs) >= 100 then null
              else round(coalesce(l.cost, 0) / (1 - (select min_margin_pct from knobs) / 100))::bigint end as min_fee
  from months m left join econ e on e.month = m.month left join lab l on l.month = m.month
),
tot as (
  select sum(gp) as gp, sum(rebate) as rebate, sum(billable) as billable, sum(hours) as hours, sum(labor) as labor,
         sum(labor_lo) as labor_lo, sum(labor_hi) as labor_hi, sum(pal) as pal, sum(open_hours) as open_hours, sum(unpriced_hours) as unpriced_hours,
         sum(fee) as fee, sum(min_fee) as min_fee, max(min_fee) as min_fee_max,            -- 103
         sum(greatest(min_fee - fee, 0)) as fee_shortfall
  from per
),
staffing as (select coalesce(p_staffing, '{}'::jsonb) as s),
hire as (
  select sum((h ->> 'hours')::numeric) as hours,
         sum((h ->> 'cost_hire')::bigint) as cost_hire,
         sum((h ->> 'cost_contractor')::bigint) as cost_contractor,
         bool_or((h ->> 'recommend')::boolean) as recommend,
         bool_and(h ->> 'cost_hire' is not null) as hire_priced,
         bool_and(h ->> 'cost_contractor' is not null) as contractor_priced
  from staffing, jsonb_array_elements(coalesce(staffing.s -> 'hire', '[]'::jsonb)) h
),
-- capacity: the scope's named hours per person per month against free hours
scope_named as (
  select staff_id, month, sum(hours) as hours from scope_staff_months
  where scope_id = p_scope_id and staff_id is not null group by staff_id, month
),
flight as (select min(month) as f0, max(month) as f1 from per),
cap as (
  select c.staff_id, c.month, c.capacity_hours,
         c.committed_hours - coalesce((select sum(a.hours) from assignments a
                                       where a.scope_id = p_scope_id and a.staff_id = c.staff_id and a.month = c.month), 0) as committed_other
  from flight, staff_capacity(f0, f1) c where f0 is not null
),
caprows as (
  select n.staff_id, n.month, n.hours as scope_hours,
         c.capacity_hours, c.committed_other,
         c.capacity_hours - c.committed_other - n.hours as free_after,
         (c.capacity_hours - c.committed_other - n.hours) < -0.005 as over
  from scope_named n left join cap c on c.staff_id = n.staff_id and c.month = n.month
),
-- client roll-up: the client's other live deals + this scope, per flight month.
-- 106: the measured side only when a flight month is already closed
cd as materialized (
  -- CASE, not WHERE: the planner may evaluate a target list before a filter
  -- it considers constant; CASE never evaluates the branch it does not take
  select case when (select client_id from sc) is not null
                and (select f0 from flight) < date_trunc('month', current_date)::date
              then client_detail((select client_id from sc)) end as j
),
existing_measured as (
  select (x ->> 'month')::date as month, (x ->> 'gp_actual')::bigint as gp, (x ->> 'labor_actual')::bigint as labor
  from cd, jsonb_array_elements(cd.j -> 'months') x
  where cd.j is not null and (x ->> 'month')::date < date_trunc('month', current_date)::date
),
existing_plan as (
  select v.month, sum(v.gp - v.rebate)::bigint as gp   -- 100: the client's other deals net of their rebates
  from v_deal_month_forecast v
  where v.client_id = (select client_id from sc) and v.month >= date_trunc('month', current_date)::date
  group by v.month
),
plan_labor_keys as (
  select distinct a.staff_id, a.month from assignments a
  join deals d on d.id = a.deal_id
  where d.client_id = (select client_id from sc) and a.scope_id is distinct from p_scope_id
    and a.month between (select f0 from flight) and (select f1 from flight)
),
plan_rates as materialized (
  select staff_id, month, cached_hourly_cost(staff_id, month) as rate from plan_labor_keys   -- 106: memoised
),
existing_plan_labor as (
  select a.month, sum(round(a.hours * r.rate))::bigint as labor
  from assignments a join deals d on d.id = a.deal_id
  join plan_rates r on r.staff_id = a.staff_id and r.month = a.month
  where d.client_id = (select client_id from sc) and a.scope_id is distinct from p_scope_id
  group by a.month
),
client_rows as (
  select p.month,
         coalesce(em.gp, ep.gp, 0) as gp_existing,
         coalesce(em.labor, epl.labor, 0) as labor_existing,
         p.gp as gp_scope, p.rebate as rebate_scope, p.labor as labor_scope,
         coalesce(em.gp, ep.gp, 0) - coalesce(em.labor, epl.labor, 0) + p.pal as pal_combined
  from per p
  left join existing_measured em on em.month = p.month
  left join existing_plan ep on ep.month = p.month
  left join existing_plan_labor epl on epl.month = p.month
  where (select client_id from sc) is not null
),
checks as (
  select
    (select bool_and(pal >= 0) from per) as monthly_positive,
    (select pal >= 0 from tot) as overall_positive,
    (select case when hours > 0 then round(pal / hours) >= (select target_c from knobs) else false end from tot) as per_hour_ok,
    (select bool_and(not over) from caprows where capacity_hours is not null) as capacity_ok,
    (select bool_and(pal_combined >= 0) from client_rows) as client_ok,
    (select open_hours > 0 from tot) as staff_unclear,
    (select unpriced_hours > 0 from tot) as unpriced,
    (select hours from tot) > 0 as has_hours,
    (select bool_and(fee >= coalesce(min_fee, 0)) from per) as min_fee_ok   -- 103: informative, not a gate
),
-- "viable with a hire": re-price the unstaffable hours at the hire / contractor rate.
-- 106: dept_avg_rate's ladder (department mean, else company mean, per month)
-- from ONE pass over the rates table, not a call per department-month
hire_hours_rows as (
  select (x ->> 'department') as department, (k.key)::date as month, (k.value)::numeric as hours
  from staffing, jsonb_array_elements(coalesce(staffing.s -> 'hire', '[]'::jsonb)) x, jsonb_each_text(x -> 'by_month') k
),
rates_all as materialized (
  select r.* from flight, staff_rates_months(f0, f1) r where f0 is not null and r.rate is not null
    and exists (select 1 from hire_hours_rows)
),
dept_avg as (
  select h.department, h.month,
         coalesce((select round(avg(r.rate))::bigint from rates_all r where r.department = h.department and r.month = h.month),
                  (select round(avg(r.rate))::bigint from rates_all r where r.month = h.month)) as rate
  from (select distinct department, month from hire_hours_rows) h
),
hire_avg_value as (
  select coalesce(sum(round(l.hours * da.rate)), 0) as v
  from hire_hours_rows l join dept_avg da on da.department = l.department and da.month = l.month
),
alt as (
  select
    case when h.hours is null or h.hours = 0 then null
         when h.hire_priced then (select pal from tot) - h.cost_hire + (select v from hire_avg_value)
         end as pal_hire,
    case when h.hours is null or h.hours = 0 then null
         when h.contractor_priced then (select pal from tot) - h.cost_contractor + (select v from hire_avg_value)
         end as pal_contractor,
    h.recommend, h.hours as hire_hours, h.cost_hire, h.cost_contractor
  from hire h
),
status as (
  select case
    when not (select has_hours from checks) then 'unclear'
    when (select unpriced from checks) then 'unclear'
    when (select overall_positive and per_hour_ok and coalesce(capacity_ok, true) and coalesce(client_ok, true) from checks) then 'go'
    when (select recommend from alt) and (select pal_hire from alt) is not null
         and (select pal_hire from alt) >= 0
         and round((select pal_hire from alt) / nullif((select hours from tot), 0)) >= (select target_c from knobs) then 'go_with_hire'
    when (select recommend from alt) and (select pal_contractor from alt) is not null
         and (select pal_contractor from alt) >= 0
         and round((select pal_contractor from alt) / nullif((select hours from tot), 0)) >= (select target_c from knobs) then 'go_with_contractor'
    else 'no_go' end as status
)
select jsonb_build_object(
  'months', coalesce((select jsonb_agg(jsonb_build_object(
      'month', month, 'gp', gp, 'rebate', rebate, 'billable', billable, 'hours', hours, 'labor', labor,
      'labor_lo', labor_lo, 'labor_hi', labor_hi, 'pal', pal,
      'per_hour_c', case when hours > 0 then round(pal / hours) end,
      'fee', fee, 'min_fee', min_fee,   -- 103
      'open_hours', open_hours, 'unpriced_hours', unpriced_hours) order by month) from per), '[]'::jsonb),
  'total', (select jsonb_build_object(
      'gp', gp, 'rebate', rebate, 'billable', billable, 'hours', hours, 'labor', labor,
      'labor_lo', labor_lo, 'labor_hi', labor_hi, 'pal', pal,
      'per_hour_c', case when hours > 0 then round(pal / hours) end,
      'fee', fee, 'min_fee', min_fee, 'min_fee_max', min_fee_max, 'fee_shortfall', fee_shortfall,   -- 103
      'open_hours', open_hours, 'unpriced_hours', unpriced_hours) from tot),
  'targets', (select jsonb_build_object('per_hour_c', target_c, 'utilization_pct', util, 'min_margin_pct', min_margin_pct,
                                        'min_margin_preset', (select min_margin_preset from sc)) from knobs),
  'checks', (select to_jsonb(c) from checks c),
  'status', (select status from status),
  'hire', (select jsonb_build_object('recommend', recommend, 'hours', hire_hours, 'cost_hire', cost_hire,
                                     'cost_contractor', cost_contractor, 'pal_hire', pal_hire, 'pal_contractor', pal_contractor) from alt),
  'capacity', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'month', month, 'scope_hours', scope_hours, 'capacity_hours', capacity_hours,
      'committed_other', committed_other, 'free_after', free_after, 'over', over) order by staff_id, month) from caprows), '[]'::jsonb),
  'client', coalesce((select jsonb_agg(jsonb_build_object(
      'month', month, 'gp_existing', gp_existing, 'labor_existing', labor_existing,
      'gp_scope', gp_scope, 'rebate_scope', rebate_scope, 'labor_scope', labor_scope,
      'pal_combined', pal_combined) order by month) from client_rows), '[]'::jsonb)
);
$$;

comment on function scope_verdict_calc(uuid, jsonb, jsonb, jsonb) is
  'The 105 verdict computed from the scope_months rows, scope_labor rows and scope_staffing jsonb the caller already holds — scope_page computes each once. client_detail is consulted only when a flight month is closed. scope_verdict(id) wraps it.';

create or replace function scope_verdict(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
select scope_verdict_calc(p_scope_id,
  coalesce((select jsonb_agg(to_jsonb(m)) from scope_months(p_scope_id) m), '[]'::jsonb),
  coalesce((select jsonb_agg(to_jsonb(l)) from scope_labor(p_scope_id) l), '[]'::jsonb),
  scope_staffing(p_scope_id));
$$;

-- ---------------------------------------------------------------------------
--  scope_existing_deals (103) — project_detail only for a window that reaches
--  a closed month; planned labor from the memo
-- ---------------------------------------------------------------------------
create or replace function scope_existing_deals(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
with sc as (select * from scopes where id = p_scope_id),
win as (
  select date_trunc('month', min(flight_start))::date as m0, date_trunc('month', max(flight_end))::date as m1
  from scope_deals where scope_id = p_scope_id and flight_start is not null and flight_end is not null
),
cur as (select date_trunc('month', current_date)::date as m),
d as (
  select d.* from deals d, sc, win
  where d.client_id = sc.client_id and d.status in ('won', 'active') and not d.hidden
    and win.m0 is not null
    and date_trunc('month', d.flight_start)::date <= win.m1 and date_trunc('month', d.flight_end)::date >= win.m0
    and d.id not in (select source_deal_id from scope_deals where scope_id = p_scope_id and source_deal_id is not null)
),
-- 106: the measured side exists only when the window has a closed month in it
d_measured as (select d.* from d, win, cur where win.m0 < cur.m),
pd as (
  select d.id as deal_id, (x ->> 'month')::date as month,
         (x ->> 'gp_actual')::bigint as gp_actual, (x ->> 'labor_actual')::bigint as labor_actual
  from d_measured d, jsonb_array_elements(project_detail(d.id) -> 'months') x
),
plan as (
  select v.deal_id, v.month, sum(v.gp - v.rebate) as gp from v_deal_month_forecast v where v.deal_id in (select id from d) group by v.deal_id, v.month
),
asg_keys as (select distinct a.staff_id, a.month from assignments a where a.deal_id in (select id from d)),
rates as materialized (select staff_id, month, cached_hourly_cost(staff_id, month) as rate from asg_keys),
asg as (
  select a.deal_id, a.month, sum(a.hours) as hours, sum(round(a.hours * r.rate)) as labor
  from assignments a join rates r on r.staff_id = a.staff_id and r.month = a.month
  where a.deal_id in (select id from d) group by a.deal_id, a.month
),
te as (
  select t.deal_id, date_trunc('month', t.worked_on)::date as month, sum(t.hours) as hours
  from time_entries t where t.deal_id in (select id from d) and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
  group by t.deal_id, date_trunc('month', t.worked_on)
),
rows_ as (
  select d.id, d.name, d.flight_start, d.flight_end, d.qbo_project_id,
    coalesce((select sum(gp_actual) from pd, win, cur where pd.deal_id = d.id and pd.month between win.m0 and win.m1 and pd.month < cur.m), 0)::bigint as gp_measured,
    coalesce((select sum(gp) from plan, win, cur where plan.deal_id = d.id and plan.month between win.m0 and win.m1 and plan.month >= cur.m), 0)::bigint as gp_plan,
    coalesce((select sum(labor_actual) from pd, win, cur where pd.deal_id = d.id and pd.month between win.m0 and win.m1 and pd.month < cur.m), 0)::bigint as labor_measured,
    coalesce((select sum(labor) from asg, win, cur where asg.deal_id = d.id and asg.month between win.m0 and win.m1 and asg.month >= cur.m), 0)::bigint as labor_plan,
    coalesce((select sum(hours) from te, win, cur where te.deal_id = d.id and te.month between win.m0 and win.m1 and te.month < cur.m), 0)::numeric as hours_measured,
    coalesce((select sum(hours) from asg, win, cur where asg.deal_id = d.id and asg.month between win.m0 and win.m1 and asg.month >= cur.m), 0)::numeric as hours_plan
  from d
)
select coalesce((select jsonb_agg(jsonb_build_object(
  'id', id, 'name', name, 'flight_start', flight_start, 'flight_end', flight_end, 'qbo_project_id', qbo_project_id,
  'gp_measured', gp_measured, 'gp_plan', gp_plan, 'labor_measured', labor_measured, 'labor_plan', labor_plan,
  'hours_measured', hours_measured, 'hours_plan', hours_plan,
  'pal', gp_measured + gp_plan - labor_measured - labor_plan) order by flight_start, name) from rows_), '[]'::jsonb);
$$;

comment on function scope_existing_deals(uuid) is
  'The client''s live deals whose flights overlap the scope''s months (the source deal of an extend re-scope excluded): per deal GP and labor measured to date (project_detail — consulted only when the window reaches a closed month, 106) and planned forward (v_deal_month_forecast gp − rebate; assignments × the memoised hourly cost) inside the window, hours, profit after labor. Labor is a total per deal — never per person.';

-- ---------------------------------------------------------------------------
--  approvals_queue (105) — the memo warmed first
-- ---------------------------------------------------------------------------
create or replace function approvals_queue_calc()
returns jsonb
language sql
stable
as $$
select coalesce((select jsonb_agg(jsonb_build_object(
  'id', s.id, 'name', s.name, 'scenario', s.scenario, 'client_id', s.client_id, 'client_name', c.name,
  'proposed_by', s.proposed_by, 'proposed_at', s.proposed_at, 'version', s.version,
  'deals', (select coalesce(jsonb_agg(jsonb_build_object('name', sd.name, 'flight_start', sd.flight_start, 'flight_end', sd.flight_end, 'promote_mode', sd.promote_mode) order by sd.ord), '[]'::jsonb) from scope_deals sd where sd.scope_id = s.id),
  'kpis', (v.j -> 'total') || jsonb_build_object('status', v.j ->> 'status'))
  order by s.proposed_at nulls last, s.set_at)
  from scopes s left join clients c on c.id = s.client_id
  cross join lateral (select scope_verdict(s.id) as j) v   -- 105: once per scope
  where s.status = 'proposed'), '[]'::jsonb);
$$;

create or replace function approvals_queue()
returns jsonb
language plpgsql
as $$
declare v_f0 date; v_f1 date;
begin
  select min(x.m0), max(x.m1) into v_f0, v_f1 from (
    select sd.flight_start as m0, sd.flight_end as m1 from scope_deals sd join scopes s on s.id = sd.scope_id where s.status = 'proposed'
    union all select dm.month, dm.month from scope_dept_months dm join scopes s on s.id = dm.scope_id where s.status = 'proposed'
    union all select sm.month, sm.month from scope_staff_months sm join scopes s on s.id = sm.scope_id where s.status = 'proposed') x;
  perform staff_rate_cache_fill(v_f0, v_f1);
  return approvals_queue_calc();
end;
$$;

comment on function approvals_queue() is
  'What waits for an approver: every proposed scope with its deals, proposer and verdict KPIs. 106: warms staff_rate_cache over the proposed flights first (volatile), then approvals_queue_calc.';

-- ---------------------------------------------------------------------------
--  scope_page (105) — every building block once, the memo warmed first
-- ---------------------------------------------------------------------------
create or replace function scope_page(p_scope_id uuid)
returns jsonb
language plpgsql
as $$
declare
  v_family uuid; v_f0 date; v_f1 date;
  v_econ jsonb; v_labor jsonb; v_staffing jsonb; v_verdict jsonb;
begin
  select family_id into v_family from scopes where id = p_scope_id;
  if v_family is null then return null; end if;
  -- warm the rate memo over everything this page prices: the family's flights
  -- and hour rows (siblings' verdicts price too)
  select min(x.m0), max(x.m1) into v_f0, v_f1 from (
    select sd.flight_start as m0, sd.flight_end as m1 from scope_deals sd join scopes s on s.id = sd.scope_id where s.family_id = v_family
    union all select dm.month, dm.month from scope_dept_months dm join scopes s on s.id = dm.scope_id where s.family_id = v_family
    union all select sm.month, sm.month from scope_staff_months sm join scopes s on s.id = sm.scope_id where s.family_id = v_family) x;
  perform staff_rate_cache_fill(v_f0, v_f1);

  select coalesce(jsonb_agg(to_jsonb(m) order by m.month, m.scope_line_id), '[]'::jsonb) into v_econ from scope_months(p_scope_id) m;
  select coalesce(jsonb_agg(to_jsonb(l) order by l.month), '[]'::jsonb) into v_labor from scope_labor(p_scope_id) l;
  v_staffing := scope_staffing(p_scope_id);
  v_verdict  := scope_verdict_calc(p_scope_id, v_econ, v_labor, v_staffing);

  return scope_state(p_scope_id)
    || jsonb_build_object(
    'econ', v_econ,
    'labor', v_labor,
    'staffing', v_staffing,
    'verdict', v_verdict,
    'existing_deals', scope_existing_deals(p_scope_id),   -- 103
    'prog_margin', scope_prog_margin(p_scope_id),          -- 104: the deal's backend margin (output)
    'versions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.id, 'version', v.version, 'reason', v.reason, 'label', v.label, 'saved_by', v.saved_by, 'saved_at', v.saved_at)
        order by v.version desc) from scope_versions v where v.scope_id = p_scope_id), '[]'::jsonb),
    'siblings', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s2.id, 'name', s2.name, 'scenario', s2.scenario, 'status', s2.status, 'version', s2.version,
        'kpis', (v.j -> 'total') || jsonb_build_object('status', v.j ->> 'status'))
        order by s2.created_at) from scopes s2
        cross join lateral (select case when s2.id = p_scope_id then v_verdict else scope_verdict(s2.id) end as j) v   -- the open scope reuses its own
        where s2.family_id = v_family), '[]'::jsonb),
    'staff', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active, 'tracks_capacity', s.tracks_capacity)
        order by s.name) from staff s where s.active and s.tracks_capacity and not s.exclude_hours), '[]'::jsonb),
    'departments', coalesce((select jsonb_agg(distinct s.department) from staff s
        where s.active and s.tracks_capacity and s.department is not null), '[]'::jsonb),
    'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name) from clients c where c.active), '[]'::jsonb),
    'settings', jsonb_build_object(
        'per_hour', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_profit_per_hour'), 150),
        'utilization_pct', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_utilization_pct'), 80),
        'prog_target_gp_pct', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_prog_target_gp_pct'), 40),
        'cpm_platform_share_pct', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_cpm_platform_share_pct'), 50),
        'margin_default', coalesce((select (value #>> '{}')::numeric from settings where key = 'programmatic_margin_default'), 35),
        'approvers', coalesce((select value from settings where key = 'scope_approver_emails'), '[]'::jsonb),
        'comp_bands', coalesce((select value from settings where key = 'scope_comp_bands'), '[]'::jsonb),
        'hire_costs', coalesce((select value from settings where key = 'scope_hire_costs'), '{}'::jsonb),
        'min_margin_presets', coalesce((select value from settings where key = 'scope_min_margin_presets'), '[]'::jsonb),   -- 103
        'kind_departments', coalesce((select value from settings where key = 'scope_kind_departments'), '{}'::jsonb),        -- 104
        'always_departments', coalesce((select value from settings where key = 'scope_always_departments'), '[]'::jsonb)),
    'sources', jsonb_build_object(
        'pipeline', coalesce((select jsonb_agg(jsonb_build_object(
            'hubspot_deal_id', pd.hubspot_deal_id, 'name', pd.name, 'company', pd.company, 'amount', pd.amount,
            'campaign_start', pd.campaign_start, 'campaign_end', pd.campaign_end, 'stage', pd.stage, 'url', pd.url))
            from pipeline_deals pd where pd.hubspot_deal_id in
              (select hubspot_deal_id from scope_deals where scope_id = p_scope_id and hubspot_deal_id is not null)), '[]'::jsonb),
        'deals', coalesce((select jsonb_agg(jsonb_build_object(
            'id', d.id, 'name', d.name, 'client_id', d.client_id, 'flight_start', d.flight_start, 'flight_end', d.flight_end, 'status', d.status))
            from deals d where d.id in
              (select source_deal_id from scope_deals where scope_id = p_scope_id and source_deal_id is not null
               union select promoted_deal_id from scope_deals where scope_id = p_scope_id and promoted_deal_id is not null)), '[]'::jsonb))
  );
end;
$$;

comment on function scope_page(uuid) is
  'The whole Scoping editor in one round trip. 106: volatile — warms staff_rate_cache over the family''s months, then computes scope_months, scope_labor and scope_staffing ONCE and hands them to scope_verdict_calc; the payload is 105''s, key for key. Labor and verdict carry totals only.';

-- ---------------------------------------------------------------------------
--  quick_check (099) — department averages from the memo
-- ---------------------------------------------------------------------------
create or replace function quick_check_calc(p_kind text, p_budget_c bigint, p_fee_pct numeric, p_months int,
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
-- 106: band_rate(dept, null, month) = the department mean, else the company
-- mean — dept_avg_rate is that ladder on the memoised rates
priced as (
  select h.department, h.hours, dept_avg_rate(h.department, (select cur from k)) as rate from hrs h
),
lab as (
  select sum(h.hours) as hours,
         sum(round(h.hours * coalesce(h.rate, 0))) as cost,
         bool_or(h.rate is null) as unpriced
  from priced h
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

create or replace function quick_check(p_kind text, p_budget_c bigint, p_fee_pct numeric, p_months int,
                                       p_hours jsonb, p_amount_c bigint default 0, p_margin_pct numeric default null)
returns jsonb
language plpgsql
as $$
begin
  perform staff_rate_cache_fill(date_trunc('month', current_date)::date, date_trunc('month', current_date)::date);
  return quick_check_calc(p_kind, p_budget_c, p_fee_pct, p_months, p_hours, p_amount_c, p_margin_pct);
end;
$$;

comment on function quick_check(text, bigint, numeric, int, jsonb, bigint, numeric) is
  'The list view''s 30-second answer: monthly gp from the shared primitives; hours typed per department, or (099) estimated per department from spend via the benchmarks; labor at department averages (dept_avg_rate on the warmed memo, 106); pal, profit per hour vs target, status.';

-- ---------------------------------------------------------------------------
--  delete_scope — draft / proposed by anyone, approved by an approver (its
--  reserved hours leave Hour Planning with it), promoted never: the promoted
--  scope is the record behind its deals' lines and dates.
-- ---------------------------------------------------------------------------
create or replace function delete_scope(p_scope_id uuid, p_by text)
returns jsonb
language plpgsql
as $$
declare v scopes%rowtype; v_n int;
begin
  perform pg_advisory_xact_lock(hashtext('save_scope'), hashtext(p_scope_id::text));
  select * into v from scopes where id = p_scope_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;
  if v.status = 'promoted' then
    return jsonb_build_object('ok', false, 'reason', 'a promoted scope is the record behind its deals — it stays');
  end if;
  if v.status = 'approved' and not scope_is_approver(p_by) then
    return jsonb_build_object('ok', false, 'reason', 'only an approver can delete an approved scope (its hours are reserved in Hour Planning)');
  end if;
  delete from assignments where scope_id = p_scope_id;
  get diagnostics v_n = row_count;
  delete from scopes where id = p_scope_id;   -- cascades: deals, lines, months, department and staff months, versions
  return jsonb_build_object('ok', true, 'deleted', v.name, 'scenario', v.scenario, 'family_id', v.family_id,
                            'status_was', v.status, 'assignments_deleted', v_n);
end;
$$;

comment on function delete_scope(uuid, text) is
  'Deletes a scope and everything under it (scope_deals, lines, months, dept/staff months, versions, its reserved assignments). Draft / proposed: anyone. Approved: approvers only. Promoted: refused — the deals in the Forecast point back at it.';

-- ---------------------------------------------------------------------------
--  scope_act — one round trip per action: do it, return the fresh page
-- ---------------------------------------------------------------------------
create or replace function scope_act(p_action text, p_scope_id uuid, p_by text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
as $$
declare r jsonb; v_id uuid := p_scope_id;
begin
  case p_action
    when 'create' then
      r := create_scope(p_args ->> 'origin_kind', p_args ->> 'ref', p_args ->> 'name', p_by, p_args ->> 'scenario');
      v_id := nullif(r ->> 'scope_id', '')::uuid;
    when 'save' then
      r := save_scope(coalesce(p_args -> 'payload', '{}'::jsonb), p_by, p_args ->> 'label');
      v_id := coalesce(nullif(r ->> 'scope_id', '')::uuid, v_id);
    when 'propose'    then r := set_scope_status(v_id, 'proposed', p_by);
    when 'draft'      then r := set_scope_status(v_id, 'draft', p_by);
    when 'approve'    then r := approve_scope(v_id, p_by);
    when 'unapprove'  then r := unapprove_scope(v_id, p_by);
    when 'auto_staff' then r := auto_staff_scope(v_id, p_by);
    when 'estimate'   then r := scope_estimate_hours(v_id, p_by);
    when 'promote'    then r := promote_scope(v_id, p_by, coalesce(p_args -> 'projects', '{}'::jsonb));
    when 'delete'     then return delete_scope(v_id, p_by);
    else return jsonb_build_object('ok', false, 'reason', 'unknown action ' || coalesce(p_action, '(null)'));
  end case;
  if coalesce((r ->> 'ok')::boolean, false) and v_id is not null then
    r := r || jsonb_build_object('page', scope_page(v_id));
  end if;
  return r;
end;
$$;

comment on function scope_act(text, uuid, text, jsonb) is
  'The Scoping editor''s actions in one round trip: create {origin_kind, ref, name, scenario} / save {payload, label} / propose / draft / approve / unapprove / auto_staff / estimate / promote {projects} / delete. Runs the existing function, then appends page = scope_page(id) when it succeeded (delete returns no page).';

-- ---------------------------------------------------------------------------
--  scoping_list — the list view in one request (the tabs filter in the page)
-- ---------------------------------------------------------------------------
create or replace function scoping_list()
returns jsonb
language sql
stable
as $$
select jsonb_build_object(
  'scopes', coalesce((select jsonb_agg(to_jsonb(x) order by x.set_at desc) from
      (select id, family_id, name, scenario, client_id, status, version, set_by, set_at, created_at, proposed_by, proposed_at from scopes) x), '[]'::jsonb),
  'pipeline', coalesce((select jsonb_agg(to_jsonb(x)) from
      (select hubspot_deal_id, name, company, amount, campaign_start, campaign_end, close_date, stage, probability, pipeline, is_won, url from pipeline_deals) x), '[]'::jsonb),
  'promotions', coalesce((select jsonb_agg(hubspot_deal_id) from promotions), '[]'::jsonb),
  'dismissals', coalesce((select jsonb_agg(hubspot_deal_id) from won_deal_dismissals), '[]'::jsonb),
  'deals', coalesce((select jsonb_agg(to_jsonb(x)) from
      (select id, name, client_id, status, flight_start, flight_end, hidden, hubspot_deal_id from deals
       where status in ('won', 'active') and not hidden) x), '[]'::jsonb),
  'clients', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'active', active) order by name) from clients where active), '[]'::jsonb),
  'settings', coalesce((select jsonb_object_agg(key, value) from settings
      where key in ('scope_target_profit_per_hour', 'scope_approver_emails', 'hubspot_promote_pipelines', 'sales_probability_threshold')), '{}'::jsonb),
  'scoped', coalesce((select jsonb_agg(jsonb_build_object('hubspot_deal_id', hubspot_deal_id, 'scope_id', scope_id))
      from scope_deals where hubspot_deal_id is not null), '[]'::jsonb),
  'departments', coalesce((select jsonb_agg(distinct department) from staff
      where active and tracks_capacity and department is not null), '[]'::jsonb)
);
$$;

comment on function scoping_list() is
  'Everything the Scoping list view needs in one round trip — scopes, the pipeline mirror, promotions, dismissals, live deals, clients, the four knobs, scoped HubSpot ids, departments. The Pipeline tab''s filter (Sales Forecast''s population) stays in the page.';
