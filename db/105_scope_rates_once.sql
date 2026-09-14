-- ============================================================================
--  105 — Scoping pages under the statement timeout: price every person ONCE
--  per month and reuse it.
--
--  The first real load of a scope timed out ("canceling statement due to
--  statement timeout"). scope_labor priced placeholders and uncovered demand
--  with band_rate(), and band_rate() calls staff_hourly_cost() — the whole
--  burden stack — for every active person, and staff_band() calls it AGAIN per
--  person; the band-extremes range did that per department × band × month.
--  On the real roster that is thousands of burden-stack evaluations per page.
--  scope_staffing added two correlated time_entries scans per person, and the
--  page computed sibling verdicts twice each.
--
--  Now:
--    staff_rates_months(p_from, p_to)  the rates table: every active,
--      tracks_capacity, non-excluded person employed in each month of the
--      range, with staff_hourly_cost(person, month) and the comp band that rate
--      falls in — ONE burden-stack call per person-month, MATERIALIZED where
--      it is used. band_rate()'s population and rounding exactly.
--    dept_avg_rate(dept, month) / dept_band_rate(dept, band, month) read it.
--    scope_labor   rewritten on the rates table: same numbers as 097
--      (097 / 103 / 104 fixtures re-run to the cent), a fraction of the work.
--    scope_staffing candidates: one pass over twelve months of counted hours,
--      rates from the table.
--    scope_verdict's hire re-pricing, approvals_queue and scope_page's
--      siblings: one verdict per scope, dept averages from the table.
--    scope_months: the deal margin computed once, not per row.
--
--  Fixture: db/105_fixture_test.sql (equivalence of the rates table with
--  staff_hourly_cost / staff_band / band_rate) + re-run 097, 101, 103, 104.
-- ============================================================================

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
  select s.id as staff_id, s.department, m.month, staff_hourly_cost(s.id, m.month) as rate
  from staff s cross join months m
  where s.active and s.tracks_capacity and not s.exclude_hours
    and (s.start_date is null or s.start_date <= m.month)
    and (s.end_date is null or s.end_date >= m.month)
)
select p.staff_id, p.department, p.month, p.rate,
       (select b.name from bands b where p.rate is not null and (b.upto_c is null or p.rate <= b.upto_c) order by b.ord limit 1) as band
from people p;
$$;

comment on function staff_rates_months(date, date) is
  'Every active tracks_capacity non-excluded person employed in each month of the range, with staff_hourly_cost(person, month) and the comp band that rate falls in — one burden-stack call per person-month. The population and semantics of band_rate() / staff_band(); materialize it where used.';

create or replace function dept_avg_rate(p_department text, p_month date)
returns bigint
language sql
stable
as $$
  with r as (select * from staff_rates_months(p_month, p_month) where rate is not null)
  select coalesce((select round(avg(rate))::bigint from r where department = p_department),
                  (select round(avg(rate))::bigint from r));
$$;

-- ---------------------------------------------------------------------------
--  scope_labor: 097's numbers, on the rates table
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
-- 105: ONE burden-stack call per person-month for the whole flight
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
                  staff_hourly_cost(n.staff_id, n.month)) as rate
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

comment on function scope_labor(uuid) is
  'Labor per month as ONE number (097 semantics): named hours × staff_hourly_cost, placeholder hours × the department+band average, uncovered demand × the department average — all from staff_rates_months, one burden-stack call per person-month (105). Totals only; no per-person cost ever leaves SQL.';

-- ---------------------------------------------------------------------------
--  scope_months (104) — the deal margin once
-- ---------------------------------------------------------------------------
create or replace function scope_months(p_scope_id uuid)
returns table (
  scope_deal_id uuid, scope_line_id uuid, kind line_kind, label text, month date,
  media_funding media_funding, budget bigint, amount bigint, hours numeric,
  fee bigint, gp bigint, billable bigint, agency_media_out bigint, pass_through bigint, rebate bigint
) as $$
with pm as (select scope_prog_margin(p_scope_id) as m),   -- 105: once, not per row
lines as (
  select sd.id as scope_deal_id, sl.id as scope_line_id, sl.kind, sl.label, sl.media_funding,
         gs.month::date as month,
         coalesce(slm.amount, sl.amount) as amount,
         coalesce(slm.budget, sl.budget) as budget,
         coalesce(slm.hours,  sl.hours_per_month) as hours,
         sl.fee_pct, sl.rate, sl.structure,
         -- 104: the backend margin is a DEAL output — one margin across the scope's
         -- programmatic lines that lands the target GP on revenue; a line's own
         -- margin_pct (CPM lines, legacy rows) still wins
         coalesce(sl.margin_pct, (select m from pm),
           (select (value #>> '{}')::numeric from settings where key = 'programmatic_margin_default'), 35) as margin_pct
  from scope_deals sd
  join scope_lines sl on sl.scope_deal_id = sd.id
  cross join lateral generate_series(date_trunc('month', sd.flight_start), date_trunc('month', sd.flight_end), interval '1 month') gs(month)
  left join scope_line_months slm on slm.scope_line_id = sl.id and slm.month = gs.month::date
  where sd.scope_id = p_scope_id and sd.flight_start is not null and sd.flight_end is not null
),
calc as (
  select l.*,
         line_fee(l.budget, l.fee_pct, l.structure) as fee_raw,
         case l.kind
           when 'retainer'     then l.amount::numeric
           when 'custom'       then l.amount::numeric
           when 'creative'     then case when l.label like 'creative:hourly%' then round(l.rate * l.hours) else l.amount end
           when 'hourly'       then round(l.rate * l.hours)
           when 'search'       then round(line_fee(l.budget, l.fee_pct, l.structure))
           when 'social'       then round(line_fee(l.budget, l.fee_pct, l.structure))
           when 'programmatic' then round(l.budget * l.margin_pct / 100 + line_fee(l.budget, l.fee_pct, l.structure))
         end as gp_n
  from lines l
)
select c.scope_deal_id, c.scope_line_id, c.kind, c.label, c.month, c.media_funding, c.budget, c.amount, c.hours,
  -- the fee the client sees: the media fee for media kinds, the whole line for the rest
  case when c.kind in ('search', 'social', 'programmatic') then round(c.fee_raw)::bigint else c.gp_n::bigint end as fee,
  c.gp_n::bigint as gp,
  case c.kind
    when 'programmatic' then c.budget + round(c.fee_raw)::bigint
    else c.gp_n::bigint
  end as billable,
  case when c.kind in ('search', 'social') and c.media_funding = 'agency' then c.budget else 0 end as agency_media_out,
  case when c.kind in ('search', 'social') and c.media_funding = 'agency' then c.budget else 0 end as pass_through,
  -- 103: a line's own rebate wins; otherwise the SCOPE's rebate applies to
  -- every line it fits — basis media only to media lines, basis fee to all
  round(line_rebate(c.budget,
                    case when c.kind in ('search', 'social', 'programmatic') then c.fee_raw else c.gp_n end,
                    coalesce(nullif(c.structure #>> '{rebate,pct}', '')::numeric,
                             case when sc.rebate_basis = 'media' and c.kind not in ('search', 'social', 'programmatic') then 0
                                  else sc.rebate_pct end),
                    coalesce(c.structure #>> '{rebate,basis}', sc.rebate_basis)))::bigint as rebate
from calc c
cross join (select rebate_pct, rebate_basis from scopes where id = p_scope_id) sc;
$$ language sql stable;

-- ---------------------------------------------------------------------------
--  scope_staffing (097) — one pass over the hours, rates from the table
-- ---------------------------------------------------------------------------
create or replace function scope_staffing(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
with sc as (select * from scopes where id = p_scope_id),
flight as (
  select min(flight_start) as f0, max(flight_end) as f1 from scope_deals where scope_id = p_scope_id and flight_start is not null
),
months as (
  select gs::date as month from flight, generate_series(date_trunc('month', f0), date_trunc('month', f1), interval '1 month') gs
  where f0 is not null
),
kinds as (select distinct sl.kind from scope_lines sl join scope_deals sd on sd.id = sl.scope_deal_id where sd.scope_id = p_scope_id),
demand as (select department, month, hours from scope_dept_months where scope_id = p_scope_id),
named as (
  select department, month, sum(hours) as hours from scope_staff_months
  where scope_id = p_scope_id and staff_id is not null group by department, month
),
placeholders as (
  select department, month, sum(hours) as hours from scope_staff_months
  where scope_id = p_scope_id and staff_id is null group by department, month
),
gap as (
  select d.department, d.month, d.hours as demand,
         coalesce(n.hours, 0) as named, coalesce(p.hours, 0) as placeholder,
         greatest(d.hours - coalesce(n.hours, 0) - coalesce(p.hours, 0), 0) as unassigned
  from demand d
  left join named n on n.department = d.department and n.month = d.month
  left join placeholders p on p.department = d.department and p.month = d.month
),
cap as (
  select c.staff_id, c.month, c.capacity_hours,
         c.committed_hours - coalesce((select sum(a.hours) from assignments a
                                       where a.scope_id = p_scope_id and a.staff_id = c.staff_id and a.month = c.month), 0) as committed_other
  from flight, staff_capacity(f0, f1) c
  where f0 is not null
),
-- 105: one pass over the last twelve months of counted hours for everyone,
-- and the rate from the per-month rates table — not a burden-stack call per person
te12 as (
  select te.staff_id, te.client_id, te.deal_id, te.hours from time_entries te
  where te.staff_id is not null and te.worked_on >= current_date - interval '12 months'
    and coalesce(te.attribution, '') not in ('excluded', 'timeoff')
),
kind_deals as (select distinct dl.deal_id from deal_lines dl where dl.kind in (select kind from kinds)),
hist as (
  select staff_id,
         sum(hours) filter (where client_id = (select client_id from sc)) as client_hours,
         sum(hours) filter (where deal_id in (select deal_id from kind_deals)) as kind_hours
  from te12 group by staff_id
),
rates0 as materialized (select * from flight, staff_rates_months(f0, f0) where f0 is not null),
cand_base as (
  select s.id as staff_id, s.name, s.department,
         coalesce(h.client_hours, 0) as client_hours,
         coalesce(h.kind_hours, 0) as kind_hours,
         coalesce((select sum(greatest(c.capacity_hours - c.committed_other, 0)) from cap c where c.staff_id = s.id), 0) as free_total,
         (select r.rate from rates0 r where r.staff_id = s.id limit 1) as rate
  from staff s
  left join hist h on h.staff_id = s.id
  where s.active and s.tracks_capacity and not s.exclude_hours
),
cands as (
  select cb.*, row_number() over (partition by cb.department order by cb.client_hours desc, cb.kind_hours desc, cb.free_total desc, cb.rate asc nulls last, cb.name) as rank
  from cand_base cb
),
-- hours no free person in the department can cover, per month
dept_free as (
  select cb.department, c.month, sum(greatest(c.capacity_hours - c.committed_other, 0)) as free_hours
  from cand_base cb join cap c on c.staff_id = cb.staff_id
  group by cb.department, c.month
),
unstaffable as (
  select g.department, g.month, g.unassigned + g.placeholder as open_hours,
         greatest(g.unassigned + g.placeholder - coalesce(df.free_hours, 0), 0) as unstaffable
  from gap g left join dept_free df on df.department = g.department and df.month = g.month
),
knobs as (
  select coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_hire_fte_share_pct'), 50) as fte_share,
         coalesce((select (value #>> '{}')::int from settings where key = 'scope_hire_min_months'), 2) as min_months,
         coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_utilization_pct'), 80) as util
),
fte as (
  -- a full-time plannable month: 40 h/wk ÷ 5 × business days × utilization
  select m.month, round(40.0 / 5 * (select count(*) from generate_series(m.month, (m.month + interval '1 month - 1 day')::date, interval '1 day') d
                                     where extract(isodow from d) < 6) * (select util from knobs) / 100, 2) as fte_hours
  from months m
),
hire as (
  select u.department,
         sum(u.unstaffable) as hours,
         count(*) filter (where u.unstaffable >= (select fte_share from knobs) / 100 * f.fte_hours) as heavy_months,
         jsonb_object_agg(u.month::text, u.unstaffable) filter (where u.unstaffable > 0) as by_month,
         hire_hourly_cost(u.department) as hire_hourly_c,
         contractor_hourly_cost(u.department) as contractor_hourly_c
  from unstaffable u join fte f on f.month = u.month
  group by u.department
  having sum(u.unstaffable) > 0
)
select jsonb_build_object(
  'months', coalesce((select jsonb_agg(month order by month) from months), '[]'::jsonb),
  'gap', coalesce((select jsonb_agg(jsonb_build_object(
      'department', department, 'month', month, 'demand', demand, 'named', named,
      'placeholder', placeholder, 'unassigned', unassigned) order by department, month) from gap), '[]'::jsonb),
  'candidates', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', c.staff_id, 'name', c.name, 'department', c.department, 'rank', c.rank,
      'client_hours', round(c.client_hours, 1), 'kind_hours', round(c.kind_hours, 1),
      'free', coalesce((select jsonb_object_agg(cp.month::text, round(greatest(cp.capacity_hours - cp.committed_other, 0), 2))
                        from cap cp where cp.staff_id = c.staff_id), '{}'::jsonb))
      order by c.department, c.rank) from cands c), '[]'::jsonb),
  'unstaffable', coalesce((select jsonb_agg(jsonb_build_object(
      'department', department, 'month', month, 'open_hours', open_hours, 'unstaffable', unstaffable)
      order by department, month) from unstaffable where unstaffable > 0), '[]'::jsonb),
  'hire', coalesce((select jsonb_agg(jsonb_build_object(
      'department', h.department, 'hours', h.hours, 'by_month', h.by_month,
      'recommend', h.heavy_months >= (select min_months from knobs),
      'heavy_months', h.heavy_months,
      'hire_hourly_c', h.hire_hourly_c, 'contractor_hourly_c', h.contractor_hourly_c,
      'cost_hire', case when h.hire_hourly_c is null then null else round(h.hours * h.hire_hourly_c)::bigint end,
      'cost_contractor', case when h.contractor_hourly_c is null then null else round(h.hours * h.contractor_hourly_c)::bigint end)
      order by h.department) from hire h), '[]'::jsonb),
  'knobs', (select to_jsonb(k) from knobs k)
);
$$;

-- ---------------------------------------------------------------------------
--  scope_verdict (103) — hire re-pricing from the table
-- ---------------------------------------------------------------------------
create or replace function scope_verdict(p_scope_id uuid)
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
  from scope_months(p_scope_id) group by month
),
lab as (select * from scope_labor(p_scope_id)),
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
staffing as (select scope_staffing(p_scope_id) as s),
hire as (
  select sum((h ->> 'hours')::numeric) as hours,
         sum((h ->> 'cost_hire')::bigint) as cost_hire,
         sum((h ->> 'cost_contractor')::bigint) as cost_contractor,
         bool_or((h ->> 'recommend')::boolean) as recommend,
         bool_and(h ->> 'cost_hire' is not null) as hire_priced,
         bool_and(h ->> 'cost_contractor' is not null) as contractor_priced
  from staffing, jsonb_array_elements(staffing.s -> 'hire') h
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
-- client roll-up: the client's other live deals + this scope, per flight month
cd as (select client_detail((select client_id from sc)) as j where (select client_id from sc) is not null),
existing_measured as (
  select (x ->> 'month')::date as month, (x ->> 'gp_actual')::bigint as gp, (x ->> 'labor_actual')::bigint as labor
  from cd, jsonb_array_elements(cd.j -> 'months') x
  where (x ->> 'month')::date < date_trunc('month', current_date)::date
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
  select staff_id, month, staff_hourly_cost(staff_id, month) as rate from plan_labor_keys
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
-- "viable with a hire": re-price the unstaffable hours at the hire / contractor rate
alt as (
  select
    case when h.hours is null or h.hours = 0 then null
         when h.hire_priced then (select pal from tot) - h.cost_hire
             + (select coalesce(sum(round(l.hours * br.r)), 0) from
                (select (x ->> 'department') as department, (k.key)::date as month, (k.value)::numeric as hours
                 from staffing, jsonb_array_elements(staffing.s -> 'hire') x, jsonb_each_text(x -> 'by_month') k) l
                cross join lateral (select dept_avg_rate(l.department, l.month) as r) br)
         end as pal_hire,
    case when h.hours is null or h.hours = 0 then null
         when h.contractor_priced then (select pal from tot) - h.cost_contractor
             + (select coalesce(sum(round(l.hours * br.r)), 0) from
                (select (x ->> 'department') as department, (k.key)::date as month, (k.value)::numeric as hours
                 from staffing, jsonb_array_elements(staffing.s -> 'hire') x, jsonb_each_text(x -> 'by_month') k) l
                cross join lateral (select dept_avg_rate(l.department, l.month) as r) br)
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

-- ---------------------------------------------------------------------------
--  approvals_queue (103) / scope_page (104) — one verdict per scope
-- ---------------------------------------------------------------------------
create or replace function approvals_queue()
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

create or replace function scope_page(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
with own as (select scope_verdict(p_scope_id) as j)
select scope_state(p_scope_id)
  || jsonb_build_object(
  'econ', coalesce((select jsonb_agg(to_jsonb(m) order by m.month, m.scope_line_id) from scope_months(p_scope_id) m), '[]'::jsonb),
  'labor', coalesce((select jsonb_agg(to_jsonb(l) order by l.month) from scope_labor(p_scope_id) l), '[]'::jsonb),
  'staffing', scope_staffing(p_scope_id),
  'verdict', (select j from own),   -- 105: computed once, reused for the open scope's sibling row
  'existing_deals', scope_existing_deals(p_scope_id),   -- 103
  'prog_margin', scope_prog_margin(p_scope_id),          -- 104: the deal's backend margin (output)
  'versions', coalesce((select jsonb_agg(jsonb_build_object(
      'id', v.id, 'version', v.version, 'reason', v.reason, 'label', v.label, 'saved_by', v.saved_by, 'saved_at', v.saved_at)
      order by v.version desc) from scope_versions v where v.scope_id = p_scope_id), '[]'::jsonb),
  'siblings', coalesce((select jsonb_agg(jsonb_build_object(
      'id', s2.id, 'name', s2.name, 'scenario', s2.scenario, 'status', s2.status, 'version', s2.version,
      'kpis', (v.j -> 'total') || jsonb_build_object('status', v.j ->> 'status'))
      order by s2.created_at) from scopes s2
      cross join lateral (select case when s2.id = p_scope_id then (select j from own) else scope_verdict(s2.id) end as j) v   -- 105: once per sibling; the open scope reuses its own
      where s2.family_id = (select family_id from scopes where id = p_scope_id)), '[]'::jsonb),
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
$$;
