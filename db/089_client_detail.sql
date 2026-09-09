-- ============================================================================
--  089 — client_detail: the two reports at the bottom of an opened client on
--  Client Profitability. project_detail (088) for ONE deal, unioned across
--  every deal that belongs to the client, so the charts sum to the client row
--  above them.
--
--    weeks   — hours per ISO week per department across all the client's
--              deals (time entries keyed by deal_id, exactly as the table's
--              hours are — an entry carrying the client but no deal is not in
--              the table's total and is not here either).
--    months  — revenue and gross profit, actual vs plan, per month, summed.
--              Actual = the SAME arithmetic as 088/forecast_page, over the
--              set of QB projects the client's deals claim (distinct, so two
--              deals claiming one project never double-count it). Plan =
--              v_deal_month_forecast billable/gp summed over the deals.
--              The UNCLAIMED remainder — money on the client's QB parent that
--              no deal claims — is deliberately NOT here, for the reason
--              Client Profitability keeps it out of the client total: every
--              other figure is per-deal and a remainder has no deal to belong
--              to. The page shows it as its own row; the chart matches the
--              row above it, to the cent, and 089_fixture_test asserts that.
--    engagement — min flight_start / max flight_end across the deals, the
--              chart's window.
--
--  Same fail-open rules as 080 on the nonrev side; actuals stop at the last
--  fully-closed month (null from the current month on).
-- ============================================================================

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
  select t.worked_on, t.hours,
         coalesce(s.department, t.department, '(no department)') as department
  from time_entries t
  left join staff s on s.id = t.staff_id
  where t.deal_id in (select id from d)
),
weeks as (
  select date_trunc('week', worked_on)::date as week, department,
         sum(hours)::numeric as hours
  from te
  group by 1, 2
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
  select gs.month::date
  from engagement e
  cross join lateral generate_series(
    date_trunc('month', e.flight_start),
    date_trunc('month', e.flight_end),
    interval '1 month') gs(month)
  where e.flight_start is not null and e.flight_end is not null
)
select jsonb_build_object(
  'client_id', p_client_id,
  'deal_ids', coalesce((select jsonb_agg(id) from d), '[]'::jsonb),
  'engagement', (select to_jsonb(e) from engagement e),
  'measured_through', (select (m - interval '1 month')::date from cur),
  'weeks', coalesce((select jsonb_agg(jsonb_build_object(
      'week', w.week, 'department', w.department, 'hours', w.hours)
      order by w.week, w.department) from weeks w), '[]'::jsonb),
  'months', coalesce((select jsonb_agg(jsonb_build_object(
      'month',       m.month,
      'rev_actual',  a.rev_actual,
      'cogs_actual', a.cogs_actual,
      'gp_actual',   case when a.rev_actual is null then null
                          else a.rev_actual - a.cogs_actual end,
      'rev_plan',    p.rev_plan,
      'gp_plan',     p.gp_plan)
      order by m.month)
      from months m
      left join actual a on a.month = m.month
      left join plan   p on p.month = m.month), '[]'::jsonb)
);
$$ language sql stable;

comment on function client_detail is
  'An opened client on Client Profitability: project_detail (088) unioned '
  'across every deal of the client. Hours per ISO week per department over '
  'all the client''s deals; revenue / gross profit actual vs plan per month, '
  'summed — actuals over the DISTINCT set of QB projects the deals claim, '
  'same forecast_page arithmetic, stopping at the last fully-closed month. '
  'The unclaimed remainder on the client''s QB parent is deliberately '
  'excluded, matching the page''s client total (089_fixture_test asserts it). '
  'engagement is min flight_start / max flight_end, the chart''s window.';
