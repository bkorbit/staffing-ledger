-- ============================================================================
--  068 — forecast_page gains labor_forecast_month: a bottoms-up projection of
--  future Labour cost sourced from Team setup (comp_periods burdened rate +
--  PEO fee, via staff_annual_labor_cost — the same function that feeds Team's
--  Total Cost column), instead of the flat trailing-6-month GL average.
--
--  Deliberately in scope: current active roster only, projected forward one
--  month at a time. Because staff_annual_labor_cost resolves "which
--  comp_period covers this month" the same way hours_page()/Team already do,
--  a known future change already entered in Team — a scheduled departure
--  (comp_periods.ends_on), a new hire (comp_periods.starts_on in the future),
--  a raise (a new comp_period row starting later) — is honored automatically:
--  a staff row simply contributes $0 for any month outside its comp_periods
--  coverage, no separate active-flag filtering needed.
--
--  Deliberately OUT of scope (Boris, 2026-08-30): bonuses, severance, and
--  commissions. None of those are modeled by a comp_period rate, so this
--  projection will run below actual GL payroll by however much of that the
--  company pays out — accepted for now, revisit once there's a way to plan
--  for them.
--
--  Deliberately UNCHANGED: cost_runrate_monthly('payroll') and its callers
--  (Cashflow's half-month payroll_month projection). This migration only
--  changes what feeds the Forecast chart's Labour bar for future months —
--  Cashflow keeps using the flat GL trailing average, matching Boris's
--  explicit scope decision to touch only the Forecast chart.
-- ============================================================================

create or replace function forecast_page(p_from date, p_to date)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
plan as (
  select deal_id, month, gp, billable from v_deal_month_forecast
  where month between p_from and p_to
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on::timestamp)::date between p_from and p_to
),
cost as (
  select month, class, qbo_project_id, account_name, amount
  from v_cost_lines_classified
  where month between p_from and p_to
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
-- one row per future month (from "now" through p_to, clamped to p_from..p_to),
-- crossed with every staff row — a staff row contributes $0 for a month its
-- comp_periods don't cover, so no active/date filtering is needed here at all
labor_forecast_month as (
  select gm.month::date as month,
         round(sum(coalesce(staff_annual_labor_cost(s.id, gm.month::date), 0))::numeric / 12)::bigint as total
  from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
  cross join staff s
  group by gm.month
)
select jsonb_build_object(
  'plan_month', coalesce((select jsonb_agg(t) from (
      select month, sum(gp)::bigint as gp, sum(billable)::bigint as billable
      from plan group by month) t), '[]'::jsonb),
  'plan_deal', coalesce((select jsonb_agg(t) from (
      select deal_id,
        sum(gp)::bigint as gp_all,
        coalesce(sum(gp) filter (where month < (select m from cur)), 0)::bigint as gp_settled,
        coalesce(sum(billable) filter (where month >= (select m from cur)), 0)::bigint as bill_future
      from plan group by deal_id) t), '[]'::jsonb),
  'rev_month', coalesce((select jsonb_agg(t) from (
      select month, sum(total)::bigint as total from (
        select month, total from inv
        union all
        -- contra-revenue: debits to income-type accounts (search/social media
        -- pass-through offsets) net against invoiced revenue, as QuickBooks does
        select month, -amount as total from cost where class = 'income'
      ) u group by month) t), '[]'::jsonb),
  'rev_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(total)::bigint as total from (
        select qbo_project_id, month, total from inv
        union all
        select qbo_project_id, month, -amount from cost
        where class = 'income' and qbo_project_id is not null
      ) u where month <= (select m from cur) and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'cost_month', coalesce((select jsonb_agg(t) from (
      select month, class, sum(amount)::bigint as total from cost group by month, class) t), '[]'::jsonb),
  'cogs_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(amount)::bigint as total
      from cost where class = 'cogs' and month <= (select m from cur)
        and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(t) from (
      select class, coalesce(account_name, '(no account)') as account,
             sum(amount)::bigint as total
      from cost group by class, account_name) t), '[]'::jsonb),
  'runrates', jsonb_build_object(
      'payroll',  cost_runrate_monthly('payroll'),
      'overhead', cost_runrate_monthly('overhead'),
      'other',    cost_runrate_monthly('other')),
  'labor_forecast_month', coalesce((select jsonb_agg(t) from labor_forecast_month t), '[]'::jsonb),
  'projects', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'parent_id', parent_id, 'jobcode', jobcode))
      from keep_projects), '[]'::jsonb)
);
$$ language sql stable;

comment on function forecast_page is
  'The Forecast page''s data, grouped where it lives: one jsonb, one round trip. '
  'Projects are trimmed to the ones the page shows; the editor''s full picker list '
  'loads lazily. inv (055) uses an explicit ::timestamp cast so it matches '
  'invoices_month_idx (053). labor_forecast_month (068) is the Team-setup-sourced '
  'bottoms-up Labour projection for the chart''s future months — see that CTE''s '
  'comment for what it does and does not account for.';
