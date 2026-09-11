-- ============================================================================
--  094 — the detail charts get "profit after labor" per month.
--
--  Project Hours and Client Profitability already carry a Profit after labor
--  column (gross profit − hours-based labor cost, hours_page's deal_labor).
--  The opened row's "Revenue & gross profit" chart could not draw it: the
--  detail RPCs (088-091) had hours per week but no cost. Both now price the
--  SAME time entries they already count, the SAME way hours_page does
--  (staff_hourly_cost per distinct staff/day, MATERIALIZED — 061/062), and
--  add two fields to every month row:
--
--    labor_actual  hours × rate summed over the month; 0 for a closed month
--                  with no hours; null while the month is still running
--    pal_actual    gp_actual − labor_actual, same nullness
--
--  A month that has hours but no invoice, no plan and no flight coverage now
--  gets a row too, so a project that only burned time shows the loss rather
--  than a blank. Everything else — weeks, revenue, COGS, GP, plan — is 091's,
--  unchanged. 094_fixture_test asserts the cents against staff_hourly_cost
--  and against hours_page's deal_labor for the same deal and range; the
--  one-cent-per-month rounding a per-month sum can add over a whole-range
--  sum is below what either page displays.
--
--  Not added: a plan twin. assignments carry hours, not cost (034/035), so
--  there is no planned labor to subtract from gp_plan — the chart draws
--  profit after labor as a measured line only.
-- ============================================================================

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
-- prices them — one staff_hourly_cost() per distinct staff/day, MATERIALIZED
-- so the planner cannot re-evaluate it per row (061/062). A row with no
-- staff (unknown_user) has hours but no rate, and drops out of the cost here
-- as it does from hours_page's deal_labor.
staff_days as (
  select distinct staff_id, worked_on from te where staff_id is not null
),
day_rates as materialized (
  select staff_id, worked_on, staff_hourly_cost(staff_id, worked_on) as rate
  from staff_days
),
labor as (
  select date_trunc('month', te.worked_on)::date as month,
         sum(te.hours * dr.rate)::bigint as labor
  from te
  join day_rates dr on dr.staff_id = te.staff_id and dr.worked_on = te.worked_on
  group by 1
),
plan as (
  select month, sum(billable)::bigint as rev_plan, sum(gp)::bigint as gp_plan
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
      'gp_plan',     p.gp_plan)
      order by m.month)
      from measured m
      left join plan p on p.month = m.month), '[]'::jsonb)
);
$$ language sql stable;

comment on function project_detail is
  'One opened project on the Project Hours page: hours per ISO week per '
  'department (staff.department first, the entry''s own QB Time department '
  'only as a fallback), and the project''s revenue / gross profit per month, '
  'actual vs plan. The actual side restates forecast_page''s rev_proj and '
  'cogs_proj per month for one project — same CTE shapes, same 080 fail-open '
  'rules — and 088_fixture_test asserts the two agree to the cent. Every month '
  'before the current one is measured (0 when nothing happened, 090); null is '
  'reserved for months not yet closed. The plan side is v_deal_month_forecast''s '
  'billable and gp per month, which freeze-on-close already holds at the '
  'as-opened value for past months. 094: labor_actual (the same hours priced '
  'as hours_page prices them) and pal_actual (gp − labor) per closed month; a '
  'month with hours and no money still gets a row. Per-person hours are NOT '
  'here: hours_page''s staff_hours_deal / staff_deal_planned already carry them.';

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
-- prices them — one staff_hourly_cost() per distinct staff/day, MATERIALIZED
-- so the planner cannot re-evaluate it per row (061/062). A row with no
-- staff (unknown_user) has hours but no rate, and drops out of the cost here
-- as it does from hours_page's deal_labor.
staff_days as (
  select distinct staff_id, worked_on from te where staff_id is not null
),
day_rates as materialized (
  select staff_id, worked_on, staff_hourly_cost(staff_id, worked_on) as rate
  from staff_days
),
labor as (
  select date_trunc('month', te.worked_on)::date as month,
         sum(te.hours * dr.rate)::bigint as labor
  from te
  join day_rates dr on dr.staff_id = te.staff_id and dr.worked_on = te.worked_on
  group by 1
),
plan as (
  select month, sum(billable)::bigint as rev_plan, sum(gp)::bigint as gp_plan
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
      'gp_plan',     p.gp_plan)
      order by m.month)
      from measured m
      left join plan p on p.month = m.month), '[]'::jsonb)
);
$$ language sql stable;

comment on function client_detail is
  'An opened client on Client Profitability: project_detail (088) unioned '
  'across every deal of the client. Hours per ISO week per department AND per '
  'deal (weeks_by_deal, 090 — the client chart stacks by project) over all the '
  'client''s deals; revenue / gross profit actual vs plan per month, summed — '
  'actuals over the DISTINCT set of QB projects the deals claim, same '
  'forecast_page arithmetic. Every month before the current one is measured '
  '(0 when nothing happened, 090); null is reserved for months not yet closed. '
  'The unclaimed remainder on the client''s QB parent is deliberately excluded, '
  'matching the page''s client total (089_fixture_test asserts it). engagement '
  'is min flight_start / max flight_end, the chart''s window; deals names and '
  'orders the series. 091: counts exactly the rows hours_page counts '
  '(attribution not excluded / timeoff). 094: labor_actual and pal_actual per '
  'closed month across all the client''s deals, priced as hours_page prices them.';
