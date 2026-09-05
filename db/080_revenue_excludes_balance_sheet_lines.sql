-- ============================================================================
--  080 — measured revenue stops counting invoice lines that post to the
--  balance sheet, so it means what QuickBooks' P&L means by Total Income.
--
--  079 has the full reconciliation and the reasoning; this migration is the
--  math. Both forecast_page's rev_month/rev_proj and rev_proj_page's literal
--  copy of rev_proj gain the same subtraction, and the two stay in lockstep
--  by hand exactly as 051 requires.
--
--  The shape of the change, in one line:
--
--    revenue = invoices.total
--            - invoice lines resolved to a NON-income account   (080, new)
--            - cost lines hitting an income account             (025, contra)
--
--  Note what it does NOT do: it does not switch the base from invoices.total
--  to a sum of invoice lines. Only SalesItemLineDetail lines are stored (001),
--  so a sum-of-lines base would silently drop sales tax and any line type the
--  sync does not keep. Subtracting from the document total instead changes
--  exactly the dollars we mean to change and leaves every other dollar where
--  it was.
--
--  Every branch of the resolution fails OPEN — a line is only subtracted when
--  we positively resolved its account AND that account has a class AND the
--  class is not 'income'. A line the sync has not stamped yet (account_id
--  null, the pre-backfill state of every existing row), one whose account
--  matched nothing (unjoined), or one whose account carries no class at all
--  is counted as revenue, exactly as it is today. Failing closed here would
--  silently delete revenue — the same shape as the credit-memo bug where
--  salesCostRow drops a line whose item has no income account.
--
--  Because null means "revenue, as before", 080 is a no-op against the
--  current data and only takes effect once a full QBO re-sync has stamped
--  the accounts. Run 079 and 080 together, re-sync, then re-check August.
--
--  Not touched, deliberately: cashflow_forecast (071) collects against
--  invoices.balance. A deposit invoice is real cash arriving on a real due
--  date — it is not revenue, but it very much is collection, and netting it
--  out of the cash curve would be a second, opposite bug.
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
  'QuickBooks P&L calls Total Income. labor_forecast_month is bottoms-up Team-setup '
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
    ) u where month <= (select m from cur) and qbo_project_id is not null
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
  'as of 080.';
