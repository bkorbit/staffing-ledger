-- Fixture test for 109 — NOT a migration, do not ship this file.
-- Run with 001-109 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the SINGLE result set — every line must say PASS
--   3. it ends in ROLLBACK
--
-- 109 claims to change nothing but speed, so every assertion here is an
-- equality against the thing it replaced, on data chosen to sit exactly on the
-- boundaries the rewrites depend on:
--
--   * person A is salaried with TWO comp periods (a raise on the 10th of last
--     month), enrolled in 401k with an eligibility date inside the range, and
--     enrolled in health insurance with the plan's start date inside the range
--     — so all three cohort keys flip mid-range, on three different days, and
--     hours are logged the day before / the day of / the day after each flip.
--   * person B is an hourly contractor (every burden line zero).
--   * person C is active with NO comp period at all: null rate, hours logged
--     anyway. They must survive as a row and contribute no cost.
--
--   1. DAY RATES   — staff_day_rates(person, day) = staff_hourly_cost(person,
--                    day) for every logged day, C's null included. This is the
--                    claim the cohort grouping rests on.
--   2. MONTH COSTS — staff_base_labor_forecast_dates(dates) = the per-date
--                    staff_base_labor_forecast_month(d) for each, including a
--                    mid-month date (labor_forecast_breakdown's series starts
--                    on today, not the 1st).
--   3. DETAIL      — project_detail / client_detail labor_actual for the
--                    closed month = hours x staff_hourly_cost(person, DAY),
--                    summed by hand, and = hours_page's deal_labor cost.
--   4. PARTS       — hours_page_parts / forecast_page_parts return exactly the
--                    keys asked for, each byte-equal to the whole payload's,
--                    and nothing else.
--   5. LINE FEE    — line_fee = 096's body (inlined below as _fee_096) over a
--                    grid: flat, marginal, whole, min, cap, min+cap, unknown
--                    mode, empty bands, null budget / pct / structure.
--   6. LABOR TREND — labor_forecast_breakdown per month = the four canonical
--                    per-month functions it used to call.
--   7. CASHFLOW    — out_payroll / out_overhead per period = the pre-109
--                    per-period formula, restated here from the same canonical
--                    functions.
--
-- Mutation check — each of these was applied in the PGlite bed and each made
-- the named row FAIL (rows 2, 6 and 7 share a primitive, so the first of them
-- fails all three):
--   * staff_day_rates: group cohorts without k401_key                  -> row 1
--   * staff_cost_on_dates: group cohorts without hi_key                -> row 2
--   * project_detail: price by month instead of by day                 -> row 3
--   * hours_page_parts: leave unasked keys in as nulls                 -> row 4
--   * line_fee: give an unknown fee mode the flat answer               -> row 5
--   * labor_forecast_breakdown: take the tier branch whatever the month-> row 6
--   * cashflow_forecast: pay a whole month's base per payroll run      -> row 7
--
-- Two mutations that did NOT fail, and why they cannot: rounding the health
-- insurance subtraction once instead of twice (annual HI is always twelve
-- equal months, so the inner round() has nothing to round), and dropping
-- health_insurance_forecast_month's two `exists` guards (this fixture has both
-- a priced tier and a person on it, so the guards are true either way).

begin;

-- ------------------------------------------------------------------ the fee
-- 096's line_fee, verbatim, under a scratch name
create or replace function _fee_096(p_budget bigint, p_fee_pct numeric, p_structure jsonb)
returns numeric language sql immutable as $$
with s as (select coalesce(p_structure, '{}'::jsonb) as st),
mode as (select coalesce((select st #>> '{fee,mode}' from s), 'flat') as m),
bands as (
  select t.ord,
         (t.b ->> 'pct')::numeric as pct,
         nullif(t.b ->> 'upto', '')::bigint as upto,
         coalesce(lag(nullif(t.b ->> 'upto', '')::bigint) over (order by t.ord), 0) as lo
  from s, jsonb_array_elements(case when jsonb_typeof(st #> '{fee,bands}') = 'array'
                                    then st #> '{fee,bands}' else '[]'::jsonb end)
         with ordinality as t(b, ord)
),
raw as (
  select case (select m from mode)
    when 'flat'     then coalesce(p_budget, 0) * coalesce(p_fee_pct, 0) / 100
    when 'marginal' then coalesce((select sum(greatest(least(coalesce(p_budget, 0), coalesce(upto, coalesce(p_budget, 0))) - lo, 0) * pct / 100)
                                   from bands), 0)
    when 'whole'    then coalesce((select coalesce(p_budget, 0) * pct / 100 from bands
                                   where coalesce(p_budget, 0) > lo and (upto is null or coalesce(p_budget, 0) <= upto)
                                   order by ord limit 1), 0)
  end as fee
),
floored as (
  select greatest(fee, coalesce((select nullif(st ->> 'fee_min', '')::numeric from s), fee)) as fee from raw
),
capped as (
  select least(fee, coalesce((select nullif(st ->> 'fee_cap', '')::numeric from s), fee)) as fee from floored
)
select fee from capped;
$$;

create temp table _fee_grid (n int, budget bigint, pct numeric, st jsonb);
insert into _fee_grid values
  (1,  1000000, 10,   '{}'),
  (2,  1000000, 10,   null),
  (3,  null,    10,   '{}'),
  (4,  1000000, null, '{}'),
  (5,  0,       10,   '{}'),
  (6,  1000000, 10,   '{"fee_min":"500000"}'),
  (7,  1000000, 10,   '{"fee_cap":"1000"}'),
  (8,  1000000, 10,   '{"fee_min":"500000","fee_cap":"1000"}'),
  (9,  1000000, 10,   '{"fee":{"mode":"marginal","bands":[{"pct":12,"upto":"500000"},{"pct":8}]}}'),
  (10, 1000000, 10,   '{"fee":{"mode":"whole","bands":[{"pct":12,"upto":"500000"},{"pct":8}]}}'),
  (11, 400000,  10,   '{"fee":{"mode":"whole","bands":[{"pct":12,"upto":"400000"},{"pct":8}]}}'),
  (12, 1000000, 10,   '{"fee":{"mode":"marginal","bands":[]}}'),
  (13, 1000000, 10,   '{"fee":{"mode":"whole","bands":[]}}'),
  (14, 1000000, 10,   '{"fee":{"mode":"marginal"}}'),
  (15, 1000000, 10,   '{"fee":{"mode":"nonsense","bands":[{"pct":8}]}}'),
  (16, 1000000, 10,   '{"fee":{"mode":"marginal","bands":[{"pct":12,"upto":""},{"pct":8}]}}'),
  (17, 1000000, 10,   '{"fee":{"mode":"marginal","bands":"not an array"}}'),
  (18, 1000000, 10,   '{"fee":{"mode":"flat"},"fee_min":"250000"}'),
  (19, -500000, 10,   '{}'),
  (20, 1000000, -5,   '{}');

-- ----------------------------------------------------------------- the world
create temp table _fx as select
  date_trunc('month', current_date)::date                          as cur,
  (date_trunc('month', current_date) - interval '1 month')::date   as m0,
  (date_trunc('month', current_date) + interval '1 month')::date   as n1;

-- health insurance starts on the 12th of LAST month: inside the range, and not
-- on a month boundary, so a per-month rate would answer differently
insert into settings (key, value) values
  ('health_insurance_start_date', to_jsonb(((select m0 from _fx) + 11)::text)),
  ('health_insurance_monthly_cost', '450'),
  ('k401_match_rate', '4'),
  ('k401_grandfather_cutoff', '"2020-01-01"'),
  ('programmatic_margin_default', '35')
on conflict (key) do update set value = excluded.value;
insert into health_insurance_tiers (tier_key, label, monthly_cost) values ('_fx109_single', '_fx109 Single', 60000)
  on conflict (tier_key) do update set monthly_cost = excluded.monthly_cost;
insert into workers_comp_rates (state, rate) values ('NY', 0.75) on conflict (state) do update set rate = excluded.rate;
insert into suta_rates (state, wage_base, rate) values ('NY', 1250000, 3.4) on conflict (state) do update set rate = excluded.rate;

insert into clients (id, name, qbo_customer_id, active) values
  ('f9f9f9f9-0000-0000-0000-000000000109', '_fx109 Client', '_fx109_cust', true);
insert into qbo_projects (id, name, parent_id, hidden) values ('_fx109_proj', '_fx109 Project', '_fx109_cust', false);
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, qbo_project_id)
select 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, '_fx109 deal',
       'active'::deal_status, 'manual'::deal_origin, m0, (n1 + 27)::date, '_fx109_proj' from _fx;
-- a banded, capped, rebated search line: exercises line_fee's non-flat path
-- inside v_deal_month_forecast, and line_rebate on top of it
insert into deal_lines (deal_id, kind, label, amount, budget, fee_pct, rate, hours_per_month, media_funding, billing_day, structure, rebate_pct, rebate_basis) values
  ('f9f9f9f9-0000-0000-0000-0000000d0109', 'search', null, 0, 2000000, 10, 0, 0, 'agency', 'first',
   '{"fee":{"mode":"marginal","bands":[{"pct":12,"upto":"1000000"},{"pct":8}]},"fee_min":"150000"}', 2.5, 'media'),
  ('f9f9f9f9-0000-0000-0000-0000000d0109', 'retainer', null, 300000, 0, 0, 0, 0, 'client', 'first', '{}', 0, null);

-- A: salaried, a raise on the 10th of last month, health insurance from the
--    12th of last month, New York (SDI + workers' comp + SUTA), and hired
--    seven months and five days ago — so staff_401k_eligibility_date (hire
--    month + 7 months, because the hire was not on a 1st) is the 1st of THIS
--    month. Three different cohort keys therefore flip on three different
--    days inside the range, which is the whole point of this person.
insert into staff (id, name, department, active, tracks_capacity, start_date, enrolled_401k, enrolled_health_insurance, health_insurance_tier, work_state)
select 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, '_fx109 A', 'Paid Media', true, true,
       (cur - interval '7 months' + interval '5 days')::date, true, true, '_fx109_single', 'NY' from _fx;
insert into staff (id, name, department, active, tracks_capacity, start_date, enrolled_401k, enrolled_health_insurance, work_state)
select 'f9f9f9f9-0000-0000-0000-00000000b109'::uuid, '_fx109 B', 'Creative', true, true, (m0 - 400)::date, false, false, 'NY' from _fx
union all
select 'f9f9f9f9-0000-0000-0000-00000000c109'::uuid, '_fx109 C', 'AdOps', true, true, (m0 - 400)::date, false, false, 'NY' from _fx;
insert into comp_periods (staff_id, starts_on, ends_on, kind, annual_cost, weekly_capacity, employment_type)
select 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, (cur - interval '7 months' + interval '5 days')::date, (m0 + 8)::date, 'salary'::comp_kind, 12000000, 40, 'full_time' from _fx;
insert into comp_periods (staff_id, starts_on, kind, annual_cost, weekly_capacity, employment_type)
select 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, (m0 + 9)::date, 'salary'::comp_kind, 15000000, 40, 'full_time' from _fx;
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity, employment_type)
select 'f9f9f9f9-0000-0000-0000-00000000b109'::uuid, (m0 - 400)::date, 'hourly'::comp_kind, 9000, 40, 'contractor' from _fx;
-- C deliberately has no comp_periods row at all

-- 401k eligibility for A falls on the 1st of a month by construction; put the
-- hours around every boundary that matters: the raise (m0+9), the health
-- insurance start (m0+11), and the month edge
insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, attribution)
select 'fx109-a1', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 7)::date,  3.00, 'deal' from _fx union all
select 'fx109-a2', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 8)::date,  2.00, 'deal' from _fx union all
select 'fx109-a3', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 9)::date,  4.00, 'deal' from _fx union all
select 'fx109-a4', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 10)::date, 1.50, 'deal' from _fx union all
select 'fx109-a5', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 11)::date, 2.50, 'deal' from _fx union all
select 'fx109-a6', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 12)::date, 5.00, 'deal' from _fx union all
select 'fx109-a7', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, cur,             6.00, 'deal' from _fx union all
select 'fx109-b1', 'f9f9f9f9-0000-0000-0000-00000000b109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 9)::date,  7.00, 'deal' from _fx union all
select 'fx109-c1', 'f9f9f9f9-0000-0000-0000-00000000c109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 9)::date,  9.00, 'deal' from _fx union all
select 'fx109-x1', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 9)::date,  8.00, 'excluded' from _fx union all
select 'fx109-x2', 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, 'f9f9f9f9-0000-0000-0000-0000000d0109'::uuid, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, (m0 + 9)::date,  1.00, 'timeoff' from _fx;

-- money on the project, in the CLOSED month: an invoice, a deposit line that
-- is not revenue (080), a contra line (025) and a COGS bill line
insert into invoices (id, client_id, qbo_project_id, doc_number, issued_on, due_on, total, balance, qbo_customer_name)
select 'fx109-inv'::text, 'f9f9f9f9-0000-0000-0000-000000000109'::uuid, '_fx109_proj'::text, 'FX109'::text, (m0 + 3)::date, (m0 + 33)::date, 900000::bigint, 900000::bigint, '_fx109 Client'::text from _fx;
insert into qbo_accounts (id, name, fully_qualified_name, account_type, account_sub_type, derived_class) values
  ('_fx109_inc',  '_fx109 Revenue',  '_fx109 Revenue',  'Income',             null, 'income'),
  ('_fx109_dep',  '_fx109 Deposit',  '_fx109 Deposit',  'Other Current Liability', null, 'deposit'),
  ('_fx109_cogs', '_fx109 Media',    '_fx109 Media',    'Cost of Goods Sold', 'SuppliesMaterialsCogs', 'cogs'),
  ('_fx109_ovh',  '_fx109 Rent',     '_fx109 Rent',     'Expense',            'RentOrLeaseOfBuildings', 'overhead'),
  ('_fx109_pay',  '_fx109 Payroll',  'Labor Cost:Payroll expenses', 'Expense', 'PayrollExpenses', 'payroll'),
  ('_fx109_hi',   '_fx109 Health insurance', 'Labor Cost:Health insurance', 'Expense', 'PayrollExpenses', 'payroll');
insert into invoice_lines (id, invoice_id, line_no, item_name, amount, account_id, account_name) values
  ('fx109-il1', 'fx109-inv', 1, 'Service', 700000, '_fx109_inc', '_fx109 Revenue'),
  ('fx109-il2', 'fx109-inv', 2, 'Deposit', 200000, '_fx109_dep', '_fx109 Deposit');
insert into bills (id, kind, vendor_name, issued_on, due_on, total, balance)
select 'fx109-bill'::text, 'bill'::cost_kind, '_fx109 Vendor'::text, (m0 + 4)::date, (m0 + 34)::date, 250000::bigint, 0::bigint from _fx;
insert into bill_lines (id, bill_id, line_no, item_name, account_id, account_name, amount, qbo_project_id) values
  ('fx109-bl1', 'fx109-bill', 1, 'Media', '_fx109_cogs', '_fx109 Media', 250000, '_fx109_proj');
-- trailing-window cost lines, so the overhead / loose-payroll / health-insurance
-- run-rates are not all zero
insert into bills (id, kind, vendor_name, issued_on, due_on, total, balance)
select 'fx109-ovh-' || g, 'bill'::cost_kind, '_fx109 Landlord'::text, (cur - (g * 30))::date, (cur - (g * 30) + 30)::date, 600000::bigint, 0::bigint from _fx, generate_series(1, 5) g;
insert into bill_lines (id, bill_id, line_no, item_name, account_id, account_name, amount)
select 'fx109-ovhl-' || g, 'fx109-ovh-' || g, 1, 'Rent', '_fx109_ovh', '_fx109 Rent', 400000 from generate_series(1, 5) g
union all
select 'fx109-payl-' || g, 'fx109-ovh-' || g, 2, 'Payroll', '_fx109_pay', 'Labor Cost:Payroll expenses', 150000 from generate_series(1, 5) g
union all
select 'fx109-hil-' || g, 'fx109-ovh-' || g, 3, 'Health', '_fx109_hi', 'Labor Cost:Health insurance', 50000 from generate_series(1, 5) g;
-- a scheduled bonus inside the cashflow horizon and the labor trend
insert into staff_bonuses (staff_id, pay_date, amount)
select 'f9f9f9f9-0000-0000-0000-00000000a109'::uuid, (n1 + 9)::date, 500000::bigint from _fx;

-- ------------------------------------------------------------- the payloads
create temp table _days as
  select distinct staff_id, worked_on from time_entries
  where deal_id = 'f9f9f9f9-0000-0000-0000-0000000d0109'
    and coalesce(attribution, '') not in ('excluded', 'timeoff');
create temp table _rates as
  select staff_id, worked_on, rate from staff_day_rates(null, null, array['f9f9f9f9-0000-0000-0000-0000000d0109'::uuid]);
create temp table _dates as
  select (select m0 from _fx) as d union all select (select cur from _fx)
  union all select ((select cur from _fx) + 12)::date union all select (select n1 from _fx);
create temp table _bulk as
  select on_date, total from staff_base_labor_forecast_dates((select array_agg(d) from _dates));
create temp table _pd as select project_detail('f9f9f9f9-0000-0000-0000-0000000d0109') as j;
create temp table _cd as select client_detail('f9f9f9f9-0000-0000-0000-000000000109') as j;
create temp table _hp_full as select hours_page((select m0 from _fx), ((select n1 from _fx) - 1)::date) as j;
create temp table _hp_part as select hours_page_parts((select m0 from _fx), ((select n1 from _fx) - 1)::date,
  array['staff','deal_labor','staff_hours_deal_month','deal_forecast']) as j;
create temp table _fp_full as select forecast_page((select m0 from _fx), (select n1 from _fx)) as j;
create temp table _fp_part as select forecast_page_parts((select m0 from _fx), (select n1 from _fx),
  array['plan_month','rev_proj','runrates','labor_forecast_month']) as j;
create temp table _trend as select * from labor_forecast_breakdown((select cur from _fx), ((select n1 from _fx) + 40)::date);
create temp table _cf as select * from cashflow_forecast(6);
-- the pre-109 per-period payroll formula, restated from the canonical
-- per-month functions: each half-month period carries the one payroll run that
-- falls inside it, at half that month's base, plus the loose run-rate, plus
-- health insurance on the 1st, plus any bonus paid in the period.
create temp table _cf_expect as
with runs as (
  select d::date as pay_on, date_trunc('month', d)::date as month from (
    select (date_trunc('month', current_date) + make_interval(months => m) + interval '14 days') as d from generate_series(0, 5) m
    union all
    select (date_trunc('month', current_date) + make_interval(months => m + 1) - interval '1 day') from generate_series(0, 5) m
  ) x where d::date >= current_date
)
select c.week_start,
  coalesce((select round(staff_base_labor_forecast_month(r.month) / 2.0) from runs r
            where r.pay_on between c.week_start and
                  case when extract(day from c.week_start) = 1 then (c.week_start + 14)::date
                       else (date_trunc('month', c.week_start) + interval '1 month - 1 day')::date end
            limit 1), 0)::bigint
  + round(payroll_loose_runrate() / 2.0)
  + case when extract(day from c.week_start) = 1 then health_insurance_forecast_month(c.week_start) else 0 end
  + coalesce((select sum(staff_bonus_burdened_cost(b.id)) from staff_bonuses b
              where b.pay_date between c.week_start and
                    case when extract(day from c.week_start) = 1 then (c.week_start + 14)::date
                         else (date_trunc('month', c.week_start) + interval '1 month - 1 day')::date end), 0) as out_payroll
from _cf c;

with r(n, result) as (
  select 1, case when (select count(*) from _days) = 9
                  and (select count(*) from _rates) = 9
                  and not exists (
                        select 1 from _days d
                        left join _rates r on r.staff_id = d.staff_id and r.worked_on = d.worked_on
                        where r.rate is distinct from staff_hourly_cost(d.staff_id, d.worked_on))
                  and (select count(*) from _rates where rate is null) = 1
                  and (select count(distinct rate) from _rates where staff_id = 'f9f9f9f9-0000-0000-0000-00000000a109') = 4
    then '1. DAY RATES all 9 logged days priced exactly as staff_hourly_cost(person, day); C has no comp period and stays null; A''s rate changes 4 times across the raise, 401k and health-insurance boundaries: PASS'
    else '1. DAY RATES: FAIL — ' || coalesce((select string_agg(d.staff_id::text || ' ' || d.worked_on || ' cohort ' || coalesce(r.rate::text, 'null')
           || ' vs live ' || coalesce(staff_hourly_cost(d.staff_id, d.worked_on)::text, 'null'), '; ' order by d.worked_on, d.staff_id)
           from _days d left join _rates r on r.staff_id = d.staff_id and r.worked_on = d.worked_on
           where r.rate is distinct from staff_hourly_cost(d.staff_id, d.worked_on)), 'counts: ' || (select count(*) from _days) || '/' || (select count(*) from _rates)) end
  union all
  select 2, case when (select count(*) from _bulk) = 4
                  and not exists (select 1 from _dates d left join _bulk b on b.on_date = d.d
                                  where b.total is distinct from staff_base_labor_forecast_month(d.d))
    then '2. MONTH COSTS staff_base_labor_forecast_dates matches staff_base_labor_forecast_month on all four dates, mid-month one included: PASS'
    else '2. MONTH COSTS: FAIL — ' || coalesce((select string_agg(d.d || ' bulk ' || coalesce(b.total::text, 'null') || ' vs ' || coalesce(staff_base_labor_forecast_month(d.d)::text, 'null'), '; ' order by d.d)
           from _dates d left join _bulk b on b.on_date = d.d), 'no rows') end
  union all
  select 3, case when (select (e ->> 'labor_actual')::bigint from _pd, jsonb_array_elements(j -> 'months') e, _fx where (e ->> 'month')::date = m0)
                     = (select sum(t.hours * staff_hourly_cost(t.staff_id, t.worked_on))::bigint from time_entries t, _fx
                        where t.deal_id = 'f9f9f9f9-0000-0000-0000-0000000d0109'
                          and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
                          and date_trunc('month', t.worked_on)::date = m0)
                  and (select (e ->> 'labor_actual')::bigint from _cd, jsonb_array_elements(j -> 'months') e, _fx where (e ->> 'month')::date = m0)
                     = (select (e ->> 'labor_actual')::bigint from _pd, jsonb_array_elements(j -> 'months') e, _fx where (e ->> 'month')::date = m0)
                  and (select sum((e ->> 'labor_actual')::bigint) from _pd, jsonb_array_elements(j -> 'months') e)
                     = (select (e ->> 'cost')::bigint from _hp_full, jsonb_array_elements(j -> 'deal_labor') e
                        where e ->> 'deal_id' = 'f9f9f9f9-0000-0000-0000-0000000d0109')
                       - (select sum(t.hours * staff_hourly_cost(t.staff_id, t.worked_on))::bigint from time_entries t, _fx
                          where t.deal_id = 'f9f9f9f9-0000-0000-0000-0000000d0109'
                            and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
                            and date_trunc('month', t.worked_on)::date = cur)
    then '3. DETAIL project_detail and client_detail price the closed month by DAY rate, to the cent, and agree with hours_page''s deal_labor once the running month is taken out: PASS'
    else '3. DETAIL: FAIL — project ' || coalesce((select (e ->> 'labor_actual') from _pd, jsonb_array_elements(j -> 'months') e, _fx where (e ->> 'month')::date = m0), 'null')
      || ' client ' || coalesce((select (e ->> 'labor_actual') from _cd, jsonb_array_elements(j -> 'months') e, _fx where (e ->> 'month')::date = m0), 'null')
      || ' by hand ' || coalesce((select sum(t.hours * staff_hourly_cost(t.staff_id, t.worked_on))::bigint::text from time_entries t, _fx
             where t.deal_id = 'f9f9f9f9-0000-0000-0000-0000000d0109' and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
               and date_trunc('month', t.worked_on)::date = m0), 'null') end
  union all
  select 4, case when (select array_agg(k order by k) from _hp_part, jsonb_object_keys(j) k)
                     = array['deal_forecast','deal_labor','staff','staff_hours_deal_month']
                  and not exists (select 1 from _hp_part p, _hp_full f, jsonb_object_keys(p.j) k where p.j -> k is distinct from f.j -> k)
                  and (select array_agg(k order by k) from _fp_part, jsonb_object_keys(j) k)
                     = array['labor_forecast_month','plan_month','rev_proj','runrates']
                  and not exists (select 1 from _fp_part p, _fp_full f, jsonb_object_keys(p.j) k where p.j -> k is distinct from f.j -> k)
                  and (select count(*) from _hp_full, jsonb_object_keys(j) k) = 14
                  and (select count(*) from _fp_full, jsonb_object_keys(j) k) = 11
    then '4. PARTS hours_page_parts / forecast_page_parts return exactly the four keys asked for, each equal to the whole payload''s, and the whole payload still has all 14 / 11: PASS'
    else '4. PARTS: FAIL — hours keys ' || (select array_agg(k order by k)::text from _hp_part, jsonb_object_keys(j) k)
      || ' forecast keys ' || (select array_agg(k order by k)::text from _fp_part, jsonb_object_keys(j) k)
      || ' differing: ' || coalesce((select string_agg(k, ',') from _hp_part p, _hp_full f, jsonb_object_keys(p.j) k where p.j -> k is distinct from f.j -> k), 'none') end
  union all
  select 5, case when not exists (select 1 from _fee_grid
                                  where line_fee(budget, pct, st) is distinct from _fee_096(budget, pct, st))
                  and (select count(*) from _fee_grid) = 20
                  and line_fee(1000000, 10, '{"fee":{"mode":"nonsense","bands":[{"pct":8}]}}') is null
                  and (select sum(gp)::bigint from v_deal_month_forecast, _fx
                       where deal_id = 'f9f9f9f9-0000-0000-0000-0000000d0109' and month = m0)
                      = round(_fee_096(2000000, 10, '{"fee":{"mode":"marginal","bands":[{"pct":12,"upto":"1000000"},{"pct":8}]},"fee_min":"150000"}'))::bigint + 300000
    then '5. LINE FEE identical to 096 across all 20 grid cases (flat, marginal, whole, min, cap, min+cap, unknown mode, empty bands, nulls); an unknown mode is still null; the banded deal line prices the same inside the view: PASS'
    else '5. LINE FEE: FAIL — ' || coalesce((select string_agg(n || ': ' || coalesce(line_fee(budget, pct, st)::text, 'null') || ' vs ' || coalesce(_fee_096(budget, pct, st)::text, 'null'), '; ' order by n)
           from _fee_grid where line_fee(budget, pct, st) is distinct from _fee_096(budget, pct, st)), 'unknown mode gave ' || coalesce(line_fee(1000000, 10, '{"fee":{"mode":"nonsense"}}')::text, 'null')) end
  union all
  select 6, case when (select count(*) from _trend) > 1
                  and not exists (
                        select 1 from _trend t
                        where t.base_statutory_cents   is distinct from staff_base_labor_forecast_month(t.month)
                           or t.loose_payroll_cents    is distinct from payroll_loose_runrate()
                           or t.health_insurance_cents is distinct from health_insurance_forecast_month(t.month)
                           or t.total_cents is distinct from (t.base_statutory_cents + t.loose_payroll_cents + t.health_insurance_cents + t.bonus_cents))
                  and (select sum(bonus_cents) from _trend) = (select sum(staff_bonus_burdened_cost(id)) from staff_bonuses)
    then '6. LABOR TREND every month equals the four canonical per-month functions it used to call one by one, and the scheduled bonus lands once: PASS'
    else '6. LABOR TREND: FAIL — ' || coalesce((select string_agg(t.month || ' base ' || coalesce(t.base_statutory_cents::text, 'null') || '/' || coalesce(staff_base_labor_forecast_month(t.month)::text, 'null')
           || ' loose ' || t.loose_payroll_cents || '/' || payroll_loose_runrate()
           || ' hi ' || t.health_insurance_cents || '/' || health_insurance_forecast_month(t.month), '; ' order by t.month) from _trend t), 'no rows') end
  union all
  select 7, case when (select count(*) from _cf) = 6
                  and not exists (select 1 from _cf c join _cf_expect e on e.week_start = c.week_start
                                  where c.out_payroll is distinct from e.out_payroll)
                  and not exists (select 1 from _cf c where c.out_overhead is distinct from round(cost_runrate_monthly('overhead') / 2.0)::bigint)
    then '7. CASHFLOW out_payroll for every period equals the pre-109 per-period formula (half the month''s base on its own payroll run, plus the loose run-rate, plus health insurance on the 1st, plus the bonus in its own period), and out_overhead is half the overhead run-rate: PASS'
    else '7. CASHFLOW: FAIL — ' || coalesce((select string_agg(c.week_start || ' got ' || c.out_payroll || ' want ' || e.out_payroll, '; ' order by c.week_start)
           from _cf c join _cf_expect e on e.week_start = c.week_start where c.out_payroll is distinct from e.out_payroll),
           'overhead ' || coalesce((select min(out_overhead)::text from _cf), 'none') || ' vs ' || round(cost_runrate_monthly('overhead') / 2.0)::text) end
)
select result from r order by n;

rollback;
