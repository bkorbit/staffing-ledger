-- ============================================================================
--  088 — project_detail: what the Project Hours page shows when a project row
--  opens. One jsonb, one round trip, fetched lazily per opened deal.
--
--  Three things the page could not get from hours_page/forecast_page:
--
--    weeks   — hours logged per ISO week (Monday) per department, for every
--              time entry on this deal. Department is the person's CURRENT
--              staff.department (the same field Team Hours filters on), and
--              only when they have none does the entry's own QB Time
--              department stand in. Not clipped to the flight or to the
--              page's range: an hour logged before the flight opened is a
--              real hour on this project and the chart should show it.
--    months  — the project's revenue and gross profit, actual vs plan, per
--              month. The ACTUAL side is forecast_page's own rev_proj /
--              cogs_proj arithmetic restated per month for one project:
--              invoice totals minus balance-sheet invoice lines (080) minus
--              income-class cost lines (025 contra) is revenue; cogs-class
--              cost lines are COGS; GP is the difference. It is deliberately
--              the same three CTE shapes with the same fail-open conditions,
--              and 088_fixture_test asserts digit-for-digit agreement with
--              forecast_page's rev_proj/cogs_proj for the same project and
--              range — the rule is that no two pages disagree about revenue.
--              Actuals stop at the last month that is fully over (CLAUDE.md:
--              measured = month fully over; the in-progress month never
--              masquerades as measured), so rev_actual/gp_actual are NULL
--              from the current month on and the chart's actual line simply
--              ends. The PLAN side is v_deal_month_forecast summed per month
--              — billable for revenue (087: pass_through is cash, never
--              revenue) and gp — which for closed months is already the
--              as-opened figure (freeze-on-close), so past months read as
--              genuine forecast accuracy without any snapshot machinery.
--              The month list is the flight's months ∪ any month carrying a
--              plan or an actual, so an invoice outside the flight is shown
--              rather than hidden.
--    deal    — the deal row itself (name, flight, claimed QB project), so
--              the client can draw the axis and the "no QB project" state
--              without a second lookup.
--
--  What is NOT here, on purpose: the people breakdown. hours_page already
--  returns staff_hours_deal and staff_deal_planned for the page's range, and
--  the page renders those — a second copy of per-person hours here would be
--  one more thing that could drift from Team Hours.
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
-- the same three shapes forecast_page/rev_proj_page use (055 ::timestamp cast
-- for the index; 080's fail-open nonrev conditions), for this one project
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
)
select jsonb_build_object(
  'deal', (select to_jsonb(d) from d),
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

comment on function project_detail is
  'One opened project on the Project Hours page: hours per ISO week per '
  'department (staff.department first, the entry''s own QB Time department '
  'only as a fallback), and the project''s revenue / gross profit per month, '
  'actual vs plan. The actual side restates forecast_page''s rev_proj and '
  'cogs_proj per month for one project — same CTE shapes, same 080 fail-open '
  'rules — and 088_fixture_test asserts the two agree to the cent; it stops at '
  'the last fully-closed month (null from the current month on). The plan side '
  'is v_deal_month_forecast''s billable and gp per month, which freeze-on-close '
  'already holds at the as-opened value for past months. Per-person hours are '
  'NOT here: hours_page''s staff_hours_deal / staff_deal_planned already carry '
  'them for the page''s range.';
