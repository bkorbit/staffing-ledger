-- Fixture test for 096 + 097 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-097 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
-- One client with a live retainer deal D0 (P planned 20h on it next month),
-- staff P and Q (Paid Media), R (Programmatic), T (Creative, 1 h/wk), and a
-- two-month scope (this month n0, next month n1) with six lines:
--   search       marginal 15% ≤ $50k, 12% ≤ $150k, 10% above; min fee $5,000;
--                n0 $120,000 → 7,500 + 8,400 = $15,900; n1 $20,000 → raw
--                $3,000 → floored to $5,000
--   social       whole-spend, same bands, EMG-funded, rebate 2% of FEE;
--                n0 $120,000 → 12% = $14,400; n1 exactly $50,000 → 15% =
--                $7,500 (boundary inclusive); pass_through = the media
--   programmatic fee 5% + backend 30%, rebate 2% of MEDIA, $100,000/mo →
--                gp $35,000, billable $105,000, rebate $2,000
--   programmatic CPM, platform share 50%, $10,000/mo → gp $5,000, billable $10,000
--   hourly       40 h × $200 → $8,000/mo
--   retainer     $10,000/mo, 20 h included, $250/h overage
-- Demand: Paid Media 100 h/mo, Programmatic 30 h/mo, Creative 100 h/mo.
-- Supply: P 40 h both months, Q 20 h in n0, a Paid Media placeholder in P's
-- band 20 h in n0. Everything else is UNASSIGNED and priced at the
-- department average; Creative can cover ~0 h → hire path.
--
--   1. PRIMITIVES — line_fee marginal / whole / boundary / min / flat-half-cent,
--                   prog_suggest_margin(5, 40) = 37
--   2. MONTHS     — gp / billable / pass_through / rebate per line, to the cent
--   3. LABOR      — n0 and n1 labor = named at their own rates + placeholder
--                   at the band rate + unassigned at the department averages;
--                   payload carries no per-person cost
--   4. VERDICT    — pal = gp − rebate − labor, per_hour = round(pal/hours),
--                   status go; hire recommended for Creative with both costs
--   5. CAPACITY   — P next month: committed_other = 20 (D0), free_after =
--                   capacity − 20 − 40
--   6. CLIENT     — roll-up month n1: gp_existing = D0's $10,000 plan,
--                   labor_existing = 20 h × P's rate, pal_combined adds up
--   7. LIFECYCLE  — approve by a stranger refused; propose → approve writes 3
--                   assignment rows (deal_id null, scope_id set); hours_page
--                   staff_planned for P = 100, staff_deal_planned = 20 (D0
--                   only); save on approved refused; un-approve deletes the 3
--   8. AUTO-STAFF — fills Paid Media's gap with P alone (rank 1: worked this
--                   client), 20 h in n0 and 60 h in n1; Q gets nothing
--   9. VERSIONS   — versions count grows per save/approve; the latest payload
--                   re-saved reproduces identical scope_months
--  10. QUICK      — quick_check for a $100k search line at 10% with 30 h/mo:
--                   per_hour = round((gp − labor)/30), status follows target
--
-- Mutation check (PGlite bed, before shipping) — each must FAIL:
--   * line_fee: "<" instead of "<=" at the band boundary          -> row 1, 2
--   * line_fee: drop the fee_min floor                            -> row 1, 2
--   * scope_months: subtract rebate inside gp                     -> row 2, 4
--   * scope_months: round programmatic twice                      -> row 2 (a half-cent case)
--   * scope_labor: price unassigned at 0                          -> row 3, 4
--   * scope_labor: expose a per-row cost column                   -> row 3 (shape)
--   * scope_verdict: forget rebate in pal                         -> row 4
--   * scope_verdict: committed_other without the own-scope exclusion -> row 5 (after approve)
--   * approve_scope: skip the approver check                      -> row 7
--   * approve_scope: write placeholders too                       -> row 7 (4 rows)
--   * auto_staff: candidates in name order                        -> row 8

begin;
create temp table _fx as
select date_trunc('month', current_date)::date                        as n0,
       (date_trunc('month', current_date) + interval '1 month')::date  as n1,
       (date_trunc('month', current_date) - interval '1 month')::date  as m1;

insert into settings (key, value, set_by) values
  ('scope_target_profit_per_hour', '150'::jsonb, 'fx097'),
  ('scope_target_utilization_pct', '80'::jsonb, 'fx097'),
  ('scope_prog_target_gp_pct', '40'::jsonb, 'fx097'),
  ('scope_cpm_platform_share_pct', '50'::jsonb, 'fx097'),
  ('programmatic_margin_default', '35'::jsonb, 'fx097'),
  ('scope_approver_emails', '["boss@fx097"]'::jsonb, 'fx097'),
  ('scope_comp_bands', '[{"name":"Band 1","upto_c":4500},{"name":"Band 2","upto_c":7500},{"name":"Band 3","upto_c":11500},{"name":"Band 4","upto_c":null}]'::jsonb, 'fx097'),
  ('scope_hire_costs', '{"Creative":{"annual_c":10400000,"contractor_hourly_c":9000}}'::jsonb, 'fx097'),
  ('scope_hire_fte_share_pct', '50'::jsonb, 'fx097'),
  ('scope_hire_min_months', '2'::jsonb, 'fx097'),
  ('assignments_seed_lookback_months', '3'::jsonb, 'fx097')
on conflict (key) do update set value = excluded.value;

insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000097', '_fx097 Client', true);
insert into staff (id, name, department, active, tracks_capacity) values
  ('f0f0f0f0-0000-0000-0000-0000000000b7', '_fx097 P', 'Paid Media',   true, true),
  ('f0f0f0f0-0000-0000-0000-0000000000c7', '_fx097 Q', 'Paid Media',   true, true),
  ('f0f0f0f0-0000-0000-0000-0000000000d7', '_fx097 R', 'Programmatic', true, true),
  ('f0f0f0f0-0000-0000-0000-0000000000e7', '_fx097 T', 'Creative',     true, true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-0000000000b7'::uuid, (m1 - 400)::date, 'hourly'::comp_kind, 5000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-0000000000c7'::uuid, (m1 - 400)::date, 'hourly'::comp_kind, 8000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-0000000000d7'::uuid, (m1 - 400)::date, 'hourly'::comp_kind, 6000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-0000000000e7'::uuid, (m1 - 400)::date, 'hourly'::comp_kind, 7000, 1  from _fx;

-- the client's live deal: a $10,000 retainer over n0..n1, P planned 20 h on it in n1,
-- and P logged hours on it last month (client history for the ranking)
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-0000000000a7'::uuid, 'f0f0f0f0-0000-0000-0000-000000000097'::uuid, '_fx097 D0',
       'active'::deal_status, 'manual'::deal_origin, n0, (n1 + 27)::date from _fx;
insert into deal_lines (deal_id, kind, amount, billing_day) values
  ('f0f0f0f0-0000-0000-0000-0000000000a7', 'retainer', 1000000, 'first');
insert into assignments (staff_id, deal_id, month, hours, set_by)
select 'f0f0f0f0-0000-0000-0000-0000000000b7'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a7'::uuid, n1, 20, 'human@fx097' from _fx;
insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department, attribution)
select 'fx097-1', 'f0f0f0f0-0000-0000-0000-0000000000b7'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a7'::uuid,
       'f0f0f0f0-0000-0000-0000-000000000097'::uuid, m1 + 3, 10, 'Paid Media', 'deal' from _fx;

-- rates the fixture prices with — the same functions the RPCs use
create temp table _r as
select staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000b7', n0) as p0,
       staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000b7', n1) as p1,
       staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000c7', n0) as q0,
       staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000d7', n0) as r0,
       staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000d7', n1) as r1,
       staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000e7', n0) as t0,
       staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000e7', n1) as t1,
       staff_band('f0f0f0f0-0000-0000-0000-0000000000b7', n0) as p_band
from _fx;

-- the scope, saved through save_scope from the payload shape the editor sends
create temp table _sv as
select save_scope(jsonb_build_object(
  'name', '_fx097 scope', 'scenario', 'Base',
  'client_id', 'f0f0f0f0-0000-0000-0000-000000000097',
  'payment_net_days', 30,
  'deals', jsonb_build_array(jsonb_build_object(
    'ord', 0, 'name', '_fx097 new deal', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', (select n0 from _fx), 'flight_end', (select (n1 + 27)::date from _fx),
    'lines', jsonb_build_array(
      jsonb_build_object('ord', 0, 'kind', 'search', 'fee_pct', 0, 'media_funding', 'client',
        'structure', jsonb_build_object('fee', jsonb_build_object('mode', 'marginal', 'bands', jsonb_build_array(
            jsonb_build_object('upto', 5000000, 'pct', 15), jsonb_build_object('upto', 15000000, 'pct', 12), jsonb_build_object('upto', null, 'pct', 10))),
          'fee_min', 500000),
        'months', jsonb_build_object((select n0::text from _fx), jsonb_build_object('budget', 12000000),
                                     (select n1::text from _fx), jsonb_build_object('budget', 2000000))),
      jsonb_build_object('ord', 1, 'kind', 'social', 'fee_pct', 0, 'media_funding', 'agency',
        'structure', jsonb_build_object('fee', jsonb_build_object('mode', 'whole', 'bands', jsonb_build_array(
            jsonb_build_object('upto', 5000000, 'pct', 15), jsonb_build_object('upto', 15000000, 'pct', 12), jsonb_build_object('upto', null, 'pct', 10))),
          'rebate', jsonb_build_object('pct', 2, 'basis', 'fee')),
        'months', jsonb_build_object((select n0::text from _fx), jsonb_build_object('budget', 12000000),
                                     (select n1::text from _fx), jsonb_build_object('budget', 5000000))),
      jsonb_build_object('ord', 2, 'kind', 'programmatic', 'fee_pct', 5, 'margin_pct', 30, 'budget', 10000000,
        'structure', jsonb_build_object('prog', jsonb_build_object('model', 'fee_margin'), 'rebate', jsonb_build_object('pct', 2, 'basis', 'media'))),
      jsonb_build_object('ord', 3, 'kind', 'programmatic', 'fee_pct', 9, 'margin_pct', 12, 'budget', 1000000,
        'structure', jsonb_build_object('prog', jsonb_build_object('model', 'cpm', 'platform_share_pct', 50))),
      jsonb_build_object('ord', 4, 'kind', 'hourly', 'label', 'SEO', 'rate', 20000, 'hours_per_month', 40),
      jsonb_build_object('ord', 5, 'kind', 'retainer', 'amount', 1000000, 'hours_included', 20, 'overage_rate', 25000)))),
  'dept_months', jsonb_build_array(
    jsonb_build_object('department', 'Paid Media',   'month', (select n0 from _fx), 'hours', 100, 'source', 'manual'),
    jsonb_build_object('department', 'Paid Media',   'month', (select n1 from _fx), 'hours', 100, 'source', 'manual'),
    jsonb_build_object('department', 'Programmatic', 'month', (select n0 from _fx), 'hours', 30,  'source', 'manual'),
    jsonb_build_object('department', 'Programmatic', 'month', (select n1 from _fx), 'hours', 30,  'source', 'manual'),
    jsonb_build_object('department', 'Creative',     'month', (select n0 from _fx), 'hours', 100, 'source', 'manual'),
    jsonb_build_object('department', 'Creative',     'month', (select n1 from _fx), 'hours', 100, 'source', 'manual')),
  'staff_months', jsonb_build_array(
    jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-0000000000b7', 'department', 'Paid Media', 'month', (select n0 from _fx), 'hours', 40),
    jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-0000000000b7', 'department', 'Paid Media', 'month', (select n1 from _fx), 'hours', 40),
    jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-0000000000c7', 'department', 'Paid Media', 'month', (select n0 from _fx), 'hours', 20),
    jsonb_build_object('staff_id', null, 'department', 'Paid Media', 'band', (select p_band from _r), 'month', (select n0 from _fx), 'hours', 20))
), 'seller@fx097', 'first cut') as r;

create temp table _s as select (r ->> 'scope_id')::uuid as id, r from _sv;

create temp table _months as
select m.* from scope_months((select id from _s)) m;
create temp table _labor as
select l.* from scope_labor((select id from _s)) l;
create temp table _v as
select scope_verdict((select id from _s)) as v;
create temp table _page as
select scope_page((select id from _s)) as p;

-- expected labor, assembled by hand from the same rate functions
create temp table _want as
select
  -- n0: P 40 + Q 20 named; placeholder 20 at P's band (= P alone in that band → P's rate);
  --     unassigned Paid Media 20 at avg(P,Q); Programmatic 30 at R; Creative 100 at T
  (40 * p0 + 20 * q0 + 20 * band_rate('Paid Media', p_band, n0)
   + 20 * band_rate('Paid Media', null, n0) + 30 * r0 + 100 * t0)::bigint as labor0,
  (40 * p1 + 60 * band_rate('Paid Media', null, n1) + 30 * r1 + 100 * t1)::bigint as labor1,
  230::numeric as hours0, 220::numeric as hours1,
  8830000::bigint as gp0, 7050000::bigint as gp1,
  228800::bigint as reb0, 215000::bigint as reb1
from _r, _fx;

-- lifecycle: propose, then a stranger (refused for WHO they are, not for the
-- status), then the approver; hours_page; save refused; un-approve
create temp table _st  as select set_scope_status((select id from _s), 'proposed', 'seller@fx097') as r;
create temp table _ap1 as select approve_scope((select id from _s), 'stranger@fx097') as r;
create temp table _ap2 as select approve_scope((select id from _s), 'boss@fx097') as r;
create temp table _asg as
select staff_id, deal_id, scope_id, month, hours, set_by from assignments where scope_id = (select id from _s);
create temp table _hp as
select hp from hours_page((select n0 from _fx), (select n1 from _fx)) hp;
create temp table _v_after as select scope_verdict((select id from _s)) as v;
create temp table _sv2 as select save_scope(((select p from _page) - 'econ' - 'labor' - 'staffing' - 'verdict' - 'versions' - 'siblings' - 'staff' - 'departments' - 'clients' - 'settings' - 'sources'), 'seller@fx097', 'should be refused') as r;
create temp table _un  as select unapprove_scope((select id from _s), 'boss@fx097') as r;
create temp table _asg2 as select count(*) as n from assignments where scope_id = (select id from _s);

-- auto-staff (scope is proposed again — editable)
create temp table _auto as select auto_staff_scope((select id from _s), 'seller@fx097') as r;
create temp table _auto_rows as
select staff_id, month, hours from scope_staff_months where scope_id = (select id from _s) and source = 'auto';

-- versions: re-save the latest payload and compare the money
create temp table _vers as select * from scope_versions where scope_id = (select id from _s);
create temp table _resave as
select save_scope((select payload from _vers order by version desc limit 1), 'seller@fx097', 'resave') as r;
create temp table _months2 as
select m.* from scope_months((select id from _s)) m;

create temp table _qc as
select quick_check('search', 10000000, 10, 3, '{"Paid Media": 30}'::jsonb) as q;

with r(n, result) as (
  select 1, case when line_fee(5000000, 0, '{"fee":{"mode":"marginal","bands":[{"upto":5000000,"pct":15},{"upto":15000000,"pct":12},{"upto":null,"pct":10}]}}') = 750000
                  and line_fee(12000000, 0, '{"fee":{"mode":"marginal","bands":[{"upto":5000000,"pct":15},{"upto":15000000,"pct":12},{"upto":null,"pct":10}]}}') = 1590000
                  and line_fee(5000000, 0, '{"fee":{"mode":"whole","bands":[{"upto":5000000,"pct":15},{"upto":15000000,"pct":12},{"upto":null,"pct":10}]}}') = 750000
                  and line_fee(5000001, 0, '{"fee":{"mode":"whole","bands":[{"upto":5000000,"pct":15},{"upto":15000000,"pct":12},{"upto":null,"pct":10}]}}') = 600000.12
                  and line_fee(2000000, 0, '{"fee":{"mode":"marginal","bands":[{"upto":5000000,"pct":15},{"upto":null,"pct":10}]},"fee_min":500000}') = 500000
                  and line_fee(20000000, 0, '{"fee":{"mode":"marginal","bands":[{"upto":5000000,"pct":15},{"upto":null,"pct":10}]},"fee_min":500000,"fee_cap":2000000}') = 2000000
                  and line_fee(12345, 12.5, '{}') = 1543.125 and round(line_fee(12345, 10, '{}')) = 1235
                  and round(line_fee(12345, 12.5, null)) = round(12345 * 12.5 / 100)
                  and prog_suggest_margin(5, 40) = 37.000
    then '1. PRIMITIVES marginal 7,500 / 15,900; whole boundary 7,500 then 6,000.0012; min 5,000; cap 20,000; flat half-cents; suggest 37%: PASS'
    else '1. PRIMITIVES: FAIL — ' || line_fee(5000001, 0, '{"fee":{"mode":"whole","bands":[{"upto":5000000,"pct":15},{"upto":15000000,"pct":12},{"upto":null,"pct":10}]}}')::text
         || ' / ' || line_fee(12000000, 0, '{"fee":{"mode":"marginal","bands":[{"upto":5000000,"pct":15},{"upto":15000000,"pct":12},{"upto":null,"pct":10}]}}')::text
         || ' / ' || prog_suggest_margin(5, 40)::text end
  union all
  select 2, case when (select r ->> 'ok' from _sv) = 'true'
                  and (select gp || '|' || billable || '|' || pass_through || '|' || rebate from _months where kind = 'search' and month = (select n0 from _fx)) = '1590000|1590000|0|0'
                  and (select gp from _months where kind = 'search' and month = (select n1 from _fx)) = 500000
                  and (select gp || '|' || billable || '|' || pass_through || '|' || rebate from _months where kind = 'social' and month = (select n0 from _fx)) = '1440000|1440000|12000000|28800'
                  and (select gp || '|' || rebate from _months where kind = 'social' and month = (select n1 from _fx)) = '750000|15000'
                  and (select gp || '|' || billable || '|' || rebate from _months where kind = 'programmatic' and label is null and budget = 10000000 and month = (select n0 from _fx)) = '3500000|10500000|200000'
                  and (select gp || '|' || billable || '|' || rebate from _months where kind = 'programmatic' and budget = 1000000 and month = (select n0 from _fx)) = '500000|1000000|0'
                  and (select gp from _months where kind = 'hourly' and month = (select n0 from _fx)) = 800000
                  and (select gp from _months where kind = 'retainer' and month = (select n1 from _fx)) = 1000000
                  and (select sum(gp) from _months where month = (select n0 from _fx)) = (select gp0 from _want)
                  and (select sum(rebate) from _months where month = (select n1 from _fx)) = (select reb1 from _want)
    then '2. MONTHS every line to the cent; n0 gp 8,830,000c, n1 rebate 215,000c: PASS'
    else '2. MONTHS: FAIL — save ' || coalesce((select r::text from _sv), 'null') || ' rows: ' ||
         coalesce((select string_agg(kind || ' ' || month || ' gp ' || gp || ' bill ' || billable || ' pass ' || pass_through || ' reb ' || rebate, '; ' order by month, kind, budget) from _months), 'none') end
  union all
  select 3, case when (select cost from _labor where month = (select n0 from _fx)) = (select labor0 from _want)
                  and (select cost from _labor where month = (select n1 from _fx)) = (select labor1 from _want)
                  and (select hours from _labor where month = (select n0 from _fx)) = 230
                  and (select hours from _labor where month = (select n1 from _fx)) = 230
                  and (select named_hours = 60 and placeholder_hours = 20 and unassigned_hours = 150 from _labor where month = (select n0 from _fx))
                  and (select named_hours = 40 and placeholder_hours = 0 and unassigned_hours = 190 from _labor where month = (select n1 from _fx))
                  and (select unpriced_hours from _labor where month = (select n0 from _fx)) = 0
                  and position('"rate"' in (select (p -> 'labor')::text || (p -> 'staff_months')::text || (p -> 'staffing')::text || (p -> 'staff')::text from _page)) = 0
                  and position('staff_hourly' in (select p::text from _page)) = 0
    then '3. LABOR n0 ' || (select labor0 from _want)::text || 'c / n1 ' || (select labor1 from _want)::text || 'c; 230 h/mo = named + placeholder + unassigned (60/20/150 then 40/0/190); no per-person cost in the payload: PASS'
    else '3. LABOR: FAIL — ' || coalesce((select string_agg(month || ' cost ' || cost || ' h ' || hours || ' n/p/u ' || named_hours || '/' || placeholder_hours || '/' || unassigned_hours || ' unpriced ' || unpriced_hours, '; ' order by month) from _labor), 'none')
         || ' want ' || (select labor0 from _want)::text || ' / ' || (select labor1 from _want)::text end
  union all
  select 4, case when ((select v from _v) -> 'total' ->> 'pal')::bigint = (select gp0 + gp1 - reb0 - reb1 - labor0 - labor1 from _want)
                  and ((select v from _v) -> 'total' ->> 'per_hour_c')::bigint = round((select gp0 + gp1 - reb0 - reb1 - labor0 - labor1 from _want) / 460.0)
                  and ((select v from _v) ->> 'status') = 'go'
                  and ((select v from _v) -> 'checks' ->> 'staff_unclear')::boolean = true
                  and ((select v from _v) -> 'hire' ->> 'recommend')::boolean = true
                  and ((select v from _v) -> 'hire' ->> 'cost_hire')::bigint = round(((select v from _v) -> 'hire' ->> 'hours')::numeric * 5000)
                  and ((select v from _v) -> 'hire' ->> 'cost_contractor')::bigint = round(((select v from _v) -> 'hire' ->> 'hours')::numeric * 9000)
                  and ((select v from _v) -> 'hire' ->> 'hours')::numeric > 180
    then '4. VERDICT pal = gp − rebate − labor = ' || ((select v from _v) -> 'total' ->> 'pal') || 'c, ' || ((select v from _v) -> 'total' ->> 'per_hour_c') || 'c/h, go, staff plan unclear, Creative hire recommended (' || ((select v from _v) -> 'hire' ->> 'hours') || 'h at $50 / $90): PASS'
    else '4. VERDICT: FAIL — total ' || coalesce(((select v from _v) -> 'total')::text, 'null') || ' status ' || coalesce((select v ->> 'status' from _v), 'null')
         || ' hire ' || coalesce(((select v from _v) -> 'hire')::text, 'null') || ' want pal ' || (select gp0 + gp1 - reb0 - reb1 - labor0 - labor1 from _want)::text end
  union all
  select 5, case when (select count(*) from jsonb_array_elements((select v from _v) -> 'capacity') c
                       where c ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-0000000000b7' and (c ->> 'month')::date = (select n1 from _fx)
                         and (c ->> 'committed_other')::numeric = 20 and (c ->> 'scope_hours')::numeric = 40
                         and (c ->> 'free_after')::numeric = (c ->> 'capacity_hours')::numeric - 60
                         and (c ->> 'over')::boolean = false) = 1
                  -- after approve, the scope's own reservation must not count as "other"
                  and (select count(*) from jsonb_array_elements((select v from _v_after) -> 'capacity') c
                       where c ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-0000000000b7' and (c ->> 'month')::date = (select n1 from _fx)
                         and (c ->> 'committed_other')::numeric = 20) = 1
    then '5. CAPACITY P next month: committed_other 20 (D0), scope 40, free = capacity − 60, unchanged after approve: PASS'
    else '5. CAPACITY: FAIL — ' || coalesce((select string_agg(c::text, '; ') from jsonb_array_elements((select v from _v) -> 'capacity') c
                       where c ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-0000000000b7'), 'no rows')
         || ' after: ' || coalesce((select string_agg(c ->> 'committed_other', ',') from jsonb_array_elements((select v from _v_after) -> 'capacity') c
                       where c ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-0000000000b7'), 'no rows') end
  union all
  select 6, case when (select count(*) from jsonb_array_elements((select v from _v) -> 'client') c
                       where (c ->> 'month')::date = (select n1 from _fx)
                         and (c ->> 'gp_existing')::bigint = 1000000
                         and (c ->> 'labor_existing')::bigint = round(20 * (select p1 from _r))
                         and (c ->> 'pal_combined')::bigint = 1000000 - round(20 * (select p1 from _r)) + (select gp1 - reb1 - labor1 from _want)) = 1
    then '6. CLIENT roll-up n1: existing $10,000 gp − 20h × P + this scope''s pal: PASS'
    else '6. CLIENT: FAIL — ' || coalesce((select string_agg(c::text, '; ') from jsonb_array_elements((select v from _v) -> 'client') c), 'no rows') end
  union all
  select 7, case when (select r ->> 'ok' from _ap1) = 'false' and (select r ->> 'reason' from _ap1) like 'only an approver%'
                  and (select r ->> 'ok' from _ap2) = 'true'
                  and (select count(*) from _asg) = 3
                  and (select bool_and(deal_id is null and scope_id is not null and set_by = 'scope:approve') from _asg)
                  and (select sum(hours) from _asg where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000b7') = 80
                  and (select (x ->> 'planned_hours')::numeric from _hp, jsonb_array_elements(hp -> 'staff_planned') x
                       where x ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-0000000000b7') = 100
                  and (select sum((x ->> 'planned_hours')::numeric) from _hp, jsonb_array_elements(hp -> 'staff_deal_planned') x
                       where x ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-0000000000b7') = 20
                  and (select r ->> 'ok' from _sv2) = 'false'
                  and (select r ->> 'ok' from _un) = 'true'
                  and (select n from _asg2) = 0
    then '7. LIFECYCLE stranger refused; approve → 3 reservations (P 80h, Q 20h), hours_page planned 100 / per-deal 20; save refused; un-approve clears: PASS'
    else '7. LIFECYCLE: FAIL — ap1 ' || coalesce((select r::text from _ap1), 'null') || ' ap2 ' || coalesce((select r::text from _ap2), 'null')
         || ' rows ' || (select count(*) from _asg)::text || ' save2 ' || coalesce((select r::text from _sv2), 'null')
         || ' un ' || coalesce((select r::text from _un), 'null') || ' left ' || (select n from _asg2)::text
         || ' hp ' || coalesce((select string_agg(x::text, ',') from _hp, jsonb_array_elements(hp -> 'staff_planned') x), 'none') end
  union all
  select 8, case when (select r ->> 'ok' from _auto) = 'true'
                  and (select hours from _auto_rows where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000b7' and month = (select n0 from _fx)) = 20
                  and (select hours from _auto_rows where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000b7' and month = (select n1 from _fx)) = 60
                  and not exists (select 1 from _auto_rows where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000c7')
                  and (select hours from _auto_rows where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000d7' and month = (select n0 from _fx)) = 30
                  and (select hours from _auto_rows where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000e7' and month = (select n0 from _fx)) < 5
    then '8. AUTO-STAFF Paid Media: P alone (worked this client) takes 20h n0 + 60h n1, Q untouched; R covers Programmatic; T only what 1 h/wk frees: PASS'
    else '8. AUTO-STAFF: FAIL — ' || coalesce((select r::text from _auto), 'null') || ' rows: '
         || coalesce((select string_agg(staff_id::text || ' ' || month || ' ' || hours, '; ' order by month) from _auto_rows), 'none') end
  union all
  select 9, case when (select count(*) from _vers) = 3
                  and (select string_agg(version || ':' || reason, ',' order by version) from _vers) = '1:save,2:approve,3:unapprove'
                  and (select r ->> 'ok' from _resave) = 'true'
                  and (select count(*) from scope_versions where scope_id = (select id from _s)) = 4
                  and not exists (select 1 from _months a full join _months2 b using (kind, month, budget, amount)
                                  where a.gp is distinct from b.gp or a.billable is distinct from b.billable
                                     or a.rebate is distinct from b.rebate or a.pass_through is distinct from b.pass_through)
    then '9. VERSIONS 1:save 2:approve 3:unapprove, re-saving the latest payload makes 4 with identical money: PASS'
    else '9. VERSIONS: FAIL — ' || coalesce((select string_agg(version || ':' || reason, ',' order by version) from _vers), 'none')
         || ' resave ' || coalesce((select r::text from _resave), 'null') end
  union all
  select 10, case when ((select q from _qc) ->> 'gp_month')::bigint = 1000000
                   and ((select q from _qc) ->> 'labor_month')::bigint = round(30 * band_rate('Paid Media', null, (select n0 from _fx)))
                   and ((select q from _qc) ->> 'per_hour_c')::bigint = round((1000000 - round(30 * band_rate('Paid Media', null, (select n0 from _fx)))) / 30.0)
                   and ((select q from _qc) ->> 'status') = case when round((1000000 - round(30 * band_rate('Paid Media', null, (select n0 from _fx)))) / 30.0) >= 15000 then 'go' else 'no_go' end
    then '10. QUICK $100k search at 10%, 30h Paid Media: gp 1,000,000c, labor at the department average, status vs $150/h: PASS'
    else '10. QUICK: FAIL — ' || coalesce((select q::text from _qc), 'null') end
)
select result from r order by n;
rollback;
