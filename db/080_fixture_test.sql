-- Fixture test for 079 + 080 — NOT a migration, do not ship this file.
-- Run in a transaction against a scratch db (or prod, rolled back) that
-- already has 001-080 applied.
--
--   1. begin;
--   2. paste this whole file
--   3. look for the five "PASS" / "FAIL" lines
--   4. rollback;   -- ALWAYS, pass or fail: this file inserts fixture rows and
--                  -- nulls every invoice_lines.account_id to make test 1
--                  -- deterministic. Rolling back restores all of it.
--
-- What is being proved:
--   1. NO-OP  — with no account stamped (the state of every existing row until
--               a full QBO re-sync backfills them), 080's forecast_page returns
--               exactly what 076's did. This is what makes it safe to run 079
--               and 080 before the re-sync.
--   2. DELTA  — a balance-sheet invoice line is subtracted from revenue for
--               exactly its own amount, no more, no less.
--   3. FAIL-OPEN — the three ways resolution can come up short (account_id
--               null, account_id pointing at nothing, account row with no
--               class) each leave the line counted as revenue. This is the
--               important one: failing closed would silently delete revenue,
--               the same shape as the credit-memo bug in salesCostRow.
--   4. PROJ   — the same subtraction lands in rev_proj, per project.
--   5. LOCKSTEP — rev_proj_page's rev_proj is digit-for-digit forecast_page's,
--               which 051 requires by hand since it is a literal copy.
--
-- The fixture is deliberately adversarial: two invoices, two months, four
-- line kinds on one invoice, one project-attributed deposit and one that is
-- not, and an income line on the same invoice as a deposit. A single-row
-- fixture would pass while getting the fail-open branches wrong.

begin;

-- ---------------------------------------------------------------- helpers --
-- Compare payloads without depending on array order: forecast.html keys
-- everything by month/id into a JS object on load, so order never matters to
-- it, and a harmless GROUP BY plan-shape difference must not read as a FAIL.
create or replace function _norm(j jsonb) returns jsonb as $$
  select coalesce(jsonb_object_agg(k,
    case when jsonb_typeof(v) = 'array'
      then (select coalesce(jsonb_agg(e order by e::text), '[]'::jsonb)
            from jsonb_array_elements(v) e)
      else v end), '{}'::jsonb)
  from jsonb_each(j) as t(k, v);
$$ language sql immutable;

-- the 076 body, verbatim, under a scratch name
create or replace function _fp_076(p_from date, p_to date)
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
      'payroll',  coalesce((select total from runrate_trail where class = 'payroll'), 0),
      'overhead', coalesce((select total from runrate_trail where class = 'overhead'), 0),
      'other',    coalesce((select total from runrate_trail where class = 'other'), 0)),
  'labor_forecast_month', coalesce((select jsonb_agg(t) from labor_forecast_month t), '[]'::jsonb),
  'projects', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'parent_id', parent_id, 'jobcode', jobcode))
      from keep_projects), '[]'::jsonb)
);
$$ language sql stable;

-- the 055 body, verbatim, under a scratch name
create or replace function _rpp_055(p_from date, p_to date)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on::timestamp)::date between p_from and p_to
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
      -- contra-revenue: debits to income-type accounts (search/social media
      -- pass-through offsets) net against invoiced revenue, same as
      -- forecast_page's rev_proj (025).
      select qbo_project_id, month, -amount from cost
      where class = 'income' and qbo_project_id is not null
    ) u where month <= (select m from cur) and qbo_project_id is not null
    group by qbo_project_id) t), '[]'::jsonb);
$$ language sql stable;

-- ------------------------------------------------------- 1. the no-op test --
-- Force the pre-backfill state so this is deterministic even on a database
-- where a re-sync has already stamped some accounts. Rolled back with the rest.
update invoice_lines set account_id = null, account_name = null;

select case when _norm(forecast_page('2026-01-01', '2026-12-01'))
               = _norm(_fp_076('2026-01-01', '2026-12-01'))
       then '1. NO-OP BEFORE BACKFILL: PASS'
       else '1. NO-OP BEFORE BACKFILL: FAIL' end as result;

-- ------------------------------------------------------------- the fixture --
insert into qbo_accounts (id, name, fully_qualified_name, account_type, derived_class) values
  ('_fx_income',  '_fx Media Revenue',  '_fx Media Revenue',  'Income',                  'income'),
  ('_fx_liab',    '_fx Media Deposit',  '_fx Media Deposit',  'Other Current Liability',  'excluded'),
  ('_fx_noclass', '_fx Unclassified',   '_fx Unclassified',   'Income',                   null);
-- deliberately NO row for '_fx_ghost' — that is the unjoined case.

insert into qbo_projects (id, name, hidden) values ('_fx_proj', '_fx Project', false)
on conflict (id) do nothing;

-- Invoice A, August, project-attributed: one income line, one deposit, and
-- the three fail-open shapes, all on the same document.
insert into invoices (id, qbo_project_id, doc_number, issued_on, total, balance) values
  ('_fx_inv_a', '_fx_proj', '_FXA', '2026-08-10', 205000, 0);
insert into invoice_lines (id, invoice_id, line_no, item_name, account_id, account_name, amount) values
  ('_fx_inv_a:1', '_fx_inv_a', 1, '_fx Media',      '_fx_income',  '_fx Media Revenue', 100000),
  ('_fx_inv_a:2', '_fx_inv_a', 2, '_fx Deposit',    '_fx_liab',    '_fx Media Deposit',  50000),
  ('_fx_inv_a:3', '_fx_inv_a', 3, '_fx Ghost',      '_fx_ghost',   '_fx Nowhere',        25000),
  ('_fx_inv_a:4', '_fx_inv_a', 4, '_fx Unstamped',  null,          null,                 20000),
  ('_fx_inv_a:5', '_fx_inv_a', 5, '_fx NoClass',    '_fx_noclass', '_fx Unclassified',   10000);

-- Invoice B, July, NO project: proves rev_month moves for an unattributed
-- deposit while rev_proj cannot, and that a second month is handled on its own.
insert into invoices (id, qbo_project_id, doc_number, issued_on, total, balance) values
  ('_fx_inv_b', null, '_FXB', '2026-07-05', 70000, 0);
insert into invoice_lines (id, invoice_id, line_no, item_name, account_id, account_name, amount) values
  ('_fx_inv_b:1', '_fx_inv_b', 1, '_fx Media',   '_fx_income', '_fx Media Revenue', 40000),
  ('_fx_inv_b:2', '_fx_inv_b', 2, '_fx Deposit', '_fx_liab',   '_fx Media Deposit', 30000);

-- --------------------------------------------- 2, 3. the delta and fail-open --
-- Expected, in cents, against the 076 baseline on the SAME fixture rows:
--   August: -50000  (the deposit alone; ghost, unstamped and class-less lines
--                    all stay revenue, and the income line is untouched)
--   July:   -30000
-- Anything else — a bigger delta means a fail-open branch is failing closed
-- and deleting revenue; a smaller one means the deposit is not being caught.
with pre as (
  select (e->>'month')::date as month, (e->>'total')::bigint as total
  from jsonb_array_elements(_fp_076('2026-07-01', '2026-08-01') -> 'rev_month') e
),
post as (
  select (e->>'month')::date as month, (e->>'total')::bigint as total
  from jsonb_array_elements(forecast_page('2026-07-01', '2026-08-01') -> 'rev_month') e
),
d as (
  select pre.month,
         pre.total as rev_076, post.total as rev_080,
         post.total - pre.total as delta
  from pre join post on post.month = pre.month
)
select case when (select delta from d where month = '2026-08-01') = -50000
             and (select delta from d where month = '2026-07-01') = -30000
       then '2/3. DELTA + FAIL-OPEN: PASS'
       else '2/3. DELTA + FAIL-OPEN: FAIL — ' ||
            coalesce((select string_agg(month::text || ' ' || rev_076::text || ' -> '
                                        || rev_080::text || ' (' || delta::text || ')',
                                        '; ' order by month)
                      from d), 'no rows')
       end as result;

-- --------------------------------------------------------- 4. rev_proj --
-- Invoice A's deposit is project-attributed, so _fx_proj's revenue must drop
-- by exactly 50000. Invoice B has no project and cannot appear at all.
with pre as (
  select (e->>'qbo_project_id') as pid, (e->>'total')::bigint as total
  from jsonb_array_elements(_fp_076('2026-07-01', '2026-08-01') -> 'rev_proj') e
),
post as (
  select (e->>'qbo_project_id') as pid, (e->>'total')::bigint as total
  from jsonb_array_elements(forecast_page('2026-07-01', '2026-08-01') -> 'rev_proj') e
)
select case when (select post.total - pre.total
                  from pre join post on post.pid = pre.pid
                  where pre.pid = '_fx_proj') = -50000
       then '4. REV_PROJ PER PROJECT: PASS'
       else '4. REV_PROJ PER PROJECT: FAIL — ' ||
            coalesce((select 'pre ' || pre.total::text || ' post ' || post.total::text
                      from pre join post on post.pid = pre.pid
                      where pre.pid = '_fx_proj'), '_fx_proj missing from one side')
       end as result;

-- ------------------------------------------------------- 5. 051 lockstep --
-- rev_proj_page is a literal copy of forecast_page's rev_proj, kept in step by
-- hand. If these ever disagree that is a bug in 080, not a second opinion on
-- what revenue means. Checked on the fixture AND on the whole real range.
select case when _norm(jsonb_build_object('r', forecast_page('2026-01-01', '2026-12-01') -> 'rev_proj'))
               = _norm(jsonb_build_object('r', rev_proj_page('2026-01-01', '2026-12-01')))
            and _norm(jsonb_build_object('r', forecast_page('2026-07-01', '2026-08-01') -> 'rev_proj'))
               = _norm(jsonb_build_object('r', rev_proj_page('2026-07-01', '2026-08-01')))
       then '5. REV_PROJ_PAGE LOCKSTEP: PASS'
       else '5. REV_PROJ_PAGE LOCKSTEP: FAIL' end as result;

-- Sanity, for reading by eye: 055's rev_proj_page must NOT match once the
-- fixture deposits are stamped — if it does, 080 never reached it.
select case when _norm(jsonb_build_object('r', rev_proj_page('2026-07-01', '2026-08-01')))
               = _norm(jsonb_build_object('r', _rpp_055('2026-07-01', '2026-08-01')))
       then '   (note) rev_proj_page is UNCHANGED from 055 — expected to differ'
       else '   (note) rev_proj_page differs from 055, as expected' end as result;

rollback;
