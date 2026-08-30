-- ============================================================================
--  069 — labor_forecast_month (068) is bottoms-up from Team setup: base pay
--  (salary/hourly * capacity), FICA/FUTA, workers' comp, SUTA, 401k match,
--  and SDI. Real payroll carries more than that, and none of it is modeled
--  per-person yet:
--
--    64000 Bonuses
--    63000 Commissions & fees
--    62004 Health insurance & accident plans
--    60001 Payroll expenses (loose/unattributed transactions)
--
--  Boris's call: add a flat trailing-6-month average of just these four
--  accounts' real GL cost on top of the bottoms-up figure, for every future
--  month, as a placeholder — same shape as cost_runrate_monthly (007), just
--  scoped to these accounts instead of a whole cost_class. Delete it once
--  each category has real per-person data to replace it with.
--
--  One interaction worth flagging: staff_annual_burdened_cost (052) already
--  has a health-insurance term (health_insurance_monthly_cost setting x
--  enrolled_health_insurance flag). Today that setting is unconfigured, so
--  the term is inert ($0) and this addendum is the only source of health
--  insurance cost in the forecast. If that setting is ever populated with a
--  real number, this addendum's health-insurance share would double-count it
--  — revisit this migration then, not later.
--
--  63000 Commissions & fees doesn't match the payroll-detection regex
--  (scripts/sync-qbo.mjs classifyAccount) or any existing override, so it has
--  been landing in 'overhead' — the same bug 056 fixed for Bonuses, Health
--  insurance, Contract labor, etc. Reclassifying it here, the same way, so
--  the actual/measured P&L split is correct too, not just the forecast.
-- ============================================================================

update qbo_accounts
set override_class = 'payroll',
    override_reason = 'Commissions & fees is a labor cost, not overhead — migration 069',
    override_by = 'migration:069',
    override_at = now()
where account_type in ('Expense', 'Other Expense')
  and name ilike '%commission%'
  and coalesce(override_class, derived_class) is distinct from 'payroll';

create or replace function labor_addendum_runrate(months int default 6)
returns bigint as $$
  select coalesce(round(sum(amount)::numeric / greatest(months, 1))::bigint, 0)
  from v_cost_lines_classified
  where class = 'payroll'
    and (
      account_name ilike '%bonus%'
      or account_name ilike '%commission%'
      or account_name ilike '%health insurance%'
      or account_name ilike '%payroll expenses%'
    )
    and issued_on >= date_trunc('month', current_date) - make_interval(months => months)
    and issued_on <  date_trunc('month', current_date);
$$ language sql stable;

comment on function labor_addendum_runrate is
  'Trailing average of real GL cost for the labor categories the bottoms-up '
  'Team-setup projection (068) does not model per-person: bonuses, '
  'commissions & fees, health insurance, and loose payroll-expense lines. A '
  'placeholder per Boris (2026-08-30) — delete each account''s share once it '
  'has real per-person data instead. class=''payroll'' is a belt-and-suspenders '
  'filter; the name match is what actually picks these four out.';

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
-- comp_periods don't cover, so no active/date filtering is needed here at all.
-- labor_addendum_runrate (069) adds the categories that per-person modeling
-- doesn't cover yet — flat across every future month, same as it is for the
-- real GL it is standing in for.
labor_forecast_month as (
  select gm.month::date as month,
         round(sum(coalesce(staff_annual_labor_cost(s.id, gm.month::date), 0))::numeric / 12)::bigint
           + labor_addendum_runrate() as total
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
  'bottoms-up Labour projection for the chart''s future months, plus '
  'labor_addendum_runrate (069) for bonuses/commissions/health insurance/loose '
  'payroll — see that function''s comment for what it does and does not cover.';
