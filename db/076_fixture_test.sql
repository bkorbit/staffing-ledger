-- Fixture test for 076 — NOT a migration, do not ship this file.
-- Run in a transaction against a scratch db (or prod, rolled back) that
-- already has 001-075 applied. Proves forecast_page's jsonb output is
-- byte-identical before/after 076 for the same inputs, on top of whatever
-- real or fixture data the db already has — stronger than a single-row
-- fixture because it diffs the WHOLE payload, not just one number.
--
-- Usage:
--   1. begin;
--   2. paste this whole file
--   3. look for "076 EQUIVALENCE: PASS" / "FAIL" in the output
--   4. rollback;   -- always — this restores forecast_page to the 071 body
--                  -- after the test, whether it passes or fails
--
-- Every jsonb_agg below is given an explicit ORDER BY (both in the 071
-- snapshot and the 076 copy) purely so this test's jsonb equality check is
-- deterministic — forecast.html keys everything by month/id into a JS object
-- on load, so it never depends on array order, and the shipped migration
-- deliberately leaves that unordered rather than diverge from 071 for no
-- reason. Without this, a harmless GROUP BY plan-shape difference between
-- the two versions could reorder an array and produce a false FAIL here.
begin;

-- snapshot the current (071) forecast_page under a scratch name
create or replace function _forecast_page_071(p_from date, p_to date)
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
bonus_forecast as (
  select date_trunc('month', b.pay_date)::date as month,
         sum(staff_bonus_burdened_cost(b.id)) as total
  from staff_bonuses b
  where date_trunc('month', b.pay_date)::date between p_from and p_to
  group by date_trunc('month', b.pay_date)::date
),
labor_forecast_month as (
  select gm.month::date as month,
         staff_base_labor_forecast_month(gm.month::date)
           + payroll_loose_runrate()
           + health_insurance_forecast_month(gm.month::date)
           + coalesce((select total from bonus_forecast bf where bf.month = gm.month::date), 0) as total
  from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
)
select jsonb_build_object(
  'plan_month', coalesce((select jsonb_agg(t order by t::text) from (
      select month, sum(gp)::bigint as gp, sum(billable)::bigint as billable
      from plan group by month) t), '[]'::jsonb),
  'plan_deal', coalesce((select jsonb_agg(t order by t::text) from (
      select deal_id,
        sum(gp)::bigint as gp_all,
        coalesce(sum(gp) filter (where month < (select m from cur)), 0)::bigint as gp_settled,
        coalesce(sum(billable) filter (where month >= (select m from cur)), 0)::bigint as bill_future
      from plan group by deal_id) t), '[]'::jsonb),
  'rev_month', coalesce((select jsonb_agg(t order by t::text) from (
      select month, sum(total)::bigint as total from (
        select month, total from inv
        union all
        select month, -amount as total from cost where class = 'income'
      ) u group by month) t), '[]'::jsonb),
  'rev_proj', coalesce((select jsonb_agg(t order by t::text) from (
      select qbo_project_id, sum(total)::bigint as total from (
        select qbo_project_id, month, total from inv
        union all
        select qbo_project_id, month, -amount from cost
        where class = 'income' and qbo_project_id is not null
      ) u where month <= (select m from cur) and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'cost_month', coalesce((select jsonb_agg(t order by t::text) from (
      select month, class, sum(amount)::bigint as total from cost group by month, class) t), '[]'::jsonb),
  'cogs_proj', coalesce((select jsonb_agg(t order by t::text) from (
      select qbo_project_id, sum(amount)::bigint as total
      from cost where class = 'cogs' and month <= (select m from cur)
        and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(t order by t::text) from (
      select class, coalesce(account_name, '(no account)') as account,
             sum(amount)::bigint as total
      from cost group by class, account_name) t), '[]'::jsonb),
  'runrates', jsonb_build_object(
      'payroll',  cost_runrate_monthly('payroll'),
      'overhead', cost_runrate_monthly('overhead'),
      'other',    cost_runrate_monthly('other')),
  'labor_forecast_month', coalesce((select jsonb_agg(t order by t::text) from labor_forecast_month t), '[]'::jsonb),
  'projects', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'parent_id', parent_id, 'jobcode', jobcode) order by id)
      from keep_projects), '[]'::jsonb)
);
$$ language sql stable;

-- install 076's rewritten forecast_page (identical to
-- db/076_forecast_page_single_scan.sql — inlined here, not \i'd, so this
-- runs unchanged in the Supabase SQL editor as well as psql/local pg16)
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
cost_trail as (
  select class, account_name, amount
  from cost_all
  where issued_on >= (select m from cur) - interval '6 months'
    and issued_on <  (select m from cur)
),
runrate_trail as (
  select class, coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class in ('payroll', 'overhead', 'other')
  group by class
),
loose_payroll_trail as (
  select coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class = 'payroll' and account_name ilike 'Labor Cost:Payroll expenses'
),
health_ins_trail as (
  select coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class = 'payroll' and account_name ilike '%health insurance%'
),
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
  'plan_month', coalesce((select jsonb_agg(t order by t::text) from (
      select month, sum(gp)::bigint as gp, sum(billable)::bigint as billable
      from plan group by month) t), '[]'::jsonb),
  'plan_deal', coalesce((select jsonb_agg(t order by t::text) from (
      select deal_id,
        sum(gp)::bigint as gp_all,
        coalesce(sum(gp) filter (where month < (select m from cur)), 0)::bigint as gp_settled,
        coalesce(sum(billable) filter (where month >= (select m from cur)), 0)::bigint as bill_future
      from plan group by deal_id) t), '[]'::jsonb),
  'rev_month', coalesce((select jsonb_agg(t order by t::text) from (
      select month, sum(total)::bigint as total from (
        select month, total from inv
        union all
        select month, -amount as total from cost where class = 'income'
      ) u group by month) t), '[]'::jsonb),
  'rev_proj', coalesce((select jsonb_agg(t order by t::text) from (
      select qbo_project_id, sum(total)::bigint as total from (
        select qbo_project_id, month, total from inv
        union all
        select qbo_project_id, month, -amount from cost
        where class = 'income' and qbo_project_id is not null
      ) u where month <= (select m from cur) and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'cost_month', coalesce((select jsonb_agg(t order by t::text) from (
      select month, class, sum(amount)::bigint as total from cost group by month, class) t), '[]'::jsonb),
  'cogs_proj', coalesce((select jsonb_agg(t order by t::text) from (
      select qbo_project_id, sum(amount)::bigint as total
      from cost where class = 'cogs' and month <= (select m from cur)
        and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(t order by t::text) from (
      select class, coalesce(account_name, '(no account)') as account,
             sum(amount)::bigint as total
      from cost group by class, account_name) t), '[]'::jsonb),
  'runrates', jsonb_build_object(
      'payroll',  coalesce((select total from runrate_trail where class = 'payroll'), 0),
      'overhead', coalesce((select total from runrate_trail where class = 'overhead'), 0),
      'other',    coalesce((select total from runrate_trail where class = 'other'), 0)),
  'labor_forecast_month', coalesce((select jsonb_agg(t order by t::text) from labor_forecast_month t), '[]'::jsonb),
  'projects', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'parent_id', parent_id, 'jobcode', jobcode) order by id)
      from keep_projects), '[]'::jsonb)
);
$$ language sql stable;

-- compare across a handful of ranges: the app's default (-6..+6 months),
-- a range narrower than the trailing runrate window (tests the least()/
-- greatest() widening in `bounds`), a range entirely in the past, and one
-- entirely in the future.
with ranges as (
  select * from (values
    (date_trunc('month', current_date - interval '6 months')::date,
     date_trunc('month', current_date + interval '6 months')::date),
    (date_trunc('month', current_date - interval '1 month')::date,
     date_trunc('month', current_date + interval '1 month')::date),
    (date_trunc('month', current_date - interval '24 months')::date,
     date_trunc('month', current_date - interval '13 months')::date),
    (date_trunc('month', current_date + interval '1 month')::date,
     date_trunc('month', current_date + interval '18 months')::date)
  ) as t(p_from, p_to)
),
compared as (
  select p_from, p_to,
         _forecast_page_071(p_from, p_to) as old_result,
         forecast_page(p_from, p_to) as new_result
  from ranges
)
select p_from, p_to,
       old_result = new_result as identical,
       case when old_result = new_result then null else old_result end as old_if_diff,
       case when old_result = new_result then null else new_result end as new_if_diff
from compared;

-- pass/fail summary
do $$
declare
  n_bad int;
begin
  select count(*) into n_bad
  from (
    select
      _forecast_page_071(p_from, p_to) <> forecast_page(p_from, p_to) as differs
    from (values
      (date_trunc('month', current_date - interval '6 months')::date,
       date_trunc('month', current_date + interval '6 months')::date),
      (date_trunc('month', current_date - interval '1 month')::date,
       date_trunc('month', current_date + interval '1 month')::date),
      (date_trunc('month', current_date - interval '24 months')::date,
       date_trunc('month', current_date - interval '13 months')::date),
      (date_trunc('month', current_date + interval '1 month')::date,
       date_trunc('month', current_date + interval '18 months')::date)
    ) as t(p_from, p_to)
  ) x
  where differs;

  if n_bad = 0 then
    raise notice '076 EQUIVALENCE: PASS — all ranges byte-identical to 071';
  else
    raise notice '076 EQUIVALENCE: FAIL — % range(s) differ, see rows above', n_bad;
  end if;
end $$;

-- timing comparison (informational — EXPLAIN ANALYZE actually runs the query)
explain (analyze, buffers, format text)
select _forecast_page_071(
  date_trunc('month', current_date - interval '6 months')::date,
  date_trunc('month', current_date + interval '6 months')::date
);

explain (analyze, buffers, format text)
select forecast_page(
  date_trunc('month', current_date - interval '6 months')::date,
  date_trunc('month', current_date + interval '6 months')::date
);

drop function _forecast_page_071(date, date);

rollback;  -- always roll back: this only ever runs as a test
