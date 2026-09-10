-- ============================================================================
--  092 — the in-progress month is never a partial actual: rev_proj and
--  cogs_proj count CLOSED months only.
--
--  Found 10 Sep 2026 on "Disney Visa - Retention", Forecast range Sep→Sep:
--  Value showed $150,550 for a $70,000/month retainer. forecast_page's
--  rev_proj kept invoice months `<= current month` and plan_deal.bill_future
--  kept plan months `>= current month` — both inclusive — so September was
--  in both: the $70,000 retainer invoice issued 1 Sep ($80,550 with the
--  creative-services invoices on the same project) PLUS the $70,000 September
--  plan. forecast.html adds the two (Value = billed + forecast), and the
--  current month was counted twice. cogs_proj had the same `<=`, so GP Billed
--  carried this month's costs against last month's revenue.
--
--  The platform rule (CLAUDE.md, "Measured = month fully over") already says
--  the in-progress month runs entirely on forecast — the chart and company
--  rows do exactly that. This migration makes the per-project actuals obey
--  the same rule. Boris, 10 Sep 2026: "if a month isn't fully completed it
--  should not count the invoices at all."
--
--  What changes — three comparisons, `<=` → `<` against date_trunc('month',
--  current_date):
--    forecast_page  rev_proj   (per-project measured revenue)
--    forecast_page  cogs_proj  (per-project measured COGS)
--    rev_proj_page  (051's literal copy of rev_proj — lockstep by hand)
--
--  What does NOT change:
--    rev_month / cost_month — company-wide by month; the chart already reads
--      them only for measured months (forecast.html `measured ?`), and the
--      P&L reconciliation scripts read the current month on purpose.
--    plan_deal — gp_settled was already strict (`< cur`); bill_future stays
--      `>= cur`. With rev_proj now strict the two meet at the month boundary
--      without overlap: Value = billed through last month + planned from this
--      month on.
--    project_detail / client_detail (088-091) — already null for the current
--      month ("not yet closed"), so they agreed with this rule before it.
--
--  Both bodies below are 080's, verbatim, except the three lines marked
--  "-- 092" and the two comments. 092_fixture_test.sql proves the boundary
--  with two current-month invoices, a current-month contra line and a
--  current-month COGS bill on one project, all of which must vanish from the
--  per-project figures while rev_month still moves by exactly their sum.
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
  select month, class, qbo_project_id, account_name, amount, issued_on
  from v_cost_lines_classified
  where month between (select lo from bounds) and (select hi from bounds)
),
cost as (
  select month, class, qbo_project_id, account_name, amount
  from cost_all
  where month between p_from and p_to
),
-- same rows cost_runrate_monthly/payroll_loose_runrate/health_insurance_
-- forecast_month's trailing branch would each independently re-select.
cost_trail as (
  select class, account_name, amount
  from cost_all
  where issued_on >= (select m from cur) - interval '6 months'
    and issued_on <  (select m from cur)
),
-- matches cost_runrate_monthly(class, 6) for the 3 classes forecast_page uses
runrate_trail as (
  select class, coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class in ('payroll', 'overhead', 'other')
  group by class
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
labor_forecast_month as (
  select gm.month::date as month,
         staff_base_labor_forecast_month(gm.month::date)
           + (select total from loose_payroll_trail)
           + (case when gm.month::date >= (select d from health_cutover)
                   then (select total from health_tier_sum)
                   else (select total from health_ins_trail) end)
           + coalesce((select total from bonus_forecast bf where bf.month = gm.month::date), 0) as total
  from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
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
        -- balance-sheet invoice lines (customer deposits / pre-payments) are
        -- not income in QuickBooks and are not revenue here either (080)
        select month, -amount as total from nonrev
        union all
        -- contra-revenue: debits to income-type accounts (search/social media
        -- pass-through offsets) net against invoiced revenue, as QuickBooks does
        select month, -amount as total from cost where class = 'income'
      ) u group by month) t), '[]'::jsonb),
  'rev_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(total)::bigint as total from (
        select qbo_project_id, month, total from inv
        union all
        select qbo_project_id, month, -amount from nonrev
        where qbo_project_id is not null
        union all
        select qbo_project_id, month, -amount from cost
        where class = 'income' and qbo_project_id is not null
      ) u where month < (select m from cur) and qbo_project_id is not null   -- 092: closed months only
      group by qbo_project_id) t), '[]'::jsonb),
  'cost_month', coalesce((select jsonb_agg(t) from (
      select month, class, sum(amount)::bigint as total from cost group by month, class) t), '[]'::jsonb),
  'cogs_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(amount)::bigint as total
      from cost where class = 'cogs' and month < (select m from cur)   -- 092: closed months only
        and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(t) from (
      select class, coalesce(account_name, '(no account)') as account,
             sum(amount)::bigint as total
      from cost group by class, account_name) t), '[]'::jsonb),
  'runrates', jsonb_build_object(
      'payroll',  coalesce((select total from runrate_trail where class = 'payroll'), 0),
      'overhead', coalesce((select total from runrate_trail where class = 'overhead'), 0),
      'other',    coalesce((select total from runrate_trail where class = 'other'), 0)),
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
  'invoices_month_idx (053). v_cost_lines_classified is scanned exactly once, via '
  'cost_all (076) — display cost, the 3 runrates, loose-payroll, and the pre-cutover '
  'health-insurance average all read from that single scan instead of independently '
  're-querying the view. Measured revenue is the invoice total minus balance-sheet '
  'invoice lines (080, customer deposits and pre-payments — QuickBooks keeps them out '
  'of Total Income) minus contra revenue (025), which makes it the same quantity the '
  'QuickBooks P&L calls Total Income. rev_proj and cogs_proj count CLOSED months only '
  '(092): the in-progress month is forecast, never a partial actual, so a deal''s Value '
  'on the Forecast table is billed-through-last-month + planned-from-this-month, and '
  'nothing is counted twice. rev_month still carries the current month (the chart '
  'reads it only for measured months). labor_forecast_month is bottoms-up Team-setup '
  'Labour for the chart''s future months: staff_base_labor_forecast_month (071/073/075, '
  'per-person base pay + statutory burden, active-only) + the loose-payroll trailing '
  'average (074''s exact-match filter) + health insurance (date-branched: trailing '
  'average pre-cutover, per-tier sum post-cutover) + bonus_forecast (070, scheduled '
  'bonuses, employer-burdened, in the month each is actually due).';

-- rev_proj_page (051/055): the same subtraction, kept a literal copy of
-- forecast_page's rev_proj by hand, for the reason 051 gives.
create or replace function rev_proj_page(p_from date, p_to date)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on::timestamp)::date between p_from and p_to
),
nonrev as (
  select month, qbo_project_id, amount
  from v_invoice_lines_classified
  where month between p_from and p_to
    and account_id is not null
    and not unjoined
    and class is not null
    and class <> 'income'
),
cost as (
  select month, class, qbo_project_id, amount
  from v_cost_lines_classified
  where month between p_from and p_to
)
select coalesce((select jsonb_agg(t) from (
    select qbo_project_id, sum(total)::bigint as total from (
      select qbo_project_id, month, total from inv
      union all
      -- balance-sheet invoice lines, same as forecast_page's rev_proj (080)
      select qbo_project_id, month, -amount from nonrev
      where qbo_project_id is not null
      union all
      -- contra-revenue: debits to income-type accounts (search/social media
      -- pass-through offsets) net against invoiced revenue, same as
      -- forecast_page's rev_proj (025).
      select qbo_project_id, month, -amount from cost
      where class = 'income' and qbo_project_id is not null
    ) u where month < (select m from cur) and qbo_project_id is not null   -- 092: closed months only
    group by qbo_project_id) t), '[]'::jsonb);
$$ language sql stable;

comment on function rev_proj_page is
  'Just forecast_page()''s rev_proj (025/080), for pages that only need '
  'revenue-per-project and would otherwise pay for the whole Forecast '
  'page''s computation on every load — including three cost_runrate_monthly() '
  'scans that are independent of p_from/p_to and get recomputed for a value '
  'the page never uses. Team Hours (051) is the first caller. Keep this in '
  'lockstep with forecast_page''s own rev_proj by hand, since it is a literal '
  'copy, not a shared call. inv (055) uses an explicit ::timestamp cast so it '
  'matches invoices_month_idx (053). Balance-sheet invoice lines are subtracted '
  'as of 080. Closed months only since 092 — the in-progress month is excluded, exactly '
  'as forecast_page''s rev_proj excludes it.';
