-- Fixture test for 104 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-104 applied, then
-- re-run 097, 101 and 103's fixtures: all must still PASS.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
-- Target GP 40 % on revenue. A scope with two programmatic lines over one
-- month — $100,000 at a 5 % fee and $50,000 at a 10 % fee — plus a CPM line
-- (its own margin, excluded) and a line with an explicit margin_pct (kept).
--
--   1. MARGIN    — scope_prog_margin = (40·(100,000·1.05 + 50,000·1.10) − (100,000·5 + 50,000·10)) / 150,000
--                  = (40·160,000 − 1,000,000)/150,000 = 36.0 %; equals prog_suggest_margin for a lone line
--   2. MONTHS    — both lines price at 36 %: GP 100,000·0.41 + 50,000·0.46 = 41,000 + 23,000 = $64,000
--                  = 40 % of revenue $160,000; the CPM line and the explicit-margin line unchanged
--   3. PROMOTE   — deal_lines.margin_pct = 36.000 on both computed lines; the
--                  view's GP total equals scope_months' (handoff identity)
--   4. SETTINGS  — scope_page carries prog_margin and the department maps
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * scope_prog_margin: unweighted mean of per-line suggestions              -> row 1
--   * scope_months: fall through to programmatic_margin_default              -> row 2
--   * promote_scope_lines: write r.margin_pct as is                          -> row 3

begin;
create temp table _fx as select date_trunc('month', current_date)::date as cur, (date_trunc('month', current_date) + interval '1 month - 1 day')::date as cur_end;
insert into settings (key, value, set_by) values
  ('scope_prog_target_gp_pct', '40'::jsonb, 'fx104'), ('programmatic_margin_default', '35'::jsonb, 'fx104'),
  ('scope_approver_emails', '["boss@fx104"]'::jsonb, 'fx104')
on conflict (key) do update set value = excluded.value;
insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000104', '_fx104 Client', true);
create temp table _s as select ((save_scope(jsonb_build_object(
  'name', '_fx104', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000104',
  'deals', jsonb_build_array(jsonb_build_object('name', 'd', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', (select cur from _fx), 'flight_end', (select cur_end from _fx),
    'lines', jsonb_build_array(
      jsonb_build_object('ord', 0, 'kind', 'programmatic', 'fee_pct', 5, 'budget', 10000000),
      jsonb_build_object('ord', 1, 'kind', 'programmatic', 'fee_pct', 10, 'budget', 5000000),
      jsonb_build_object('ord', 2, 'kind', 'programmatic', 'fee_pct', 0, 'budget', 1000000, 'structure', jsonb_build_object('prog', jsonb_build_object('model', 'cpm', 'platform_share_pct', 50))),
      jsonb_build_object('ord', 3, 'kind', 'programmatic', 'label', 'explicit', 'fee_pct', 5, 'margin_pct', 20, 'budget', 2000000))))
), 'seller@fx104', null)) ->> 'scope_id')::uuid as id;
create temp table _m as select * from scope_months((select id from _s));
create temp table _pm as select scope_prog_margin((select id from _s)) as m;
create temp table _pg as select scope_page((select id from _s)) as p;
select set_scope_status((select id from _s), 'proposed', 'seller@fx104');
select approve_scope((select id from _s), 'boss@fx104');
create temp table _pr as select promote_scope((select id from _s), 'boss@fx104', '{}'::jsonb) as r;
create temp table _dl as select label, fee_pct, margin_pct from deal_lines where scope_id = (select id from _s);
create temp table _vd as select sum(gp) as gp from v_deal_month_forecast where deal_id = (select promoted_deal_id from scope_deals where scope_id = (select id from _s));

with r(n, result) as (
  select 1, case when (select m from _pm) = 36.000 and prog_suggest_margin(5, 40) = 37.000
    then '1. MARGIN budget-weighted deal margin 36.000 % (lone-line formula still 37 %): PASS'
    else '1. MARGIN: FAIL — ' || coalesce((select m::text from _pm), 'null') end
  union all
  select 2, case when (select gp from _m where budget = 10000000) = 4100000
                  and (select gp from _m where budget = 5000000) = 2300000
                  and (select gp from _m where budget = 1000000) = 500000
                  and (select gp from _m where budget = 2000000) = 500000
                  and (select sum(gp) from _m where budget in (10000000, 5000000)) * 100 = 40 * (select sum(billable) from _m where budget in (10000000, 5000000))
    then '2. MONTHS both lines at 36 %: 4,100,000 + 2,300,000 c = 40 % of revenue; CPM 500,000 c and the explicit 20 % line 500,000 c unchanged: PASS'
    else '2. MONTHS: FAIL — ' || coalesce((select string_agg(budget || ' gp ' || gp || ' bill ' || billable, '; ' order by budget) from _m), 'none') end
  union all
  select 3, case when (select r ->> 'ok' from _pr) = 'true'
                  and (select count(*) from _dl where margin_pct = 36.000 and fee_pct in (5, 10) and label is null) = 2
                  and (select margin_pct from _dl where label = 'explicit') = 20.000
                  and (select margin_pct from _dl where fee_pct = 0) = 50.000
                  and (select gp from _vd) = (select sum(gp) from _m)
    then '3. PROMOTE margin 36.000 written on the two computed lines, explicit 20 and CPM 50 kept; view GP = scope GP: PASS'
    else '3. PROMOTE: FAIL — ' || coalesce((select string_agg(coalesce(label, '-') || ' f' || fee_pct || ' m' || coalesce(margin_pct::text, 'null'), '; ') from _dl), 'none')
         || ' view ' || coalesce((select gp::text from _vd), 'null') || ' scope ' || (select sum(gp) from _m)::text end
  union all
  select 4, case when ((select p from _pg) ->> 'prog_margin')::numeric = 36.000
                  and jsonb_typeof((select p from _pg) -> 'settings' -> 'kind_departments') = 'object'
                  and jsonb_typeof((select p from _pg) -> 'settings' -> 'always_departments') = 'array'
    then '4. SETTINGS scope_page carries prog_margin 36 and the department maps: PASS'
    else '4. SETTINGS: FAIL — ' || coalesce((select p ->> 'prog_margin' from _pg), 'null') end
)
select result from r order by n;
rollback;
