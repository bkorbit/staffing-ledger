-- ============================================================================
--  093 — two changes to the Forecast chart, both Boris's call (10 Sep 2026):
--
--  1. 'Other' is no longer forecast. The class holds lines on accounts with
--     no recognisable type — in practice one-off / incremental items, not a
--     recurring cost. Averaging the last six months forward invented a
--     monthly charge that never recurs. Measured months still show what was
--     actually booked there; forward months carry zero. forecast_page drops
--     runrates.other, and both charts (Forecast, Home) stop reading it.
--
--  2. The NET line can show EBITDA instead of net. EBITDA here is net with
--     the "add-back" lines put back: everything QuickBooks books below the
--     operating line (account_type 'Other Expense' / 'Other Income'), plus
--     depreciation, amortization, interest and income tax wherever they sit.
--     Which accounts count is a per-account flag on the chart of accounts,
--     derived by rule and overridable by hand — the same shape as
--     override_class, edited in the same "How costs are counted" panel.
--
--       qbo_accounts.ebitda_addback   null = follow the rule; true/false = a
--                                     human's answer, never written by the sync
--       account_ebitda_addback(...)   the rule, ONE copy, used by both views
--       v_account_class               + ebitda_addback (override),
--                                     ebitda_addback_auto (the rule's answer),
--                                     ebitda_addback_effective
--       v_cost_lines_classified       + account_type, account_sub_type,
--                                     ebitda_addback (effective) per line
--       forecast_page                 + addback_month (per measured month),
--                                     runrates.addback (forward months);
--                                     − runrates.other
--
--     The rule only fires for classes overhead/other. A payroll-class account
--     that QuickBooks happens to type Other Expense (056's severance /
--     bonus reclassification) is labour, and labour is never an EBITDA
--     add-back by default. COGS likewise. A human override still wins.
--
--     Forward months: the overhead run-rate is a trailing average of real
--     lines, so its add-back is the trailing average of the flagged lines
--     inside it (addback_trail). Labour (Team setup), COGS (plan) and other
--     (not forecast) contain no such lines, so nothing else is added back
--     forward. EBITDA month = net month + addback (both sides, measured and
--     forecast). The client twin is rowFor() in app/forecast.html.
--
--  Column order matters for `create or replace view`: every new column is
--  appended after the existing ones, nothing is renamed or moved.
-- ============================================================================

alter table qbo_accounts add column if not exists ebitda_addback        boolean;
alter table qbo_accounts add column if not exists ebitda_addback_reason text;
alter table qbo_accounts add column if not exists ebitda_addback_by     text;
alter table qbo_accounts add column if not exists ebitda_addback_at     timestamptz;

comment on column qbo_accounts.ebitda_addback is
  'EBITDA add-back. null = follow account_ebitda_addback()''s rule (below-the-line '
  'types, depreciation / amortization / interest / income tax by subtype or name, '
  'overhead and other classes only); true / false = a human''s answer. Human-owned: '
  'the sync never writes it.';

-- The rule. One copy; both views call it. immutable so a view over it stays
-- cheap and an expression index would be possible later.
create or replace function account_ebitda_addback(
  p_type text, p_sub_type text, p_name text, p_class cost_class, p_override boolean)
returns boolean language sql immutable as $$
  select coalesce(p_override,
    -- a class-less account is 'other' to v_cost_lines_classified, so it is here too
    coalesce(p_class, 'other'::cost_class) in ('overhead', 'other')
    and (
      coalesce(p_type, '') in ('Other Expense', 'Other Income')
      or coalesce(p_sub_type, '') in ('Depreciation', 'Amortization', 'InterestPaid',
                                      'InterestEarned', 'IncomeTaxExpense')
      or coalesce(p_name, '') ~* '\m(depreciation|amortization|amortisation)\M'
      or coalesce(p_name, '') ~* '\minterest\M'
      or coalesce(p_name, '') ~* '\m(income|franchise) tax'
    ),
    false);
$$;

comment on function account_ebitda_addback is
  'Is a cost line on this account an EBITDA add-back? Override wins when set. '
  'Otherwise: only overhead / other classes, and only accounts QuickBooks types '
  'Other Expense / Other Income (below the operating line) or that carry a '
  'depreciation / amortization / interest / income-tax subtype or name. \m \M are '
  'word boundaries — "Pinterest" is not interest.';

-- v_account_class (005): three columns appended.
create or replace view v_account_class as
select id, name, fully_qualified_name, account_type, account_sub_type,
       coalesce(override_class, derived_class) as class,
       override_class is not null              as is_overridden,
       derived_class, override_class, override_reason,
       balance, is_operating, active,
       ebitda_addback,
       account_ebitda_addback(account_type, account_sub_type, name,
                              coalesce(override_class, derived_class), null) as ebitda_addback_auto,
       account_ebitda_addback(account_type, account_sub_type, name,
                              coalesce(override_class, derived_class), ebitda_addback) as ebitda_addback_effective
from qbo_accounts;

-- v_cost_lines_classified (056's version): three columns appended, nothing
-- else changes — amount sign, class resolution and the name fallback are
-- byte-for-byte 056.
create or replace view v_cost_lines_classified as
select
  bl.id, bl.bill_id, b.kind, b.vendor_name, b.issued_on,
  date_trunc('month', b.issued_on::timestamp)::date as month,
  bl.account_id,
  bl.account_name,
  case when coalesce(a.account_type, an.account_type) = 'Other Income'
       then -abs(bl.amount) else bl.amount end        as amount,
  bl.qbo_project_id,
  coalesce(a.override_class, a.derived_class,
           an.override_class, an.derived_class,
           'other'::cost_class)                       as class,
  (a.id is null and an.id is null)                     as unjoined,
  coalesce(a.account_type, an.account_type)            as account_type,
  coalesce(a.account_sub_type, an.account_sub_type)    as account_sub_type,
  account_ebitda_addback(
    coalesce(a.account_type, an.account_type),
    coalesce(a.account_sub_type, an.account_sub_type),
    coalesce(a.name, an.name),
    coalesce(a.override_class, a.derived_class,
             an.override_class, an.derived_class,
             'other'::cost_class),
    coalesce(a.ebitda_addback, an.ebitda_addback))     as ebitda_addback
from bill_lines bl
join bills b on b.id = bl.bill_id
left join qbo_accounts a  on a.id = bl.account_id
-- name fallback ONLY when there is no id, and only when the name is unambiguous
left join lateral (
  select q.* from qbo_accounts q
  where bl.account_id is null
    and (q.fully_qualified_name = bl.account_name or q.name = bl.account_name)
    and 1 = (select count(*) from qbo_accounts q2
             where q2.fully_qualified_name = bl.account_name or q2.name = bl.account_name)
  limit 1
) an on true;

comment on view v_cost_lines_classified is
  'Expense lines with an effective cost class, joined on account id. Name matching '
  'survives only as an unambiguous fallback. unjoined = true marks lines that matched '
  'nothing and are therefore classified other — that count should be near zero, and '
  'anything above it is a data problem to look at, not to average over. Other-Income-typed '
  'lines (credit card rewards, bank interest) are forced negative so they reduce whatever '
  'class they are classified into rather than add to it. ebitda_addback (093) is '
  'account_ebitda_addback() for the resolved account — an unjoined line is never an '
  'add-back.';

-- forecast_page (092's body — 080 plus closed-months-only rev_proj/cogs_proj — with three additions): cost_all carries the flag,
-- addback_month and runrates.addback are new, runrates.other is gone.
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
  -- EBITDA add-back per measured month (093): cost lines on accounts flagged
  -- ebitda_addback, in the four classes the chart subtracts from net.
  -- EBITDA for a month = net + this. Other-Income-typed lines are negative in
  -- the view, so interest EARNED lowers EBITDA exactly as it raised net.
  'addback_month', coalesce((select jsonb_agg(t) from (
      select month, sum(amount)::bigint as total from cost
      where ebitda_addback and class in ('cogs', 'payroll', 'overhead', 'other')
      group by month) t), '[]'::jsonb),
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
      'addback',  (select total from addback_trail)),
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
  'cost_all (076) — display cost, the run-rates, loose-payroll, the pre-cutover '
  'health-insurance average and the EBITDA add-back all read from that single scan. '
  'Measured revenue is the invoice total minus balance-sheet invoice lines (080) '
  'minus contra revenue (025) — QuickBooks'' Total Income; rev_proj/cogs_proj count closed '
  'months only (092). labor_forecast_month is '
  'bottoms-up Team-setup Labour for the chart''s future months (071/073/074/075/070). '
  'Since 093 runrates has no ''other'': that class is not forecast. addback_month is '
  'the EBITDA add-back per measured month and runrates.addback its forward-month '
  'value (the flagged share of the overhead run-rate); EBITDA = net + add-back.';
