-- Fixture test for 093 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-093 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK — the fixture rows are undone. Never swap that
--      rollback for a commit.
--
-- What is being proved (dates are relative to the real current month):
--   1. FLAGS      — account_ebitda_addback(), read through v_account_class,
--                   answers every fixture account the way 093's header says:
--                   type rule, subtype rule, name rule with word boundaries
--                   ("Pinterest" is not interest), payroll never by rule,
--                   a human override wins in BOTH directions, and a
--                   class-less account is judged as 'other'.
--   2. ADDBACK    — forecast_page.addback_month moves by exactly the flagged
--                   lines in the chart's four classes: an add-back flag on an
--                   'excluded' account counts for nothing; an Other-Income
--                   line comes through NEGATIVE; a class-less ('other')
--                   depreciation line counts; an unjoined line never does.
--   3. RUNRATE    — runrates.addback moves by the six-month average of the
--                   flagged OVERHEAD lines in the trailing window only (the
--                   'other'-class line that counted in row 2 must not).
--   4. KEYS       — runrates has payroll, overhead, addback and NO 'other'.
--   5. REGRESSION — with addback_month and runrates.addback removed, the
--                   payload is byte-identical to 092's function (its body is
--                   copied verbatim below as _fp_092) with runrates.other
--                   removed: nothing else in the page moved.
--
-- Adversarial on purpose: ten accounts across five classes, both override
-- directions, a negative-sign line, an unjoined line, two months (one closed,
-- one deeper in the trailing window) and a current-month line. A single
-- depreciation row would pass while getting every branch of the rule wrong.
--
-- Mutation check (done in the PGlite bed before shipping) — each must FAIL:
--   * drop "and class in (...)" from addback_month           -> row 2
--   * drop "class = 'overhead' and" from addback_trail       -> row 3
--   * drop the \m boundary from the interest regex            -> row 1
--   * put runrates.other back                                 -> row 4

begin;

-- ---------------------------------------------------------------- helpers --
create or replace function _norm(j jsonb) returns jsonb as $$
  select coalesce(jsonb_object_agg(k,
    case when jsonb_typeof(v) = 'array'
      then (select coalesce(jsonb_agg(e order by e::text), '[]'::jsonb)
            from jsonb_array_elements(v) e)
      else v end), '{}'::jsonb)
  from jsonb_each(j) as t(k, v);
$$ language sql immutable;

-- the 092 body, verbatim, under a scratch name (row 5 compares against it)
create or replace function _fp_092(p_from date, p_to date)
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

create temp table _fx_m as
select date_trunc('month', current_date)::date                        as cur,
       (date_trunc('month', current_date) - interval '1 month')::date  as m1,
       (date_trunc('month', current_date) - interval '3 month')::date  as m3;

-- ------------------------------------------------- BEFORE the fixture rows --
create temp table _pre as
with fp as (select forecast_page((select m3 from _fx_m), (select cur from _fx_m)) as j)
select coalesce((select (e->>'total')::bigint from fp, jsonb_array_elements(fp.j -> 'addback_month') e
                 where (e->>'month')::date = (select m1 from _fx_m)), 0) as ab_m1,
       coalesce((select (e->>'total')::bigint from fp, jsonb_array_elements(fp.j -> 'addback_month') e
                 where (e->>'month')::date = (select m3 from _fx_m)), 0) as ab_m3,
       (select (j -> 'runrates' ->> 'addback')::bigint from fp)          as rr_addback;

-- ------------------------------------------------------------- the fixture --
-- (class in brackets is what v_cost_lines_classified will resolve)
insert into qbo_accounts (id, name, fully_qualified_name, account_type, account_sub_type,
                          derived_class, override_class, ebitda_addback) values
  -- rule: subtype                                             [overhead] -> add back
  ('fx093-dep',  '_fx093 Depreciation Expense', '_fx093 Depreciation Expense', 'Expense', 'Depreciation', 'overhead', null, null),
  -- rule: type Other Expense, no telling subtype or name      [overhead] -> add back
  ('fx093-oe',   '_fx093 Non Operating Loss',   '_fx093 Non Operating Loss',   'Other Expense', 'OtherMiscellaneousExpense', 'overhead', null, null),
  -- rule: "Pinterest" must not match \minterest\M             [overhead] -> count
  ('fx093-pin',  '_fx093 Pinterest Ads',        '_fx093 Pinterest Ads',        'Expense', 'AdvertisingPromotional', 'overhead', null, null),
  -- override FALSE beats the InterestPaid subtype              [overhead] -> count
  ('fx093-int',  '_fx093 Loan Interest',        '_fx093 Loan Interest',        'Expense', 'InterestPaid', 'overhead', null, false),
  -- override TRUE on a plain software account                  [overhead] -> add back
  ('fx093-soft', '_fx093 Software',             '_fx093 Software',             'Expense', 'OfficeGeneralAdministrativeExpenses', 'overhead', null, true),
  -- Other Income (056: overhead, stored positive, view negates) [overhead] -> add back, NEGATIVE
  ('fx093-oi',   '_fx093 Interest earned',      '_fx093 Interest earned',      'Other Income', 'InterestEarned', 'overhead', null, null),
  -- Other Expense typed but payroll by 056 override            [payroll]  -> count (labour is labour)
  ('fx093-sev',  '_fx093 Severance',            '_fx093 Severance',            'Other Expense', 'OtherMiscellaneousExpense', 'overhead', 'payroll', null),
  -- excluded class with a human add-back flag                  [excluded] -> flag true, but never in the chart
  ('fx093-cc',   '_fx093 Card payments',        '_fx093 Card payments',        'Credit Card', 'CreditCard', 'excluded', null, true),
  -- class-less account, depreciation by name                   [other]    -> add back
  ('fx093-nocl', '_fx093 Depreciation catch-up','_fx093 Depreciation catch-up', null, null, null, null, null),
  -- name says income tax, subtype says nothing                 [overhead] -> add back
  ('fx093-tax',  '_fx093 State income tax',     '_fx093 State income tax',     'Expense', 'TaxesPaid', 'overhead', null, null);
-- deliberately NO account for the '_fx093 Depreciation ghost' line below — unjoined.

insert into bills (id, kind, vendor_name, issued_on, total)
select 'fx093-b1', 'bill'::cost_kind,    '_fx093 Vendor',  m1 + 4,  0 from _fx_m union all
select 'fx093-b2', 'bill'::cost_kind,    '_fx093 Vendor',  m3 + 17, 0 from _fx_m union all
select 'fx093-b3', 'journal'::cost_kind, '_fx093 Journal', m1 + 28, 0 from _fx_m union all
select 'fx093-b4', 'bill'::cost_kind,    '_fx093 Vendor',  cur + 2, 0 from _fx_m;

insert into bill_lines (id, bill_id, line_no, account_name, amount, qbo_project_id, account_id) values
  -- closed month m1
  ('fx093-l01', 'fx093-b1', 1,  '_fx093 Depreciation Expense',  100000, null, 'fx093-dep'),   -- +100000
  ('fx093-l02', 'fx093-b1', 2,  '_fx093 Non Operating Loss',    250000, null, 'fx093-oe'),    -- +250000
  ('fx093-l03', 'fx093-b1', 3,  '_fx093 Pinterest Ads',          30000, null, 'fx093-pin'),   --  counts, no add-back
  ('fx093-l04', 'fx093-b1', 4,  '_fx093 Loan Interest',          20000, null, 'fx093-int'),   --  override false
  ('fx093-l05', 'fx093-b1', 5,  '_fx093 Software',               50000, null, 'fx093-soft'),  -- +50000 (override true)
  ('fx093-l06', 'fx093-b3', 1,  '_fx093 Interest earned',         1000, null, 'fx093-oi'),    --  -1000 (view negates)
  ('fx093-l07', 'fx093-b1', 6,  '_fx093 Severance',              70000, null, 'fx093-sev'),   --  payroll, never by rule
  ('fx093-l08', 'fx093-b1', 7,  '_fx093 Card payments',          99999, null, 'fx093-cc'),    --  excluded: flag is moot
  ('fx093-l09', 'fx093-b1', 8,  '_fx093 Depreciation catch-up',   5000, null, 'fx093-nocl'),  -- +5000  (class other)
  ('fx093-l10', 'fx093-b1', 9,  '_fx093 Depreciation ghost',      7777, null, null),          --  unjoined: never
  ('fx093-l11', 'fx093-b1', 10, '_fx093 State income tax',       12000, null, 'fx093-tax'),   -- +12000
  -- m3, deeper in the trailing window
  ('fx093-l12', 'fx093-b2', 1,  '_fx093 Depreciation Expense',   40000, null, 'fx093-dep'),   -- +40000
  ('fx093-l13', 'fx093-b2', 2,  '_fx093 Software',               10000, null, 'fx093-soft'),  -- +10000
  -- the in-progress month: in addback_month (like cost_month) but outside the trailing window
  ('fx093-l14', 'fx093-b4', 1,  '_fx093 Depreciation Expense',   33333, null, 'fx093-dep');

-- ------------------------------------------------------ expected, by hand ---
--   addback m1 = 100000 + 250000 + 50000 - 1000 + 5000 + 12000 = 416000
--   addback m3 = 40000 + 10000                                   =  50000
--   runrate    = overhead-class add-backs in [cur-6mo, cur):
--                m1 (416000 - 5000 class-other) + m3 50000       = 461000 / 6
--                (rounding of a six-month average on top of whatever real
--                 data sits in the window: assert within one cent of 461000/6)

create temp table _post as
with fp as (select forecast_page((select m3 from _fx_m), (select cur from _fx_m)) as j)
select coalesce((select (e->>'total')::bigint from fp, jsonb_array_elements(fp.j -> 'addback_month') e
                 where (e->>'month')::date = (select m1 from _fx_m)), 0) as ab_m1,
       coalesce((select (e->>'total')::bigint from fp, jsonb_array_elements(fp.j -> 'addback_month') e
                 where (e->>'month')::date = (select m3 from _fx_m)), 0) as ab_m3,
       (select (j -> 'runrates' ->> 'addback')::bigint from fp)          as rr_addback,
       (select j -> 'runrates' from fp)                                  as runrates,
       (select j from fp)                                                as j;

-- 1. the flags, through v_account_class
create temp table _flags as
select id, ebitda_addback_effective as got,
       case id
         when 'fx093-dep'  then true  when 'fx093-oe'   then true  when 'fx093-pin'  then false
         when 'fx093-int'  then false when 'fx093-soft' then true  when 'fx093-oi'   then true
         when 'fx093-sev'  then false when 'fx093-cc'   then true  when 'fx093-nocl' then true
         when 'fx093-tax'  then true end as want
from v_account_class where id like 'fx093-%';

-- 5. regression against 092's own function, same range, same rows
create temp table _reg as
select _norm((j - 'addback_month') || jsonb_build_object('runrates', (j -> 'runrates') - 'addback'))
       = _norm((o - 'x') || jsonb_build_object('runrates', (o -> 'runrates') - 'other')) as ok
from (select (select j from _post) as j,
             _fp_092((select m3 from _fx_m), (select cur from _fx_m)) as o) s;

-- ======================= THE RESULT: read every row =======================
with r(n, result) as (
  select 1, case when (select count(*) from _flags where got is distinct from want) = 0
                  and (select count(*) from _flags) = 10
    then '1. FLAGS: PASS (10 accounts answer as the rule says)'
    else '1. FLAGS: FAIL — ' || coalesce((select string_agg(id || ' got ' || coalesce(got::text, 'null')
                                                          || ' want ' || want::text, ', ' order by id)
                                          from _flags where got is distinct from want), 'wrong row count') end
  union all
  select 2, case when (select ab_m1 from _post) - (select ab_m1 from _pre) = 416000
                  and (select ab_m3 from _post) - (select ab_m3 from _pre) = 50000
    then '2. ADDBACK_MONTH: PASS (m1 +416000, m3 +50000 exactly)'
    else '2. ADDBACK_MONTH: FAIL — m1 ' || ((select ab_m1 from _post) - (select ab_m1 from _pre))::text
         || ' (want 416000), m3 ' || ((select ab_m3 from _post) - (select ab_m3 from _pre))::text || ' (want 50000)' end
  union all
  select 3, case when abs(((select rr_addback from _post) - (select rr_addback from _pre)) - 461000 / 6.0) < 1
    then '3. RUNRATES.ADDBACK: PASS (+' || ((select rr_addback from _post) - (select rr_addback from _pre))::text
         || ', the flagged overhead lines / 6)'
    else '3. RUNRATES.ADDBACK: FAIL — moved ' || ((select rr_addback from _post) - (select rr_addback from _pre))::text
         || ', want ' || round(461000 / 6.0)::text end
  union all
  select 4, case when (select runrates from _post) ? 'addback' and (select runrates from _post) ? 'overhead'
                  and (select runrates from _post) ? 'payroll' and not (select runrates from _post) ? 'other'
    then '4. RUNRATE KEYS: PASS (payroll, overhead, addback; no other)'
    else '4. RUNRATE KEYS: FAIL — ' || (select runrates from _post)::text end
  union all
  select 5, case when (select ok from _reg)
    then '5. REGRESSION vs 092: PASS (everything else byte-identical)'
    else '5. REGRESSION vs 092: FAIL — some other key moved' end
  union all
  select 6, '   context: addback m1 ' || (select ab_m1 from _pre)::text || ' -> ' || (select ab_m1 from _post)::text
         || ' · m3 ' || (select ab_m3 from _pre)::text || ' -> ' || (select ab_m3 from _post)::text
         || ' · runrate ' || (select rr_addback from _pre)::text || ' -> ' || (select rr_addback from _post)::text || '  (cents)'
)
select result from r order by n;

rollback;
