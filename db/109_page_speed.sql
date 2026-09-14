-- 109_page_speed.sql — every page's payload, computed once and only where asked.
--
-- Nothing here changes a number. Three shapes of waste are removed:
--
--   1. staff_hourly_cost() called once per (person, DAY). project_detail and
--      client_detail (094) priced their hours that way — ~2,900 burden-stack
--      calls for one deal, ~1.1 s in the PGlite bed, and the same walk again
--      for every scope re-priced against a live client (105/106 call both
--      RPCs). hours_page (062/090) already knew the fix: the breakdown only
--      depends on the date through THREE things — which comp_periods row
--      covers it, whether 401k eligibility has started, whether health
--      insurance has — so one call per (person, comp period, 401k, HI) is
--      exact. That rule now lives in ONE place, staff_day_rates(), and all
--      three read it. The per-day comp_periods lookup also stops being a
--      LATERAL … LIMIT 1 (one index probe per day) and becomes a range join
--      with DISTINCT ON, which is the same row by the same ordering.
--
--   2. The same per-month stack recomputed per caller: forecast_page,
--      labor_forecast_breakdown and cashflow_forecast each called
--      staff_base_labor_forecast_month() once per month (and cashflow once
--      per HALF-month), each of which sums a burden-stack call per active
--      person. staff_cost_months() computes the cohort once for the whole
--      range; staff_base_labor_forecast_months() is the monthly total in one
--      pass, with the same two roundings in the same order as the per-month
--      function (which stays, unchanged, as the single-month entry point).
--
--   3. Whole payload keys built for pages that never read them. forecast_page
--      and hours_page gain a _parts sibling taking p_parts text[]: null is
--      exactly today's payload (and forecast_page / hours_page themselves stay
--      put, as one-line wrappers passing null); a list builds only those keys
--      and drops the rest. The guards are CASE branches, and
--      an un-taken CASE branch never evaluates its subquery — so a page that
--      asks for six of hours_page's fourteen keys does not pay for the other
--      eight either. 108's five Team Hours keys alone are ~470 KB of a
--      ~650 KB payload that Home, Client Profitability and Project Hours
--      throw away.
--
-- Byte-identical output is the whole point: 109_fixture_test.sql asserts every
-- rewritten function against the pre-109 definition, row by row and key by key.

-- ---------------------------------------------------------------------------
--  1. staff_day_rates — what an hour cost on the day it was worked.
--     ONE copy of the cohort rule 062/090 proved and 094 did not use.
-- ---------------------------------------------------------------------------
create or replace function staff_day_rates(
  p_from     date default null,
  p_to       date default null,
  p_deal_ids uuid[] default null
)
returns table (staff_id uuid, worked_on date, rate bigint)
language sql
stable
as $$
with te as (
  -- 090: excluded people / excluded jobcodes and time-off-pending rows stay
  -- in the table (zero data loss) but are never priced or counted.
  select t.staff_id, t.worked_on
  from time_entries t
  where (p_from is null or t.worked_on >= p_from)
    and (p_to   is null or t.worked_on <= p_to)
    and (p_deal_ids is null or t.deal_id = any (p_deal_ids))
    and t.staff_id is not null
    and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
),
staff_days as (
  select distinct staff_id, worked_on from te
),
hi_setting as (
  select coalesce((select (value #>> '{}')::date from settings
                   where key = 'health_insurance_start_date'), '2099-01-01'::date) as hi_start
),
-- Per (staff, day): which comp_periods row covers it, and this staff's answer
-- to the two threshold comparisons on that day. Those three columns fully
-- determine staff_hourly_cost()'s output for that day — everything else the
-- burden stack reads (rates, wage bases, workers' comp / SUTA by state, the
-- PEO fee) is date-independent. DISTINCT ON … ORDER BY cp.starts_on desc
-- picks the same row the old LATERAL (… order by starts_on desc limit 1) did,
-- including the no-covering-period case, which the LEFT JOIN keeps as one row
-- with a null period_key.
cohorts as (
  select distinct on (sd.staff_id, sd.worked_on)
    sd.staff_id, sd.worked_on,
    cp.starts_on as period_key,
    (s.enrolled_401k
       and staff_401k_eligibility_date(s.start_date) is not null
       and sd.worked_on >= staff_401k_eligibility_date(s.start_date)) as k401_key,
    (s.enrolled_health_insurance and sd.worked_on >= hi_setting.hi_start) as hi_key
  from staff_days sd
  join staff s on s.id = sd.staff_id
  cross join hi_setting
  left join comp_periods cp
    on cp.staff_id = sd.staff_id
   and cp.starts_on <= sd.worked_on
   and (cp.ends_on is null or cp.ends_on >= sd.worked_on)
  order by sd.staff_id, sd.worked_on, cp.starts_on desc
),
-- One staff_hourly_cost() call per distinct cohort — MATERIALIZED so the
-- planner can't flatten this and push the call back down to per-row (062 hit
-- exactly this trap with the plain per-day version).
cohort_rates as materialized (
  select staff_id, period_key, k401_key, hi_key,
         staff_hourly_cost(staff_id, min(worked_on)) as rate
  from cohorts
  group by staff_id, period_key, k401_key, hi_key
)
-- coalesce, not `is not distinct from`: a null-safe comparison is not
-- hashable, so the planner falls back to a nested loop over every day
-- (that is most of what the per-day version cost). '-infinity' is not a
-- comp period start anyone can enter, so it collides with nothing.
select c.staff_id, c.worked_on, cr.rate
from cohorts c
join cohort_rates cr
  on cr.staff_id = c.staff_id
 and coalesce(cr.period_key, '-infinity'::date) = coalesce(c.period_key, '-infinity'::date)
 and cr.k401_key = c.k401_key
 and cr.hi_key = c.hi_key;
$$;

comment on function staff_day_rates(date, date, uuid[]) is
  'staff_hourly_cost(person, day) for every day someone logged countable hours '
  '(090: attribution not excluded / timeoff), optionally bounded by date and '
  'restricted to a set of deals. ONE burden-stack call per (person, comp '
  'period, 401k-eligible, health-insurance) cohort, which is exact: those three '
  'are the only things the breakdown reads the date for. hours_page, '
  'project_detail and client_detail all price their hours from this, so a '
  'deal''s labor is the same number on every page by construction (109).';

-- ---------------------------------------------------------------------------
--  2. staff_cost_on_dates — the burden stack per person per AS-OF DATE,
--     cohort-grouped, and the company monthly total the three forward-looking
--     pages share. A date array, not a month range: labor_forecast_breakdown's
--     series starts at greatest(p_from, this month), which is a mid-month date
--     whenever the page's range starts before today, and a 401k eligibility or
--     health-insurance start that falls inside that month would answer
--     differently on the 1st than on the 13th. The callers hand over exactly
--     the dates they would have called the per-date function with.
-- ---------------------------------------------------------------------------
create or replace function staff_cost_on_dates(p_dates date[])
returns table (
  staff_id        uuid,
  on_date         date,
  employment_type text,
  base_cents      bigint,
  burdened_cents  bigint,
  total_cents     bigint,
  hourly_cost     bigint
)
language sql
stable
as $$
with dates as (
  select distinct d from unnest(coalesce(p_dates, '{}'::date[])) d where d is not null
),
hi_setting as (
  select coalesce((select (value #>> '{}')::date from settings
                   where key = 'health_insurance_start_date'), '2099-01-01'::date) as hi_start
),
-- the same three-column cohort key staff_day_rates uses, on the caller's dates
cohorts as (
  select distinct on (s.id, dates.d)
    s.id as staff_id, dates.d as on_date,
    cp.starts_on as period_key,
    (s.enrolled_401k
       and staff_401k_eligibility_date(s.start_date) is not null
       and dates.d >= staff_401k_eligibility_date(s.start_date)) as k401_key,
    (s.enrolled_health_insurance and dates.d >= hi_setting.hi_start) as hi_key
  from staff s
  cross join dates
  cross join hi_setting
  left join comp_periods cp
    on cp.staff_id = s.id
   and cp.starts_on <= dates.d
   and (cp.ends_on is null or cp.ends_on >= dates.d)
  where s.active
  order by s.id, dates.d, cp.starts_on desc
),
keys as (
  select staff_id, period_key, k401_key, hi_key, min(on_date) as d0
  from cohorts group by 1, 2, 3, 4
),
-- one staff_burdened_cost_breakdown() per cohort. LEFT JOIN LATERAL, not
-- CROSS: a person with no comp_periods row covering that date returns zero
-- rows from the breakdown and must still appear with null cost columns —
-- staff_base_labor_forecast_month coalesces that to 0 and labor_page's roster
-- shows the person with empty cost cells (077); neither may silently drop them.
cohort_costs as materialized (
  select k.staff_id, k.period_key, k.k401_key, k.hi_key,
         b.employment_type, b.base_cents, b.burdened_cents, b.total_cents,
         -- the hourly rate through staff_hourly_cost itself, not re-derived
         -- from burdened_cents here: the null and zero-capacity cases are
         -- that function's rule and stay in one place (041)
         staff_hourly_cost(k.staff_id, k.d0) as hourly_cost
  from keys k
  left join lateral staff_burdened_cost_breakdown(k.staff_id, k.d0) b on true
)
-- coalesce rather than `is not distinct from`, so this join can hash
select c.staff_id, c.on_date, cc.employment_type, cc.base_cents, cc.burdened_cents, cc.total_cents, cc.hourly_cost
from cohorts c
join cohort_costs cc
  on cc.staff_id = c.staff_id
 and coalesce(cc.period_key, '-infinity'::date) = coalesce(c.period_key, '-infinity'::date)
 and cc.k401_key = c.k401_key
 and cc.hi_key = c.hi_key;
$$;

comment on function staff_cost_on_dates(date[]) is
  'staff_burdened_cost_breakdown() per ACTIVE person for each date given, one '
  'call per (person, comp period, 401k-eligible, health-insurance) cohort — the '
  'same exact-by-construction grouping staff_day_rates uses (109). The '
  'population is staff_base_labor_forecast_month''s (s.active); a caller that '
  'wants a narrower one filters it down.';

create or replace function staff_base_labor_forecast_dates(p_dates date[])
returns table (on_date date, total bigint)
language sql
stable
as $$
  -- staff_base_labor_forecast_month(d) for a whole list of dates in one pass.
  -- Same two roundings in the same order as the per-date function (075):
  -- round(sum(total)/12) first, then MINUS round(annual HI/12) — never one
  -- rounding over the difference.
  with dates as (
    select distinct d from unnest(coalesce(p_dates, '{}'::date[])) d where d is not null
  ),
  hi_rate as (
    select
      coalesce((select (value #>> '{}')::numeric from settings where key = 'health_insurance_monthly_cost'), 0) * 100 as hi_monthly_c,
      coalesce((select (value #>> '{}')::date from settings where key = 'health_insurance_start_date'), '2099-01-01'::date) as hi_start
  ),
  per_person_hi as (
    select dates.d,
           coalesce(sum(case when s.enrolled_health_insurance and dates.d >= hi_rate.hi_start
                             then hi_rate.hi_monthly_c * 12 else 0 end), 0) as annual_hi_cents
    from dates
    cross join hi_rate
    left join staff s on s.active
    group by dates.d
  ),
  gross as (
    -- FILTER, not coalesce-to-0: with no active staff at all the per-date
    -- function's sum() is null and it returns null, not 0. The LEFT JOIN
    -- always leaves one all-null row per date, so the filter is what keeps
    -- that case answering the same thing.
    select dates.d,
           round(sum(coalesce(c.total_cents, 0)) filter (where c.staff_id is not null)::numeric / 12)::bigint as total
    from dates
    left join staff_cost_on_dates(p_dates) c on c.on_date = dates.d
    group by dates.d
  )
  select g.d, g.total - round(h.annual_hi_cents::numeric / 12)::bigint
  from gross g join per_person_hi h on h.d = g.d;
$$;

comment on function staff_base_labor_forecast_dates(date[]) is
  'staff_base_labor_forecast_month() for a list of dates, in one pass over '
  'staff_cost_on_dates (109). forecast_page, labor_forecast_breakdown and '
  'cashflow_forecast all read this instead of calling the per-date function '
  'per date (cashflow was calling it per HALF-month, for the same twelve '
  'months, twice each). The single-date function is unchanged and stays the '
  'canonical definition.';

-- ---------------------------------------------------------------------------
--  3. project_detail / client_detail — 100's bodies, one CTE different.
--     Their day_rates walked every distinct (person, day) of the deal's whole
--     history through the burden stack: ~1.1 s for one opened project in the
--     bed, paid again by every scope priced against a live client (105/106
--     call both). Now they read staff_day_rates(), the same cohort rule
--     hours_page has used since 062 — so the cents are unchanged and equal to
--     hours_page's deal_labor by construction, which is what 094's fixture
--     asserts and 109's re-asserts.
-- ---------------------------------------------------------------------------
create or replace function project_detail(p_deal_id uuid)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
d as (
  select id, name, client_id, qbo_project_id, flight_start, flight_end
  from deals where id = p_deal_id
),
te as (
  select t.staff_id, t.worked_on, t.hours,
         coalesce(s.department, t.department, '(no department)') as department
  from time_entries t
  left join staff s on s.id = t.staff_id
  where t.deal_id = p_deal_id
    -- 091: the same rows hours_page counts (090_qbtime_hours_provenance) —
    -- excluded people and time-off-pending rows stay in the table, never here
    and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
),
weeks as (
  select date_trunc('week', worked_on)::date as week, department,
         sum(hours)::numeric as hours
  from te
  group by 1, 2
),
-- labor cost per month (094): the hours above priced exactly as hours_page
-- prices them. 109: through staff_day_rates(), the ONE copy of that rule —
-- one burden-stack call per (person, comp period, 401k, health-insurance)
-- cohort instead of one per person-DAY, which is the same rate for every day
-- in a cohort and was the whole cost of this function. A row with no staff
-- (unknown_user) has hours but no rate, and drops out of the cost here as it
-- does from hours_page's deal_labor.
day_rates as (
  select staff_id, worked_on, rate from staff_day_rates(null, null, array[p_deal_id])
),
labor as (
  select date_trunc('month', te.worked_on)::date as month,
         sum(te.hours * dr.rate)::bigint as labor
  from te
  join day_rates dr on dr.staff_id = te.staff_id and dr.worked_on = te.worked_on
  group by 1
),
plan as (
  select month, sum(billable)::bigint as rev_plan, sum(gp)::bigint as gp_plan,
         sum(rebate)::bigint as rebate_plan   -- 100
  from v_deal_month_forecast
  where deal_id = p_deal_id
  group by month
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, total
  from invoices
  where qbo_project_id = (select qbo_project_id from d)
),
nonrev as (
  select month, amount
  from v_invoice_lines_classified
  where qbo_project_id = (select qbo_project_id from d)
    and account_id is not null
    and not unjoined
    and class is not null
    and class <> 'income'
),
cost as (
  select month, class, amount
  from v_cost_lines_classified
  where qbo_project_id = (select qbo_project_id from d)
),
actual as (
  select month, sum(rev)::bigint as rev_actual, sum(cogs)::bigint as cogs_actual
  from (
    select month, total    as rev, 0::bigint as cogs from inv
    union all
    select month, -amount,         0         from nonrev
    union all
    select month, -amount,         0         from cost where class = 'income'
    union all
    select month, 0,               amount    from cost where class = 'cogs'
  ) u
  where month < (select m from cur)
  group by month
),
months as (
  select month from plan
  union
  select month from actual
  union
  -- a month with hours but no money is still a month with a (negative)
  -- profit after labor — it must have a row (094)
  select month from labor
  union
  select gs.month::date
  from d
  cross join lateral generate_series(
    date_trunc('month', d.flight_start),
    date_trunc('month', d.flight_end),
    interval '1 month') gs(month)
  where d.flight_start is not null and d.flight_end is not null
),
-- a closed month is measured even when nothing happened in it: 0, not null
measured as (
  select m.month,
         case when m.month < (select m from cur) then coalesce(a.rev_actual, 0) end   as rev_actual,
         case when m.month < (select m from cur) then coalesce(a.cogs_actual, 0) end  as cogs_actual,
         -- labor follows the same rule: measured once the month is over, 0 when
         -- nobody logged an hour, null while the month is still running (094)
         case when m.month < (select m from cur) then coalesce(l.labor, 0) end        as labor_actual
  from months m
  left join actual a on a.month = m.month
  left join labor  l on l.month = m.month
)
select jsonb_build_object(
  'deal', (select to_jsonb(d) from d),
  'measured_through', (select (m - interval '1 month')::date from cur),
  'weeks', coalesce((select jsonb_agg(jsonb_build_object(
      'week', w.week, 'department', w.department, 'hours', w.hours)
      order by w.week, w.department) from weeks w), '[]'::jsonb),
  'months', coalesce((select jsonb_agg(jsonb_build_object(
      'month',       m.month,
      'rev_actual',  m.rev_actual,
      'cogs_actual', m.cogs_actual,
      'gp_actual',   m.rev_actual - m.cogs_actual,
      -- 094: hours-based labor and profit after labor (gross profit − labor),
      -- both null until the month closes. No plan twin: assignments carry
      -- no cost, so there is no planned labor to subtract from gp_plan.
      'labor_actual', m.labor_actual,
      'pal_actual',   m.rev_actual - m.cogs_actual - m.labor_actual,
      'rev_plan',    p.rev_plan,
      'gp_plan',     p.gp_plan,
      'rebate_plan', p.rebate_plan)   -- 100: planned rebate (COGS) per month
      order by m.month)
      from measured m
      left join plan p on p.month = m.month), '[]'::jsonb)
);
$$ language sql stable;

create or replace function client_detail(p_client_id uuid)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
d as (
  select id, name, qbo_project_id, flight_start, flight_end
  from deals where client_id = p_client_id
),
projs as (
  select distinct qbo_project_id from d where qbo_project_id is not null
),
te as (
  select t.deal_id, t.staff_id, t.worked_on, t.hours,
         coalesce(s.department, t.department, '(no department)') as department
  from time_entries t
  left join staff s on s.id = t.staff_id
  where t.deal_id in (select id from d)
    and coalesce(t.attribution, '') not in ('excluded', 'timeoff')   -- 091, as above
),
weeks as (
  select date_trunc('week', worked_on)::date as week, department,
         sum(hours)::numeric as hours
  from te
  group by 1, 2
),
weeks_by_deal as (
  select date_trunc('week', worked_on)::date as week, deal_id,
         sum(hours)::numeric as hours
  from te
  group by 1, 2
),
-- labor cost per month (094): the hours above priced exactly as hours_page
-- prices them. 109: through staff_day_rates(), the ONE copy of that rule —
-- one burden-stack call per (person, comp period, 401k, health-insurance)
-- cohort instead of one per person-DAY, which is the same rate for every day
-- in a cohort and was the whole cost of this function. A row with no staff
-- (unknown_user) has hours but no rate, and drops out of the cost here as it
-- does from hours_page's deal_labor.
day_rates as (
  select staff_id, worked_on, rate from staff_day_rates(null, null, (select array_agg(id) from d))
),
labor as (
  select date_trunc('month', te.worked_on)::date as month,
         sum(te.hours * dr.rate)::bigint as labor
  from te
  join day_rates dr on dr.staff_id = te.staff_id and dr.worked_on = te.worked_on
  group by 1
),
plan as (
  select month, sum(billable)::bigint as rev_plan, sum(gp)::bigint as gp_plan,
         sum(rebate)::bigint as rebate_plan   -- 100
  from v_deal_month_forecast
  where deal_id in (select id from d)
  group by month
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, total
  from invoices
  where qbo_project_id in (select qbo_project_id from projs)
),
nonrev as (
  select month, amount
  from v_invoice_lines_classified
  where qbo_project_id in (select qbo_project_id from projs)
    and account_id is not null
    and not unjoined
    and class is not null
    and class <> 'income'
),
cost as (
  select month, class, amount
  from v_cost_lines_classified
  where qbo_project_id in (select qbo_project_id from projs)
),
actual as (
  select month, sum(rev)::bigint as rev_actual, sum(cogs)::bigint as cogs_actual
  from (
    select month, total    as rev, 0::bigint as cogs from inv
    union all
    select month, -amount,         0         from nonrev
    union all
    select month, -amount,         0         from cost where class = 'income'
    union all
    select month, 0,               amount    from cost where class = 'cogs'
  ) u
  where month < (select m from cur)
  group by month
),
engagement as (
  select min(flight_start) as flight_start, max(flight_end) as flight_end from d
),
months as (
  select month from plan
  union
  select month from actual
  union
  select month from labor   -- 094, as in project_detail
  union
  select gs.month::date
  from engagement e
  cross join lateral generate_series(
    date_trunc('month', e.flight_start),
    date_trunc('month', e.flight_end),
    interval '1 month') gs(month)
  where e.flight_start is not null and e.flight_end is not null
),
measured as (
  select m.month,
         case when m.month < (select m from cur) then coalesce(a.rev_actual, 0) end   as rev_actual,
         case when m.month < (select m from cur) then coalesce(a.cogs_actual, 0) end  as cogs_actual,
         -- labor follows the same rule: measured once the month is over, 0 when
         -- nobody logged an hour, null while the month is still running (094)
         case when m.month < (select m from cur) then coalesce(l.labor, 0) end        as labor_actual
  from months m
  left join actual a on a.month = m.month
  left join labor  l on l.month = m.month
)
select jsonb_build_object(
  'client_id', p_client_id,
  'deal_ids', coalesce((select jsonb_agg(id) from d), '[]'::jsonb),
  'deals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'flight_start', flight_start, 'flight_end', flight_end)
      order by flight_start nulls last, name) from d), '[]'::jsonb),
  'engagement', (select to_jsonb(e) from engagement e),
  'measured_through', (select (m - interval '1 month')::date from cur),
  'weeks', coalesce((select jsonb_agg(jsonb_build_object(
      'week', w.week, 'department', w.department, 'hours', w.hours)
      order by w.week, w.department) from weeks w), '[]'::jsonb),
  'weeks_by_deal', coalesce((select jsonb_agg(jsonb_build_object(
      'week', w.week, 'deal_id', w.deal_id, 'hours', w.hours)
      order by w.week, w.deal_id) from weeks_by_deal w), '[]'::jsonb),
  'months', coalesce((select jsonb_agg(jsonb_build_object(
      'month',       m.month,
      'rev_actual',  m.rev_actual,
      'cogs_actual', m.cogs_actual,
      'gp_actual',   m.rev_actual - m.cogs_actual,
      -- 094: hours-based labor and profit after labor (gross profit − labor),
      -- both null until the month closes. No plan twin: assignments carry
      -- no cost, so there is no planned labor to subtract from gp_plan.
      'labor_actual', m.labor_actual,
      'pal_actual',   m.rev_actual - m.cogs_actual - m.labor_actual,
      'rev_plan',    p.rev_plan,
      'gp_plan',     p.gp_plan,
      'rebate_plan', p.rebate_plan)   -- 100: planned rebate (COGS) per month
      order by m.month)
      from measured m
      left join plan p on p.month = m.month), '[]'::jsonb)
);
$$ language sql stable;

-- ---------------------------------------------------------------------------
--  4. hours_page — 108's body, two changes: the day rates come from
--     staff_day_rates() (same cohort rule, one copy), and p_parts picks the
--     keys. p_parts null = 108's payload exactly.
--
--     Why parts: 108 appended five keys for Team Hours' forecast profit
--     (measured_before, staff_hours_deal_month, staff_deal_planned_month,
--     deal_forecast, staff_rate_month). On a twelve-month range in the bed
--     those five are ~470 KB of a ~650 KB payload — and Home, Client
--     Profitability and Project Hours, which also call this, read none of
--     them. An un-taken CASE branch never evaluates its subquery, so a page
--     that names its keys skips the work as well as the bytes.
-- ---------------------------------------------------------------------------
create or replace function hours_page_parts(p_from date, p_to date, p_parts text[] default null)
returns jsonb as $$
with te as (
  -- 090: excluded people / excluded jobcodes and time-off-pending rows are
  -- kept in the table (zero data loss) but never priced or counted here.
  -- 109: four named columns rather than select *, so the 50k-row scan the
  -- twelve-month ranges do carries what it needs and nothing else.
  select staff_id, deal_id, worked_on, hours from time_entries
  where worked_on between p_from and p_to
    and coalesce(attribution, '') not in ('excluded', 'timeoff')
),
-- 109: the cohort rule (one staff_hourly_cost() per person / comp period /
-- 401k / health-insurance, never per person-day) now lives in
-- staff_day_rates, which project_detail and client_detail read too.
day_rates as (
  select staff_id, worked_on, rate from staff_day_rates(p_from, p_to)
),
labor as (
  -- 109: priced once, at the finest grain every key below is a roll-up of.
  -- The four hours keys used to be four independent passes over every
  -- priced row; they now roll up this one. Rows with no deal stay in (a
  -- person's staff_hours_month counts their internal hours, deal_labor does
  -- not), and the sums stay NUMERIC here — each key casts to bigint itself,
  -- exactly once, so a sum of sums is the same cents as a sum of the raw
  -- rows rather than a sum of roundings.
  select te.staff_id, te.deal_id, date_trunc('month', te.worked_on)::date as month,
         sum(te.hours) as hours, sum(te.hours * day_rates.rate) as cost
  from te
  join day_rates on day_rates.staff_id = te.staff_id and day_rates.worked_on = te.worked_on
  group by te.staff_id, te.deal_id, date_trunc('month', te.worked_on)::date
),
planned as (
  select deal_id, staff_id, month, hours as planned_hours
  from assignments
  where month between date_trunc('month', p_from) and date_trunc('month', p_to)
),
-- 108: the forecast side, whole months from the current one on
cur as (select date_trunc('month', current_date)::date as m)
select jsonb_build_object(
  'staff', case when p_parts is null or 'staff' = any (p_parts) then coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active,
      'start_date', s.start_date, 'end_date', s.end_date, 'tracks_capacity', s.tracks_capacity,
      -- 109: same answer as the per-person exists() this replaces, resolved in
      -- one pass over time_entries instead of a subplan per person
      'has_recent_hours', h.staff_id is not null))
      from staff s
      left join (select distinct staff_id from time_entries where staff_id is not null) h
        on h.staff_id = s.id), '[]'::jsonb) end,
  'comp_current', case when p_parts is null or 'comp_current' = any (p_parts) then coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', s.id, 'kind', cp.kind, 'annual_cost', cp.annual_cost,
      'hourly_cost', cp.hourly_cost, 'weekly_capacity', coalesce(cp.weekly_capacity, 40),
      'starts_on', cp.starts_on))
      from staff s left join comp_periods cp on cp.staff_id = s.id and cp.ends_on is null), '[]'::jsonb) end,
  'staff_hours_month', case when p_parts is null or 'staff_hours_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, month, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor group by staff_id, month) t), '[]'::jsonb) end,
  'staff_hours_deal', case when p_parts is null or 'staff_hours_deal' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by staff_id, deal_id) t), '[]'::jsonb) end,
  'staff_planned', case when p_parts is null or 'staff_planned' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, sum(planned_hours)::numeric as planned_hours
      from planned group by staff_id) t), '[]'::jsonb) end,
  'staff_deal_planned', case when p_parts is null or 'staff_deal_planned' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by staff_id, deal_id) t), '[]'::jsonb) end,
  'deal_labor', case when p_parts is null or 'deal_labor' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by deal_id) t), '[]'::jsonb) end,
  'deal_planned', case when p_parts is null or 'deal_planned' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by deal_id) t), '[]'::jsonb) end,
  'time_off', case when p_parts is null or 'time_off' = any (p_parts) then coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'starts_on', starts_on, 'ends_on', ends_on, 'kind', kind, 'hours', hours))
      from time_off where ends_on >= p_from and starts_on <= p_to), '[]'::jsonb) end,
  -- 108: appended — nothing above this line moved
  'measured_before', case when p_parts is null or 'measured_before' = any (p_parts) then to_jsonb((select m from cur)) end,
  'staff_hours_deal_month', case when p_parts is null or 'staff_hours_deal_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, month, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by staff_id, deal_id, month) t), '[]'::jsonb) end,
  'staff_deal_planned_month', case when p_parts is null or 'staff_deal_planned_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, month, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by staff_id, deal_id, month) t), '[]'::jsonb) end,
  'deal_forecast', case when p_parts is null or 'deal_forecast' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select f.deal_id, f.month, sum(f.billable)::bigint as billable, sum(f.gp)::bigint as gp
      from v_deal_month_forecast f
      where f.month between date_trunc('month', p_from) and date_trunc('month', p_to)
        and f.month >= (select m from cur)
      group by f.deal_id, f.month) t), '[]'::jsonb) end,
  'staff_rate_month', case when p_parts is null or 'staff_rate_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select r.staff_id, r.month, r.rate
      from staff_rates_months(greatest(date_trunc('month', p_from)::date, (select m from cur)),
                              date_trunc('month', p_to)::date) r
      where r.rate is not null) t), '[]'::jsonb) end
)
-- keys the caller did not ask for are removed outright, not left as nulls: a
-- page checking `H.deal_forecast` for a pre-108 payload must not see one.
- (select coalesce(array_agg(k), '{}'::text[])
   from unnest(array['staff','comp_current','staff_hours_month','staff_hours_deal','staff_planned',
                     'staff_deal_planned','deal_labor','deal_planned','time_off','measured_before',
                     'staff_hours_deal_month','staff_deal_planned_month','deal_forecast','staff_rate_month']) k
   where p_parts is not null and not (k = any (p_parts)));
$$ language sql stable;

-- hours_page keeps its name AND its two-argument signature: every existing
-- caller, script and fixture resolves exactly as before, and PostgREST has one
-- unambiguous candidate per name. A defaulted third argument on the same name
-- would have made hours_page(a, b) ambiguous the moment anything recreated the
-- two-argument form — which is exactly what db/076_fixture_test.sql does to
-- forecast_page.
create or replace function hours_page(p_from date, p_to date)
returns jsonb
language sql
stable
as $$ select hours_page_parts(p_from, p_to, null) $$;

comment on function hours_page(date, date) is
  'Every page''s hours payload, whole (108''s keys exactly) — hours_page_parts '
  'with no key list.';

comment on function hours_page_parts(date, date, text[]) is
  'Every page''s hours payload (108''s keys exactly). 109: p_parts names the '
  'keys wanted — null is the whole payload, unchanged; a list builds only '
  'those and drops the rest, and an un-taken CASE branch never runs its '
  'subquery, so the work is skipped too. Rates come from staff_day_rates(), '
  'the one copy of the cohort rule, shared with project_detail/client_detail.';

-- ---------------------------------------------------------------------------
--  5. forecast_page — 100's body, two changes: p_parts (the same rule as
--     hours_page above) and the forward labor months computed in one pass.
--     Home reads five of its eleven keys, Client Profitability and Project
--     Hours four; projects (~22 KB) and plan_deal (~31 KB) were built for
--     every one of them, every time.
--
--     forecast_page(from, to) keeps its name and signature and becomes a
--     one-line wrapper; the keyed body is forecast_page_parts. Overloading one
--     name with a defaulted third argument would have made forecast_page(a, b)
--     ambiguous — and db/076_fixture_test.sql recreates that exact signature.
-- ---------------------------------------------------------------------------
create or replace function forecast_page_parts(p_from date, p_to date, p_parts text[] default null)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
plan as (
  select deal_id, month, gp, billable, rebate from v_deal_month_forecast   -- 100: + rebate
  where month between p_from and p_to
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on::timestamp)::date between p_from and p_to
),
-- invoice lines that post somewhere other than an income account: customer
-- deposits and pre-payments, which QuickBooks puts on the balance sheet and
-- keeps out of Total Income (079). Subtracted from the invoice total below.
-- Every condition here is a reason to subtract; anything unresolved falls
-- through and stays revenue.
nonrev as (
  select month, qbo_project_id, amount
  from v_invoice_lines_classified
  where month between p_from and p_to
    and account_id is not null
    and not unjoined
    and class is not null
    and class <> 'income'
),
-- one scan of v_cost_lines_classified spanning both the display range and
-- the trailing-6-month runrate window (076) — everything below reads from
-- this, not from the view directly.
bounds as (
  select least(p_from, ((select m from cur) - interval '6 months')::date) as lo,
         greatest(p_to, (select m from cur)) as hi
),
cost_all as (
  select month, class, qbo_project_id, account_name, amount, issued_on, ebitda_addback
  from v_cost_lines_classified
  where month between (select lo from bounds) and (select hi from bounds)
),
cost as (
  select month, class, qbo_project_id, account_name, amount, ebitda_addback
  from cost_all
  where month between p_from and p_to
),
-- same rows cost_runrate_monthly/payroll_loose_runrate/health_insurance_
-- forecast_month's trailing branch would each independently re-select.
cost_trail as (
  select class, account_name, amount, ebitda_addback
  from cost_all
  where issued_on >= (select m from cur) - interval '6 months'
    and issued_on <  (select m from cur)
),
-- matches cost_runrate_monthly(class, 6) for the 2 classes forecast_page uses.
-- 'other' is no longer forecast (093): it holds one-off / incremental lines,
-- and averaging them forward invented a recurring cost that never recurs.
runrate_trail as (
  select class, coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class in ('payroll', 'overhead')
  group by class
),
-- the EBITDA add-back's forward month (093): the same six-month trailing
-- window as the overhead run-rate, restricted to the add-back lines INSIDE
-- that run-rate. Only class 'overhead' — it is the one forecast cost that is
-- a trailing average of real lines. Labour forecasts from Team setup, COGS
-- from the plan, 'other' is not forecast at all, so none of them can carry a
-- depreciation, interest or below-the-line line into a forward month.
addback_trail as (
  select coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class = 'overhead' and ebitda_addback
),
-- matches payroll_loose_runrate() (074: exact match, not substring)
loose_payroll_trail as (
  select coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class = 'payroll' and account_name ilike 'Labor Cost:Payroll expenses'
),
-- matches health_insurance_forecast_month's pre-cutover trailing-average branch
health_ins_trail as (
  select coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class = 'payroll' and account_name ilike '%health insurance%'
),
-- matches health_insurance_forecast_month's post-cutover tier-sum branch
health_tier_sum as (
  select coalesce(sum(t.monthly_cost), 0) as total
  from staff s
  join health_insurance_tiers t on t.tier_key = s.health_insurance_tier
  where s.enrolled_health_insurance
),
health_cutover as (
  select coalesce(
    (select (value #>> '{}')::date from settings where key = 'health_insurance_flat_rate_cutover'),
    '2026-11-01'::date
  ) as d
),
act_projects as (
  select qbo_project_id as id from inv
  union
  select qbo_project_id from cost where qbo_project_id is not null
  union
  select qbo_project_id from deals where qbo_project_id is not null
),
keep_projects as (
  select p.* from qbo_projects p
  where p.hidden = false and (
    p.id in (select id from act_projects)
    or p.id in (select coalesce(q.parent_id, q.id) from qbo_projects q
                where q.id in (select id from act_projects))
    or p.id in (select qbo_customer_id from clients where qbo_customer_id is not null)
  )
),
bonus_forecast as (
  select date_trunc('month', b.pay_date)::date as month,
         sum(staff_bonus_burdened_cost(b.id)) as total
  from staff_bonuses b
  where date_trunc('month', b.pay_date)::date between p_from and p_to
  group by date_trunc('month', b.pay_date)::date
),
-- one row per future month (from "now" through p_to, clamped to p_from..p_to).
-- loose-payroll and health-insurance no longer call their functions per row
-- (076) — both read from the single-scan CTEs above, computed once.
-- 109: one pass over the burden stack for every forward month instead of
-- staff_base_labor_forecast_month() once per month, each of which walked
-- every active person. Same dates, same per-date number — the bulk function
-- keeps 075's two roundings in 075's order.
fc_months as (
  select gm.month::date as month
  from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
),
base_labor as (
  select on_date, total
  from staff_base_labor_forecast_dates((select array_agg(month) from fc_months))
),
labor_forecast_month as (
  select m.month,
         bl.total
           + (select total from loose_payroll_trail)
           + (case when m.month >= (select d from health_cutover)
                   then (select total from health_tier_sum)
                   else (select total from health_ins_trail) end)
           + coalesce((select total from bonus_forecast bf where bf.month = m.month), 0) as total
  from fc_months m
  left join base_labor bl on bl.on_date = m.month
)
select jsonb_build_object(

  'plan_month', case when p_parts is null or 'plan_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select month, sum(gp)::bigint as gp, sum(billable)::bigint as billable,
             sum(rebate)::bigint as rebate   -- 100: the rebate the plan pays back, COGS in the forward months
      from plan group by month) t), '[]'::jsonb) end,
  'plan_deal', case when p_parts is null or 'plan_deal' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select deal_id,
        sum(gp)::bigint as gp_all,
        coalesce(sum(gp) filter (where month < (select m from cur)), 0)::bigint as gp_settled,
        coalesce(sum(billable) filter (where month >= (select m from cur)), 0)::bigint as bill_future,
        -- 100: rebates, whole plan and forward months only — profit after labor wants gp − rebate
        coalesce(sum(rebate), 0)::bigint as rebate_all,
        coalesce(sum(rebate) filter (where month >= (select m from cur)), 0)::bigint as rebate_future
      from plan group by deal_id) t), '[]'::jsonb) end,
  'rev_month', case when p_parts is null or 'rev_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select month, sum(total)::bigint as total from (
        select month, total from inv
        union all
        -- balance-sheet invoice lines (customer deposits / pre-payments) are
        -- not income in QuickBooks and are not revenue here either (080)
        select month, -amount as total from nonrev
        union all
        -- contra-revenue: debits to income-type accounts (search/social media
        -- pass-through offsets) net against invoiced revenue, as QuickBooks does
        select month, -amount as total from cost where class = 'income'
      ) u group by month) t), '[]'::jsonb) end,
  'rev_proj', case when p_parts is null or 'rev_proj' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(total)::bigint as total from (
        select qbo_project_id, month, total from inv
        union all
        select qbo_project_id, month, -amount from nonrev
        where qbo_project_id is not null
        union all
        select qbo_project_id, month, -amount from cost
        where class = 'income' and qbo_project_id is not null
      ) u where month < (select m from cur) and qbo_project_id is not null   -- 092: closed months only
      group by qbo_project_id) t), '[]'::jsonb) end,
  'cost_month', case when p_parts is null or 'cost_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select month, class, sum(amount)::bigint as total from cost group by month, class) t), '[]'::jsonb) end,
  -- EBITDA add-back per measured month (093): cost lines on accounts flagged
  -- ebitda_addback, in the four classes the chart subtracts from net.
  -- EBITDA for a month = net + this. Other-Income-typed lines are negative in
  -- the view, so interest EARNED lowers EBITDA exactly as it raised net.
  'addback_month', case when p_parts is null or 'addback_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select month, sum(amount)::bigint as total from cost
      where ebitda_addback and class in ('cogs', 'payroll', 'overhead', 'other')
      group by month) t), '[]'::jsonb) end,
  'cogs_proj', case when p_parts is null or 'cogs_proj' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(amount)::bigint as total
      from cost where class = 'cogs' and month < (select m from cur)   -- 092: closed months only
        and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb) end,
  'accounts', case when p_parts is null or 'accounts' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select class, coalesce(account_name, '(no account)') as account,
             sum(amount)::bigint as total
      from cost group by class, account_name) t), '[]'::jsonb) end,
  'runrates', case when p_parts is null or 'runrates' = any (p_parts) then jsonb_build_object(
      'payroll',  coalesce((select total from runrate_trail where class = 'payroll'), 0),
      'overhead', coalesce((select total from runrate_trail where class = 'overhead'), 0),
      'addback',  (select total from addback_trail)) end,
  'labor_forecast_month', case when p_parts is null or 'labor_forecast_month' = any (p_parts) then coalesce((select jsonb_agg(t) from labor_forecast_month t), '[]'::jsonb) end,
  'projects', case when p_parts is null or 'projects' = any (p_parts) then coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'parent_id', parent_id, 'jobcode', jobcode))
      from keep_projects), '[]'::jsonb) end
)
-- keys the caller did not ask for are removed outright, not left as nulls,
-- so a page can still tell a missing key from a key that is legitimately null.
- (select coalesce(array_agg(k), '{}'::text[])
   from unnest(array['plan_month','plan_deal','rev_month','rev_proj','cost_month','addback_month','cogs_proj','accounts','runrates','labor_forecast_month','projects']) k
   where p_parts is not null and not (k = any (p_parts)));
$$ language sql stable;

-- as with hours_page above: the two-argument forecast_page keeps its name and
-- signature, so scripts/check-august-project-revenue.sql and
-- db/076_fixture_test.sql (which recreates this exact signature to prove 076
-- against 071) both keep working.
create or replace function forecast_page(p_from date, p_to date)
returns jsonb
language sql
stable
as $$ select forecast_page_parts(p_from, p_to, null) $$;

comment on function forecast_page(date, date) is
  'The whole Forecast page in one jsonb (100''s keys exactly) — '
  'forecast_page_parts with no key list.';

comment on function forecast_page_parts(date, date, text[]) is
  'The whole Forecast page in one jsonb (100''s keys exactly). 109: p_parts '
  'names the keys wanted — null is the whole payload, unchanged; a list builds '
  'only those and an un-taken CASE branch never runs its subquery, so the work '
  'is skipped with the bytes. The forward labor months come from '
  'staff_base_labor_forecast_dates() in one pass instead of one burden-stack '
  'walk per month.';

-- ---------------------------------------------------------------------------
--  6. labor_forecast_breakdown — 077's body, the per-month function calls
--     hoisted. It called staff_base_labor_forecast_month() AND
--     health_insurance_forecast_month() once per month; the first walked every
--     active person through the burden stack, the second re-scanned six months
--     of cost lines, and both answered from inputs that do not vary across the
--     range. labor_page is unchanged and still just wraps this.
-- ---------------------------------------------------------------------------
create or replace function labor_forecast_breakdown(p_from date, p_to date)
returns table (
  month                   date,
  base_statutory_cents    bigint,
  loose_payroll_cents     bigint,
  health_insurance_cents  bigint,
  bonus_cents             bigint,
  total_cents             bigint
) as $$
  with cur as (select date_trunc('month', current_date)::date as m),
  months as (
    select gm.month::date as month
    from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
  ),
  bonus_forecast as (
    select date_trunc('month', b.pay_date)::date as month,
           sum(staff_bonus_burdened_cost(b.id)) as total
    from staff_bonuses b
    where date_trunc('month', b.pay_date)::date between p_from and p_to
    group by date_trunc('month', b.pay_date)::date
  ),
  -- MATERIALIZED, both of these: they are CROSS JOINed to the month list
  -- below, and PostgreSQL inlines a CTE referenced once — which evaluated
  -- payroll_loose_runrate() (a six-month scan of the cost lines) once per
  -- month of the range. 077 had the same shape and the same cost.
  loose as materialized (
    select payroll_loose_runrate() as total
  ),
  -- 109: one pass for the whole range instead of staff_base_labor_forecast_month()
  -- per month. The dates handed over are the same ones the per-date function
  -- would have been called with — note this series starts at greatest(p_from,
  -- this month), which is TODAY'S DATE, not the 1st, whenever the page's range
  -- starts in the past; a 401k eligibility or health-insurance start inside
  -- that month answers differently on the 1st than on the 13th, which is why
  -- the bulk function takes dates rather than a month range.
  base_labor as (
    select on_date, total
    from staff_base_labor_forecast_dates((select array_agg(month) from months))
  ),
  -- 109: health_insurance_forecast_month() decides between a tier sum and a
  -- six-month trailing average by comparing the month to the cutover; both
  -- sides are constants for the whole range, so they are computed once here
  -- and chosen per month below. Both `exists` guards come along — dropping
  -- them is what would make this disagree with the function.
  hi_branch as materialized (
    select
      coalesce((select (value #>> '{}')::date from settings where key = 'health_insurance_flat_rate_cutover'),
               '2026-11-01'::date) as cutover,
      (exists (select 1 from health_insurance_tiers where monthly_cost > 0)
       and exists (select 1 from staff where health_insurance_tier is not null)) as use_tiers,
      coalesce((select sum(t.monthly_cost)
                from staff s join health_insurance_tiers t on t.tier_key = s.health_insurance_tier
                where s.enrolled_health_insurance), 0)::bigint as tier_total,
      coalesce(round((select sum(amount) from v_cost_lines_classified
                      where class = 'payroll' and account_name ilike '%health insurance%'
                        and issued_on >= date_trunc('month', current_date) - interval '6 months'
                        and issued_on <  date_trunc('month', current_date))::numeric / 6)::bigint, 0) as trail_total
  ),
  per_month as (
    select
      m.month,
      bl.total as base_statutory_cents,
      loose.total as loose_payroll_cents,
      (case when m.month >= hi_branch.cutover and hi_branch.use_tiers
            then hi_branch.tier_total else hi_branch.trail_total end) as health_insurance_cents,
      coalesce(bf.total, 0) as bonus_cents
    from months m
    left join bonus_forecast bf on bf.month = m.month
    left join base_labor bl on bl.on_date = m.month
    cross join loose
    cross join hi_branch
  )
  select month, base_statutory_cents, loose_payroll_cents, health_insurance_cents, bonus_cents,
         (base_statutory_cents + loose_payroll_cents + health_insurance_cents + bonus_cents) as total_cents
  from per_month
$$ language sql stable;

comment on function labor_forecast_breakdown(date, date) is
  'Forward monthly labor-cost trend, broken into named components (077), for '
  'the Labor page''s trend chart. Zero duplicated formula: the same canonical '
  'functions, now called once for the range rather than once per month (109) — '
  'staff_base_labor_forecast_dates for the base, one hi_branch CTE standing in '
  'for health_insurance_forecast_month''s two constant sides (both its exists '
  'guards included), payroll_loose_runrate and staff_bonus_burdened_cost '
  'unchanged. Same cents, asserted per month in 109_fixture_test.';

-- ---------------------------------------------------------------------------
--  7. cashflow_forecast — 087's body, four repeated computations hoisted out
--     of the per-period loops. Nothing about the model moves: same periods,
--     same curves, same opening position, same contracted inflow.
-- ---------------------------------------------------------------------------
create or replace function cashflow_forecast(periods int default 12)
returns table (
  week_start        date,
  period_label      text,
  cash_in_early     bigint,
  cash_in_expected  bigint,
  cash_in_late      bigint,
  in_contracted_early    bigint,
  in_contracted_expected bigint,
  in_contracted_late     bigint,
  out_bills         bigint,
  out_payroll       bigint,
  out_overhead      bigint,
  out_agency_media  bigint,
  out_contracted_cogs bigint,
  position_optimistic   bigint,
  position_expected     bigint,
  position_conservative bigint
) as $$
declare
  opening       bigint;
  operating_set boolean;
  -- programmatic/forecast COGS terms: due N days after the last day of the spend
  -- month. Human-owned setting, default 45.
  cogs_due_days int := coalesce((select (value #>> '{}')::int from settings
                                 where key = 'programmatic_cogs_due_days'), 45);
  -- 109: these three are the same six-month trailing window over
  -- v_cost_lines_classified — cost_runrate_monthly('overhead'),
  -- payroll_loose_runrate(), and health_insurance_forecast_month's
  -- pre-cutover branch. One scan below fills all three instead of three
  -- identical ones, with each figure rounded exactly as its own function
  -- rounds it.
  overhead_week bigint;
  loose_week    bigint;
  hi_trail_m    bigint;
  hi_tier_m     bigint;
  hi_use_tiers  boolean;
  hi_cutover    date;
begin
  select coalesce(round(sum(amount) filter (where class = 'overhead')::numeric / 6)::bigint, 0),
         coalesce(round(sum(amount) filter (where class = 'payroll'
                        and account_name ilike 'Labor Cost:Payroll expenses')::numeric / 6)::bigint, 0),
         coalesce(round(sum(amount) filter (where class = 'payroll'
                        and account_name ilike '%health insurance%')::numeric / 6)::bigint, 0)
    into overhead_week, loose_week, hi_trail_m
  from v_cost_lines_classified
  where issued_on >= date_trunc('month', current_date) - interval '6 months'
    and issued_on <  date_trunc('month', current_date);
  overhead_week := round(overhead_week / 2.0);
  loose_week    := round(loose_week / 2.0);

  -- the other side of health_insurance_forecast_month, and the two `exists`
  -- guards that decide which side a month lands on. Constant over the run.
  hi_cutover := coalesce((select (value #>> '{}')::date from settings
                          where key = 'health_insurance_flat_rate_cutover'), '2026-11-01'::date);
  hi_use_tiers := exists (select 1 from health_insurance_tiers where monthly_cost > 0)
              and exists (select 1 from staff where health_insurance_tier is not null);
  select coalesce(sum(t.monthly_cost), 0)::bigint into hi_tier_m
  from staff s join health_insurance_tiers t on t.tier_key = s.health_insurance_tier
  where s.enrolled_health_insurance;
  -- 086: what counts as cash is now a class, not a QuickBooks account type,
  -- and lives in v_cash_accounts so this is the last function that has to know.
  select exists (select 1 from v_cash_accounts where is_operating)
    into operating_set;
  select coalesce(sum(balance), 0) into opening
  from v_cash_accounts
  where not operating_set or is_operating;

  return query
  -- calendar half-months: H1 = 1st..15th, H2 = 16th..month end, starting with the
  -- half that contains today, exactly `periods` of them
  with wk as (
    select h.w_start,
           case when extract(day from h.w_start) = 1
                then (h.w_start + interval '14 days')::date
                else (date_trunc('month', h.w_start) + interval '1 month' - interval '1 day')::date
           end as w_end
    from (
      select unnest(array[ m.m0, (m.m0 + interval '15 days')::date ]) as w_start
      from (select (date_trunc('month', current_date) + make_interval(months => g))::date as m0
            from generate_series(0, (periods / 2) + 1) g) m
    ) h
    where case when extract(day from h.w_start) = 1
               then (h.w_start + interval '14 days')::date
               else (date_trunc('month', h.w_start) + interval '1 month' - interval '1 day')::date
          end >= current_date
    order by h.w_start
    limit periods
  ),
  -- open AR, as before
  inflow as (
    select w.w_start,
      coalesce(sum(e.balance) filter (where e.expect_early  between w.w_start and w.w_end), 0)::bigint as early,
      coalesce(sum(e.balance) filter (where e.expect_median between w.w_start and w.w_end), 0)::bigint as expected,
      coalesce(sum(e.balance) filter (where e.expect_late   between w.w_start and w.w_end), 0)::bigint as late
    from wk w cross join v_open_invoice_expectations e
    group by w.w_start
  ),
  -- contracted: future deal months become expected invoices on the billing day,
  -- collected on the client's curve. Months already begun are excluded — their
  -- invoices either exist (open AR above) or are imminent and arrive next sync.
  contracted_src as (
    -- 087: what gets INVOICED, which is revenue plus the media an agency-funded
    -- search/social line rebills. pass_through left `billable` when it stopped
    -- being revenue; it never left the invoice, so it must not leave the cash.
    select (f.billable + f.pass_through) as billable,
      case f.billing_day
        when 'first' then f.month
        else (f.month + interval '1 month' - interval '1 day')::date
      end as invoice_on,
      coalesce(cb.p25_lag,  gb.p25_lag, 30)  as p25,
      coalesce(cb.median_lag, gb.median_lag, 35) as p50,
      coalesce(cb.p90_lag,  gb.p90_lag, 80)  as p90
    from v_deal_month_forecast f
    join clients c on c.id = f.client_id
    left join payment_behaviour cb on cb.scope = 'client' and cb.ref = c.qbo_customer_id
    left join payment_behaviour gb on gb.scope = 'global'
    where f.month > date_trunc('month', current_date)::date
      and f.billable + f.pass_through > 0
  ),
  contracted as (
    select w.w_start,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p25 between w.w_start and w.w_end), 0)::bigint as early,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p50 between w.w_start and w.w_end), 0)::bigint as expected,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p90 between w.w_start and w.w_end), 0)::bigint as late
    from wk w cross join contracted_src s
    group by w.w_start
  ),
  -- agency-funded media leaves on card mid-spend-month
  -- the cost contracted months imply (billable - gp), paid mid spend month —
  -- forecast programmatic media is cash leaving, same timing as agency media
  contracted_cogs as (
    -- due = last day of the spend month + the configured terms (Oct -> Oct 31 + 45d)
    -- 087: programmatic ONLY. 026 wrote this term for programmatic media and
    -- said so, but filtered on `billable > gp`, which also caught every
    -- agency-funded search/social month — whose media was ALSO leaving via
    -- agency_out below. That was the same budget subtracted from cash twice.
    select w.w_start,
      coalesce(sum(greatest(f.billable - f.gp, 0))
        filter (where ((f.month + interval '1 month' - interval '1 day')::date + cogs_due_days)
                between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join (select * from v_deal_month_forecast
                          where kind = 'programmatic'
                            and billable > gp
                            and month > date_trunc('month', current_date)::date) f
    group by w.w_start
  ),
  agency_out as (
    select w.w_start,
      coalesce(sum(f.agency_media_out)
        filter (where (f.month + 14) between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join (select * from v_deal_month_forecast
                          where agency_media_out > 0
                            and month >= date_trunc('month', current_date)::date) f
    group by w.w_start
  ),
  bills_due as (
    select w.w_start,
      coalesce(sum(b.balance) filter (where greatest(coalesce(b.due_on, current_date), current_date)
                                      between w.w_start and w.w_end), 0)::bigint as due
    from wk w cross join (select * from bills where balance > 0) b
    group by w.w_start
  ),
  -- base salary + statutory burden, on the existing semi-monthly cadence
  -- (15th, month-end) — half of THAT MONTH's bottoms-up total per run,
  -- not a flat GL-trailing-average disconnected from the Forecast chart.
  payroll_runs as (
    select d::date as pay_on, date_trunc('month', d)::date as month from (
      select (date_trunc('month', current_date) + make_interval(months => m) + interval '14 days') as d
      from generate_series(0, (periods / 2) + 2) m
      union all
      select (date_trunc('month', current_date) + make_interval(months => m + 1) - interval '1 day')
      from generate_series(0, (periods / 2) + 2) m
    ) x where d::date >= current_date
  ),
  -- 109: one burden-stack pass for the whole horizon. This was calling
  -- staff_base_labor_forecast_month() once per HALF-month period — twice per
  -- month, for the same month, and each call walked every active person.
  payroll_month_base as (
    select on_date as month, total
    from staff_base_labor_forecast_dates((select array_agg(distinct month) from payroll_runs))
  ),
  payroll_wk as (
    select w.w_start,
      coalesce((
        select round(b.total / 2.0)
        from payroll_runs p
        join payroll_month_base b on b.month = p.month
        where p.pay_on between w.w_start and w.w_end
        limit 1
      ), 0)::bigint as amt
    from wk w
  ),
  -- health insurance: one lump on the 1st of the month (H1 always starts on
  -- the 1st), never split
  health_wk as (
    select w.w_start,
      case when extract(day from w.w_start) = 1
           -- 109: health_insurance_forecast_month(w_start), with both sides
           -- and both guards resolved once above
           then (case when w.w_start >= hi_cutover and hi_use_tiers
                      then hi_tier_m else hi_trail_m end)
           else 0 end::bigint as amt
    from wk w
  ),
  -- each scheduled bonus on its own date — a bonus check happens once, it
  -- doesn't get smeared across the month like the flat categories
  -- 109: one staff_bonus_burdened_cost() per bonus, not per bonus per period
  bonus_cost as materialized (
    select id, pay_date, staff_bonus_burdened_cost(id) as cost from staff_bonuses
  ),
  bonus_wk as (
    select w.w_start,
      coalesce(sum(b.cost)
        filter (where b.pay_date between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join bonus_cost b
    group by w.w_start
  ),
  payroll_runs_out as (
    select pw.w_start, (coalesce(pw.amt,0) + loose_week + coalesce(hw.amt,0) + coalesce(bw.amt,0))::bigint as total
    from payroll_wk pw
    left join health_wk hw on hw.w_start = pw.w_start
    left join bonus_wk bw on bw.w_start = pw.w_start
  )
  select
    w.w_start,
    trim(to_char(w.w_start, 'Mon')) || ' H' ||
      (case when extract(day from w.w_start) = 1 then '1' else '2' end) ||
      ' ' || to_char(w.w_start, 'YY'),
    coalesce(i.early,0), coalesce(i.expected,0), coalesce(i.late,0),
    coalesce(ct.early,0), coalesce(ct.expected,0), coalesce(ct.late,0),
    coalesce(bd.due,0), coalesce(pr.total,0), overhead_week, coalesce(ao.amt,0), coalesce(cc.amt,0),
    (opening + sum(coalesce(i.early,0) + coalesce(ct.early,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.expected,0) + coalesce(ct.expected,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.late,0) + coalesce(ct.late,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint
  -- LEFT JOINs with coalesce: any of these CTEs is legitimately empty on a given
  -- day (no open AR, no future deal months, no unpaid bills), and an inner join
  -- would silently return no forecast at all — the worst possible failure shape.
  from wk w
  left join inflow i          on i.w_start  = w.w_start
  left join contracted ct     on ct.w_start = w.w_start
  left join bills_due bd      on bd.w_start = w.w_start
  left join payroll_runs_out pr on pr.w_start = w.w_start
  left join agency_out ao     on ao.w_start = w.w_start
  left join contracted_cogs cc on cc.w_start = w.w_start
  order by w.w_start;
end;
$$ language plpgsql stable;

comment on function cashflow_forecast(int) is
  'Half-month cash position (016/017/026/071/086/087). 109 is a speed-only '
  'rewrite: the three six-month trailing run-rates come from ONE scan of '
  'v_cost_lines_classified, the base payroll month comes from '
  'staff_base_labor_forecast_dates once for the horizon instead of once per '
  'HALF-month, health insurance resolves its two constant sides once, and each '
  'scheduled bonus is burdened once instead of once per period. '
  '109_fixture_test asserts every column of every period against 087.';

-- ---------------------------------------------------------------------------
--  8. line_fee — same answer, in a shape PostgreSQL can inline.
--
--     096 wrote it as a chain of CTEs. A SQL function whose body has a WITH
--     clause is never inlined into the calling query, so every row of
--     v_deal_month_forecast paid a full function call: ~38 µs, ~160 ms per
--     4,200 deal-months, and that view is read by forecast_page, three
--     separate scans inside cashflow_forecast, hours_page's deal_forecast,
--     Sales Forecast's whole-table fetch and every scope_months call.
--
--     Split in two. line_fee_bands keeps the band machinery (it needs a
--     subquery, so it stays a real call) and is reached only by a line that
--     actually has bands. line_fee itself is now one expression with no FROM
--     and no subquery, which PostgreSQL splices straight into the caller —
--     a flat line's fee becomes plain arithmetic in the view's target list.
--     Flat: 157 ms -> 2 ms per 4,227. Mixed (one line in four banded):
--     167 ms -> 19 ms.
--
--     Two things make this exactly the old answer, and the fixture pins both:
--       * GREATEST/LEAST in PostgreSQL IGNORE null arguments, so
--         greatest(fee, min) is 096's greatest(fee, coalesce(min, fee)) and
--         least(fee, cap) is its least(fee, coalesce(cap, fee)).
--       * an unrecognised fee mode still yields NULL, not a flat fee: 096's
--         CASE had no ELSE, and here the unknown mode falls through to
--         line_fee_bands, whose CASE has no ELSE either.
--     The JS twin (lineFee in app/assets/scope-math.js) is untouched: it was
--     already this shape, and scripts/test/scope-math.test.mjs still pins it
--     to 097_fixture_test's numbers.
-- ---------------------------------------------------------------------------
create or replace function line_fee_bands(p_budget bigint, p_structure jsonb)
returns numeric
language sql
immutable
as $$
  select case coalesce(coalesce(p_structure, '{}'::jsonb) #>> '{fee,mode}', 'flat')
    when 'marginal' then coalesce((
        select sum(greatest(least(coalesce(p_budget, 0), coalesce(x.upto, coalesce(p_budget, 0))) - x.lo, 0) * x.pct / 100)
        from (select (t.b ->> 'pct')::numeric                                       as pct,
                     nullif(t.b ->> 'upto', '')::bigint                             as upto,
                     coalesce(lag(nullif(t.b ->> 'upto', '')::bigint) over (order by t.ord), 0) as lo
              from jsonb_array_elements(case when jsonb_typeof(coalesce(p_structure, '{}'::jsonb) #> '{fee,bands}') = 'array'
                                             then coalesce(p_structure, '{}'::jsonb) #> '{fee,bands}'
                                             else '[]'::jsonb end)
                   with ordinality as t(b, ord)) x), 0)
    when 'whole' then coalesce((
        select coalesce(p_budget, 0) * x.pct / 100
        from (select (t.b ->> 'pct')::numeric                                       as pct,
                     nullif(t.b ->> 'upto', '')::bigint                             as upto,
                     coalesce(lag(nullif(t.b ->> 'upto', '')::bigint) over (order by t.ord), 0) as lo,
                     t.ord
              from jsonb_array_elements(case when jsonb_typeof(coalesce(p_structure, '{}'::jsonb) #> '{fee,bands}') = 'array'
                                             then coalesce(p_structure, '{}'::jsonb) #> '{fee,bands}'
                                             else '[]'::jsonb end)
                   with ordinality as t(b, ord)) x
        where coalesce(p_budget, 0) > x.lo and (x.upto is null or coalesce(p_budget, 0) <= x.upto)
        order by x.ord limit 1), 0)
  end;
$$;

comment on function line_fee_bands(bigint, jsonb) is
  'The banded half of line_fee (109): marginal = each month''s spend through '
  'every band it reaches, whole = the one band the whole spend falls in, '
  'boundary inclusive. Unknown mode -> null, as 096. Only a line that actually '
  'carries bands gets here; a flat line never calls it.';

create or replace function line_fee(p_budget bigint, p_fee_pct numeric, p_structure jsonb)
returns numeric
language sql
immutable
as $$
  select least(
    greatest(
      case when coalesce(p_structure #>> '{fee,mode}', 'flat') = 'flat'
           then coalesce(p_budget, 0) * coalesce(p_fee_pct, 0) / 100
           else line_fee_bands(p_budget, p_structure) end,
      nullif(p_structure ->> 'fee_min', '')::numeric),
    nullif(p_structure ->> 'fee_cap', '')::numeric);
$$;

comment on function line_fee(bigint, numeric, jsonb) is
  'The fee a media line earns on a month''s spend, UNROUNDED — flat '
  '(budget x pct / 100, byte-identical to 087''s inline arithmetic), or the '
  'bands in structure.fee, then fee_min, then fee_cap. ONE copy, twinned by '
  'lineFee in app/assets/scope-math.js. 109 reshaped the body so PostgreSQL '
  'inlines it into the caller (no WITH, no FROM, no subquery) and a flat line '
  'costs arithmetic rather than a function call; the answer is unchanged and '
  '109_fixture_test asserts it against 096''s body over both random and edge '
  'inputs.';

-- ---------------------------------------------------------------------------
--  9. staff_rates_months — 106's population and answer, from the cohort pass.
--     It asked the burden stack once per person-month: 50 people over 12
--     months is 600 walks, ~340 ms in the bed on a cold memo, and hours_page
--     pays exactly that for Team Hours' staff_rate_month. staff_rate_cache
--     (106) hid it for the volatile scoping entry points that fill the memo;
--     nothing else fills it, so every other caller paid full price. The memo
--     is still read first — it is by definition the same number — and now the
--     miss is cheap too.
-- ---------------------------------------------------------------------------
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
-- 109: one burden-stack call per (person, comp period, 401k, health-insurance)
-- cohort for the whole range, instead of one per person-month
cohort as (
  select c.staff_id, c.on_date as month, c.hourly_cost as rate
  from staff_cost_on_dates((select array_agg(month) from months)) c
),
people as (
  -- 106: the memo first; 109: the cohort pass, not the live per-month call,
  -- for a person-month the memo lacks
  select s.id as staff_id, s.department, m.month,
         case when c.staff_id is not null then c.rate else ch.rate end as rate
  from staff s cross join months m
  left join staff_rate_cache c on c.staff_id = s.id and c.month = m.month
  left join cohort ch on ch.staff_id = s.id and ch.month = m.month
  where s.active and s.tracks_capacity and not s.exclude_hours
    and (s.start_date is null or s.start_date <= m.month)
    and (s.end_date is null or s.end_date >= m.month)
)
select p.staff_id, p.department, p.month, p.rate,
       (select b.name from bands b where p.rate is not null and (b.upto_c is null or p.rate <= b.upto_c) order by b.ord limit 1) as band
from people p;
$$;

comment on function staff_rates_months(date, date) is
  'Every active tracks_capacity non-excluded person employed in each month of '
  'the range, with staff_hourly_cost(person, month) and the comp band that '
  'rate falls in. The population and semantics of band_rate() / staff_band(). '
  '106''s memo is still consulted first; 109 makes the miss one cohort pass '
  '(staff_cost_on_dates) instead of a burden-stack walk per person-month, so a '
  'cold memo is no longer slow either.';
