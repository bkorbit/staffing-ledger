-- Fixture test for 099 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-099 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
-- Client A's deal D1 (search) enrolled with one Google Ads upload assigned to
-- Paid Media: campaigns 10 / 20 / 30 and changes 100 / 200 / 300 in the three
-- closed months m3, m2, m1, plus a row for the RUNNING month; Paid Media hours
-- 25 / 45 / 65 (hours = 2 × campaigns + 5) with an excluded and a timeoff row
-- that must not count, and a Programmatic person's hours that belong to another
-- department. Client B's deal D2 (search): campaigns 10 → 50 h (ratio 5).
--
--   1. OBSERVED  — 3 closed months for D1 / Paid Media with hours 25/45/65;
--                  the running month is not there; excluded/timeoff/other-
--                  department hours are not counted
--   2. COEFF     — company-wide: hours_per_unit(active_campaigns) =
--                  (135+50)/(60+10) = 2.6429, n 4; client A: 2.25, slope 2,
--                  intercept 5, r² 1, n 3 (client-specific once ≥ 2 rows)
--   3. COMPARE   — drivers {active_campaigns: 28} → D1 m1 (30) first
--   4. ESTIMATE  — a scope for client A with a search line month carrying
--                  {active_campaigns: 40, changes: 400, spend: 10,000,000} →
--                  Paid Media 90.00 (the MEDIAN of 40 × 2.25, 400 × 0.225 and
--                  the spend proxy's 225 — a mean would say 135), source
--                  benchmark; a MANUAL Paid Media row this month (12 h)
--                  survives; a catalog product on a retainer line adds
--                  Analytics 10 h (8 setup + 2) in the first month, 2 in the second
--   5. REPLACE   — re-uploading the same platform + team replaces the upload:
--                  still one upload, still 3 observed months
--   6. MODEL     — a saved model for Paid Media × {search} wins over the
--                  ratio: intercept 5 + 2 × campaigns → 85.00 for 40
--   7. QUICK     — quick_check with no typed hours estimates from spend
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * v_benchmark_observed: drop the attribution filter            -> row 1, 2
--   * v_benchmark_observed: drop "month < current"                 -> row 1
--   * benchmark_coefficients: client threshold ≥ 2 → ≥ 5            -> row 2 (client scope), 4
--   * estimate_dept_hours: mean instead of median                  -> row 4 (with a third, off driver)
--   * scope_estimate_hours: overwrite manual rows                  -> row 4
--   * record_benchmark_observations: skip the replace delete       -> row 5

begin;
create temp table _fx as
select date_trunc('month', current_date)::date                        as cur,
       (date_trunc('month', current_date) - interval '1 month')::date  as m1,
       (date_trunc('month', current_date) - interval '2 month')::date  as m2,
       (date_trunc('month', current_date) - interval '3 month')::date  as m3,
       (date_trunc('month', current_date) + interval '1 month')::date  as n1;

insert into clients (id, name, active) values
  ('f0f0f0f0-0000-0000-0000-000000000099', '_fx099 Client A', true),
  ('f0f0f0f0-0000-0000-0000-000000000098', '_fx099 Client B', true);
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, '_fx099 D1', 'active'::deal_status, 'manual'::deal_origin, m3, (n1 + 27)::date from _fx union all
select 'f0f0f0f0-0000-0000-0000-0000000000b9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000098'::uuid, '_fx099 D2', 'active'::deal_status, 'manual'::deal_origin, m3, (n1 + 27)::date from _fx;
insert into deal_lines (deal_id, kind, fee_pct) values
  ('f0f0f0f0-0000-0000-0000-0000000000a9', 'search', 10), ('f0f0f0f0-0000-0000-0000-0000000000b9', 'search', 10);
insert into staff (id, name, department, active, tracks_capacity) values
  ('f0f0f0f0-0000-0000-0000-0000000000c9', '_fx099 P', 'Paid Media', true, true),
  ('f0f0f0f0-0000-0000-0000-0000000000d9', '_fx099 R', 'Programmatic', true, true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, (m3 - 60)::date, 'hourly'::comp_kind, 5000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-0000000000d9'::uuid, (m3 - 60)::date, 'hourly'::comp_kind, 6000, 40 from _fx;

insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department, attribution)
select 'fx099-1', 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, m3 + 2, 25, 'Paid Media', 'deal' from _fx union all
select 'fx099-2', 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, m2 + 2, 45, 'Paid Media', 'deal' from _fx union all
select 'fx099-3', 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, m1 + 2, 40, 'Paid Media', null   from _fx union all
select 'fx099-4', 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, m1 + 9, 25, 'Paid Media', 'mapped' from _fx union all
select 'fx099-5', 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, m1 + 3, 7, 'Paid Media', 'excluded' from _fx union all
select 'fx099-6', 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, m1 + 4, 3, 'Paid Media', 'timeoff' from _fx union all
select 'fx099-7', 'f0f0f0f0-0000-0000-0000-0000000000d9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, m1 + 5, 9, 'Programmatic', 'deal' from _fx union all
select 'fx099-8', 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000099'::uuid, cur + 1, 30, 'Paid Media', 'deal' from _fx union all
select 'fx099-9', 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000b9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000098'::uuid, m1 + 6, 50, 'Paid Media', 'deal' from _fx;

create temp table _up1 as select record_benchmark_observations(
  jsonb_build_object('deal_id', 'f0f0f0f0-0000-0000-0000-0000000000a9', 'platform', 'google_ads', 'department', 'Paid Media', 'filename', 'd1.csv', 'parser', 'google-ads@1', 'row_count', 400),
  (select jsonb_build_array(
    jsonb_build_object('month', m3, 'drivers', jsonb_build_object('active_campaigns', 10, 'changes', 100, 'spend', 1000000)),
    jsonb_build_object('month', m2, 'drivers', jsonb_build_object('active_campaigns', 20, 'changes', 200, 'spend', 2000000)),
    jsonb_build_object('month', m1, 'drivers', jsonb_build_object('active_campaigns', 30, 'changes', 300, 'spend', 3000000)),
    jsonb_build_object('month', cur, 'drivers', jsonb_build_object('active_campaigns', 99, 'changes', 999, 'spend', 9900000))) from _fx),
  'fx099') as r;
create temp table _up2 as select record_benchmark_observations(
  jsonb_build_object('deal_id', 'f0f0f0f0-0000-0000-0000-0000000000b9', 'platform', 'google_ads', 'department', 'Paid Media', 'filename', 'd2.csv', 'parser', 'google-ads@1', 'row_count', 40),
  (select jsonb_build_array(jsonb_build_object('month', m1, 'drivers', jsonb_build_object('active_campaigns', 10, 'changes', 50, 'spend', 500000))) from _fx),
  'fx099') as r;

create temp table _obs as select * from v_benchmark_observed where deal_id = 'f0f0f0f0-0000-0000-0000-0000000000a9';
create temp table _cc as select benchmark_coefficients('search', 'Paid Media', null) as c;
create temp table _ca as select benchmark_coefficients('search', 'Paid Media', 'f0f0f0f0-0000-0000-0000-000000000099') as c;
create temp table _cmp as select benchmark_comparables('search', 'Paid Media', '{"active_campaigns": 28}'::jsonb, 3) as c;

-- catalog product for the retainer line
insert into products (id, name, kind, role, department, setup_hours, monthly_hours, set_by) values
  ('f0f0f0f0-0000-0000-0000-0000000000e9', '_fx099 Dashboard build', 'retainer', 'flat', 'Analytics', '{"Analytics": 8}', '{"Analytics": 2}', 'fx099');

-- the scope: client A, two months n0=cur..n1, a search line with drivers, a retainer with the product, a manual Creative demand row
create temp table _sv as select save_scope(jsonb_build_object(
  'name', '_fx099 scope', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000099',
  'deals', jsonb_build_array(jsonb_build_object('name', 'd', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', (select cur from _fx), 'flight_end', (select (n1 + 27)::date from _fx),
    'lines', jsonb_build_array(
      jsonb_build_object('kind', 'search', 'fee_pct', 10,
        'months', jsonb_build_object((select cur::text from _fx), jsonb_build_object('budget', 10000000, 'drivers', jsonb_build_object('active_campaigns', 40, 'changes', 400, 'spend', 10000000)),
                                     (select n1::text from _fx), jsonb_build_object('budget', 10000000, 'drivers', jsonb_build_object('active_campaigns', 40, 'changes', 400, 'spend', 10000000)))),
      jsonb_build_object('kind', 'retainer', 'amount', 500000, 'structure', jsonb_build_object('products', jsonb_build_array(jsonb_build_object('product_id', 'f0f0f0f0-0000-0000-0000-0000000000e9', 'qty', 1))))))),
  -- a MANUAL Paid Media row this month: the estimator has 90 h for it and must leave the 12
  'dept_months', jsonb_build_array(jsonb_build_object('department', 'Paid Media', 'month', (select cur from _fx), 'hours', 12, 'source', 'manual'))
), 'fx099', 'created') as r;
create temp table _s as select (r ->> 'scope_id')::uuid as id from _sv;
create temp table _est as select scope_estimate_hours((select id from _s), 'fx099') as r;
create temp table _dm as select department, month, hours, source from scope_dept_months where scope_id = (select id from _s);

-- replace: same deal + platform + team again
create temp table _up3 as select record_benchmark_observations(
  jsonb_build_object('deal_id', 'f0f0f0f0-0000-0000-0000-0000000000a9', 'platform', 'google_ads', 'department', 'Paid Media', 'filename', 'd1-v2.csv', 'parser', 'google-ads@1', 'row_count', 401),
  (select jsonb_build_array(
    jsonb_build_object('month', m3, 'drivers', jsonb_build_object('active_campaigns', 10, 'changes', 100, 'spend', 1000000)),
    jsonb_build_object('month', m2, 'drivers', jsonb_build_object('active_campaigns', 20, 'changes', 200, 'spend', 2000000)),
    jsonb_build_object('month', m1, 'drivers', jsonb_build_object('active_campaigns', 30, 'changes', 300, 'spend', 3000000))) from _fx),
  'fx099') as r;
create temp table _ups as select count(*) as n from benchmark_uploads where deal_id = 'f0f0f0f0-0000-0000-0000-0000000000a9';
create temp table _obs2 as select count(*) as n from v_benchmark_observed where deal_id = 'f0f0f0f0-0000-0000-0000-0000000000a9';

-- model wins
create temp table _mdl as select save_benchmark_model('Paid Media', array['search'], '{"intercept": 5, "active_campaigns": 2}'::jsonb, 12, 0.98, 'fx099') as r;
create temp table _est2 as select * from estimate_dept_hours('search', 'Paid Media', 'f0f0f0f0-0000-0000-0000-000000000099', '{"active_campaigns": 40, "changes": 400}'::jsonb);
delete from benchmark_models where department = 'Paid Media';

create temp table _qc as select quick_check('search', 2000000, 10, 3, '{}'::jsonb) as q;

with r(n, result) as (
  select 1, case when (select count(*) from _obs where department = 'Paid Media') = 3
                  and (select hours from _obs where department = 'Paid Media' and month = (select m1 from _fx)) = 65
                  and (select hours from _obs where department = 'Paid Media' and month = (select m3 from _fx)) = 25
                  and not exists (select 1 from _obs where month >= (select cur from _fx))
                  and (select (drivers ->> 'active_campaigns')::numeric from _obs where department = 'Paid Media' and month = (select m2 from _fx)) = 20
                  and (select (drivers ->> 'platforms')::int from _obs where department = 'Paid Media' and month = (select m2 from _fx)) = 1
    then '1. OBSERVED 3 closed months, hours 25/45/65 (deal + null + mapped counted; excluded, timeoff, other dept, running month not): PASS'
    else '1. OBSERVED: FAIL — ' || coalesce((select string_agg(department || ' ' || month || ' h ' || hours || ' ' || drivers::text, '; ' order by month) from _obs), 'none') end
  union all
  select 2, case when (select c ->> 'scope' from _cc) = 'company' and ((select c from _cc) ->> 'n')::int = 4
                  and (select (d ->> 'hours_per_unit')::numeric from _cc, jsonb_array_elements(c -> 'drivers') d where d ->> 'driver' = 'active_campaigns') = round(185.0 / 70, 8)
                  and (select c ->> 'scope' from _ca) = 'client' and ((select c from _ca) ->> 'n')::int = 3
                  and (select (d ->> 'hours_per_unit')::numeric from _ca, jsonb_array_elements(c -> 'drivers') d where d ->> 'driver' = 'active_campaigns') = 2.25
                  and (select (d ->> 'slope')::numeric from _ca, jsonb_array_elements(c -> 'drivers') d where d ->> 'driver' = 'active_campaigns') = 2
                  and (select (d ->> 'intercept')::numeric from _ca, jsonb_array_elements(c -> 'drivers') d where d ->> 'driver' = 'active_campaigns') = 5
                  and (select (d ->> 'r2')::numeric from _ca, jsonb_array_elements(c -> 'drivers') d where d ->> 'driver' = 'active_campaigns') = 1
    then '2. COEFF company 2.6429 h/campaign over 4 rows; client A 2.25 (slope 2, intercept 5, r² 1) over 3: PASS'
    else '2. COEFF: FAIL — company ' || (select c::text from _cc) || ' client ' || (select c::text from _ca) end
  union all
  select 3, case when (select c -> 0 ->> 'month' from _cmp)::date = (select m1 from _fx) and (select c -> 0 ->> 'deal_id' from _cmp) = 'f0f0f0f0-0000-0000-0000-0000000000a9'
    then '3. COMPARE nearest to 28 campaigns is D1 last month (30): PASS'
    else '3. COMPARE: FAIL — ' || (select c::text from _cmp) end
  union all
  select 4, case when (select r ->> 'ok' from _est) = 'true'
                  and (select hours || '|' || source from _dm where department = 'Paid Media' and month = (select cur from _fx)) = '12.00|manual'
                  and (select hours || '|' || source from _dm where department = 'Paid Media' and month = (select n1 from _fx)) = '90.00|benchmark'
                  and (select hours || '|' || source from _dm where department = 'Analytics' and month = (select cur from _fx)) = '10.00|catalog'
                  and (select hours from _dm where department = 'Analytics' and month = (select n1 from _fx)) = 2.00
    then '4. ESTIMATE Paid Media next month 90.00 (median of 40×2.25, 400×0.225 and a wild spend proxy 225; client coefficients); the manual 12 h this month kept; catalog Analytics 10 then 2: PASS'
    else '4. ESTIMATE: FAIL — ' || coalesce((select r::text from _est), 'null') || ' rows: ' || coalesce((select string_agg(department || ' ' || month || ' ' || hours || ' ' || source, '; ' order by department, month) from _dm), 'none') end
  union all
  select 5, case when (select n from _ups) = 1 and (select n from _obs2) = 3 and ((select r from _up3) ->> 'replaced')::int = 1
    then '5. REPLACE re-upload of the same platform + team replaces: 1 upload, 3 observed months: PASS'
    else '5. REPLACE: FAIL — uploads ' || (select n from _ups)::text || ' observed ' || (select n from _obs2)::text || ' ' || (select r::text from _up3) end
  union all
  select 6, case when (select hours from _est2) = 85.00 and (select method from _est2) = 'model'
    then '6. MODEL intercept 5 + 2 × 40 = 85.00 beats the ratio: PASS'
    else '6. MODEL: FAIL — ' || coalesce((select hours::text || ' ' || method from _est2), 'null') end
  union all
  select 7, case when ((select q from _qc) ->> 'hours_method') like 'ratio%'
                  and ((select q from _qc) ->> 'hours_month')::numeric = round(2000000 * round(185.0 / 6500000, 8), 2)
                  and ((select q from _qc) ->> 'gp_month')::bigint = 200000
    then '7. QUICK no typed hours → estimated from spend via the benchmarks (' || ((select q from _qc) ->> 'hours_month') || 'h): PASS'
    else '7. QUICK: FAIL — ' || (select q::text from _qc) end
)
select result from r order by n;
rollback;
