-- ============================================================================
--  090 — two fixes to the detail RPCs (088/089), from the first look at real
--  clients on Client Profitability:
--
--  1. A CLOSED MONTH WITH NOTHING INVOICED IS MEASURED $0, NOT UNKNOWN.
--     088/089 left-joined the month list to `actual`, so a closed month
--     inside the flight with no invoices and no bills came back with
--     rev_actual / gp_actual NULL — the same NULL that means "not measured
--     yet" from the current month on. The chart broke its actual line across
--     any gap. Now every month before the current one carries 0 when nothing
--     happened; NULL is reserved for months not yet closed. The plan side
--     already behaved this way (a month with no plan is 0).
--
--  2. HOURS PER WEEK PER DEAL, for the client chart. Boris wants the client's
--     hours stacked by PROJECT, not department ("which project is eating the
--     hours"). client_detail gains `weeks_by_deal` [{week, deal_id, hours}]
--     and `deals` [{id, name, flight_start, flight_end}] so the chart can
--     name and order its series (by flight start — a stable, meaningful
--     order; never by rank, so a project keeps its colour). `weeks` (by
--     department) stays: Project Hours' own chart still stacks a single
--     project by department, and both are cheap.
--
--  Same bodies as 088/089 otherwise — read those headers for the reasoning
--  behind each CTE. 090_fixture_test asserts the zeros and the new arrays,
--  and 088/089_fixture_test still pass against these definitions.
-- ============================================================================

create or replace function project_detail(p_deal_id uuid)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
d as (
  select id, name, client_id, qbo_project_id, flight_start, flight_end
  from deals where id = p_deal_id
),
te as (
  select t.worked_on, t.hours,
         coalesce(s.department, t.department, '(no department)') as department
  from time_entries t
  left join staff s on s.id = t.staff_id
  where t.deal_id = p_deal_id
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
         case when m.month < (select m from cur) then coalesce(a.rev_actual, 0) end  as rev_actual,
         case when m.month < (select m from cur) then coalesce(a.cogs_actual, 0) end as cogs_actual
  from months m
  left join actual a on a.month = m.month
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
  'as-opened value for past months. Per-person hours are NOT here: '
  'hours_page''s staff_hours_deal / staff_deal_planned already carry them.';

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
  select t.deal_id, t.worked_on, t.hours,
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
weeks_by_deal as (
  select date_trunc('week', worked_on)::date as week, deal_id,
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
),
measured as (
  select m.month,
         case when m.month < (select m from cur) then coalesce(a.rev_actual, 0) end  as rev_actual,
         case when m.month < (select m from cur) then coalesce(a.cogs_actual, 0) end as cogs_actual
  from months m
  left join actual a on a.month = m.month
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
  'orders the series.';
