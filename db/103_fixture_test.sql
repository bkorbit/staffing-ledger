-- Fixture test for 103 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-103 applied, then
-- re-run 097, 101 and 102's fixtures: all must still PASS.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
-- One client with a live retainer deal D0 ($5,000/mo, P planned 10 h this
-- month) and a scope for the same client: a flat 10 % search line on
-- $100,000/mo and a $10,000 retainer, P named 40 h/mo against 60 h of Paid
-- Media demand (20 h unassigned at the department average = P's rate).
--
--   1. REBATE media  — scope-level 2 % of media: search 200,000 c/mo, retainer 0
--   2. REBATE fee    — switched to 2 % of fees: 20,000 + 20,000 c/mo
--   3. MINIMUM       — min_fee = round(labor ÷ 0.85) at Slight margin, = labor
--                      at Break even; fee = 2,000,000 c; min_fee_max, shortfall 0
--   4. QUEUE         — propose stamps proposed_by/at; approvals_queue lists the
--                      scope with its verdict status; back to draft clears it
--   5. EXISTING      — D0 appears with gp_plan 1,000,000 c (two forward months
--                      in the window), labor_plan 10 h × P's rate, hours_plan 10
--   6. PROMOTE       — the promoted deal's lines carry rebate 2 % media on the
--                      search line only; v_deal_month_forecast rebate total =
--                      scope_months rebate total
--   7. TERMS         — one scope-level rebate sentence, the minimum monthly fee
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * scope_months: apply the fee-basis rebate to media lines only         -> row 2
--     (the media-basis kind guard is belt-and-braces: a non-media line has
--      budget 0, so line_rebate already yields 0 for it)
--   * scope_verdict: min_fee = labor (no division)                      -> row 3
--   * approvals_queue: drop "status = 'proposed'"                        -> row 4
--   * promote_scope_lines: ignore the scope rebate                       -> row 6

begin;
create temp table _fx as
select date_trunc('month', current_date)::date as cur,
       (date_trunc('month', current_date) - interval '1 month')::date as m1,
       (date_trunc('month', current_date) + interval '1 month')::date as n1;
insert into settings (key, value, set_by) values
  ('scope_approver_emails', '["boss@fx103"]'::jsonb, 'fx103'),
  ('scope_min_margin_presets', '[{"name":"Break even","pct":0},{"name":"Slight margin","pct":15},{"name":"Target","pct":35}]'::jsonb, 'fx103'),
  ('scope_target_profit_per_hour', '150'::jsonb, 'fx103')
on conflict (key) do update set value = excluded.value;
update settings set value = value || '{"rebate_media_deal":"EMG rebates {{pct}}% of media spend to the client, invoiced by the client.","rebate_fee_deal":"EMG rebates {{pct}}% of all fees to the client, invoiced by the client.","min_fee_deal":"Minimum monthly fee {{amount}}."}'::jsonb
where key = 'scope_terms_templates';

insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000103', '_fx103 Client', true);
insert into staff (id, name, department, active, tracks_capacity) values ('f0f0f0f0-0000-0000-0000-000000000b03', '_fx103 P', 'Paid Media', true, true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-000000000b03'::uuid, (m1 - 400)::date, 'hourly'::comp_kind, 5000, 40 from _fx;
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-000000000d03'::uuid, 'f0f0f0f0-0000-0000-0000-000000000103'::uuid, '_fx103 D0', 'active'::deal_status, 'manual'::deal_origin, m1, (n1 + 27)::date from _fx;
insert into deal_lines (deal_id, kind, amount, billing_day) values ('f0f0f0f0-0000-0000-0000-000000000d03', 'retainer', 500000, 'first');
insert into assignments (staff_id, deal_id, month, hours, set_by)
select 'f0f0f0f0-0000-0000-0000-000000000b03'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d03'::uuid, cur, 10, 'human@fx103' from _fx;
create temp table _r as select staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b03', cur) as p0, staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b03', n1) as p1 from _fx;

create temp table _s as select ((save_scope(jsonb_build_object(
  'name', '_fx103 scope', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000103',
  'rebate_pct', 2, 'rebate_basis', 'media', 'min_margin_preset', 'Slight margin',
  'deals', jsonb_build_array(jsonb_build_object('name', '_fx103 deal', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', (select cur from _fx), 'flight_end', (select (n1 + 27)::date from _fx),
    'lines', jsonb_build_array(
      jsonb_build_object('ord', 0, 'kind', 'search', 'fee_pct', 10, 'budget', 10000000),
      jsonb_build_object('ord', 1, 'kind', 'retainer', 'amount', 1000000)))),
  'dept_months', jsonb_build_array(
    jsonb_build_object('department', 'Paid Media', 'month', (select cur from _fx), 'hours', 60),
    jsonb_build_object('department', 'Paid Media', 'month', (select n1 from _fx), 'hours', 60)),
  'staff_months', jsonb_build_array(
    jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-000000000b03', 'department', 'Paid Media', 'month', (select cur from _fx), 'hours', 40),
    jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-000000000b03', 'department', 'Paid Media', 'month', (select n1 from _fx), 'hours', 40))
), 'seller@fx103', null)) ->> 'scope_id')::uuid as id;

create temp table _m1 as select kind, month, rebate, fee, gp from scope_months((select id from _s));
create temp table _v1 as select scope_verdict((select id from _s)) as v;
create temp table _pg as select scope_page((select id from _s)) as p;
-- fee basis
select save_scope((select p from _pg) - 'econ' - 'labor' - 'staffing' - 'verdict' - 'versions' - 'siblings' - 'staff' - 'departments' - 'clients' - 'settings' - 'sources' - 'existing_deals'
                  || '{"rebate_basis":"fee"}'::jsonb, 'seller@fx103', 'fee basis');
create temp table _m2 as select kind, month, rebate from scope_months((select id from _s));
-- break even
select save_scope((select p from _pg) - 'econ' - 'labor' - 'staffing' - 'verdict' - 'versions' - 'siblings' - 'staff' - 'departments' - 'clients' - 'settings' - 'sources' - 'existing_deals'
                  || '{"rebate_basis":"media","min_margin_preset":"Break even"}'::jsonb, 'seller@fx103', 'break even');
create temp table _v2 as select scope_verdict((select id from _s)) as v;
-- back to slight margin for the rest
select save_scope((select p from _pg) - 'econ' - 'labor' - 'staffing' - 'verdict' - 'versions' - 'siblings' - 'staff' - 'departments' - 'clients' - 'settings' - 'sources' - 'existing_deals', 'seller@fx103', 'back');

create temp table _labor as select month, cost from scope_labor((select id from _s));
select set_scope_status((select id from _s), 'proposed', 'seller@fx103');
create temp table _q as select approvals_queue() as q;
create temp table _prop as select proposed_by, proposed_at from scopes where id = (select id from _s);
select set_scope_status((select id from _s), 'draft', 'seller@fx103');
create temp table _q2 as select approvals_queue() as q;
create temp table _prop2 as select proposed_by, proposed_at from scopes where id = (select id from _s);
create temp table _ex as select scope_existing_deals((select id from _s)) as e;
create temp table _t as select scope_terms((select id from _s)) as t;

select set_scope_status((select id from _s), 'proposed', 'seller@fx103');
select approve_scope((select id from _s), 'boss@fx103');
create temp table _pr as select promote_scope((select id from _s), 'boss@fx103', '{}'::jsonb) as r;
create temp table _dl as select kind, rebate_pct, rebate_basis from deal_lines where scope_id = (select id from _s);
create temp table _vd as select sum(rebate) as rebate from v_deal_month_forecast where deal_id = (select promoted_deal_id from scope_deals where scope_id = (select id from _s));

with r(n, result) as (
  select 1, case when (select rebate from _m1 where kind = 'search' and month = (select cur from _fx)) = 200000
                  and (select rebate from _m1 where kind = 'retainer' and month = (select cur from _fx)) = 0
                  and (select fee from _m1 where kind = 'search' and month = (select cur from _fx)) = 1000000
    then '1. REBATE media 2%: search 200,000c, retainer 0: PASS'
    else '1. REBATE media: FAIL — ' || coalesce((select string_agg(kind || ' ' || rebate, '; ') from _m1 where month = (select cur from _fx)), 'none') end
  union all
  select 2, case when (select rebate from _m2 where kind = 'search' and month = (select cur from _fx)) = 20000
                  and (select rebate from _m2 where kind = 'retainer' and month = (select cur from _fx)) = 20000
    then '2. REBATE fee 2%: search 20,000c, retainer 20,000c: PASS'
    else '2. REBATE fee: FAIL — ' || coalesce((select string_agg(kind || ' ' || rebate, '; ') from _m2 where month = (select cur from _fx)), 'none') end
  union all
  select 3, case when (select (x ->> 'min_fee')::bigint from _v1, jsonb_array_elements(v -> 'months') x where (x ->> 'month')::date = (select cur from _fx))
                     = round((select cost from _labor where month = (select cur from _fx)) / 0.85)
                  and (select (x ->> 'min_fee')::bigint from _v2, jsonb_array_elements(v -> 'months') x where (x ->> 'month')::date = (select cur from _fx))
                     = (select cost from _labor where month = (select cur from _fx))
                  and (select (x ->> 'fee')::bigint from _v1, jsonb_array_elements(v -> 'months') x where (x ->> 'month')::date = (select cur from _fx)) = 2000000
                  and (select (v -> 'total' ->> 'min_fee_max')::bigint from _v1) = (select max(round(cost / 0.85)) from _labor)
                  and (select (v -> 'total' ->> 'fee_shortfall')::bigint from _v1) = 0
                  and (select v -> 'targets' ->> 'min_margin_preset' from _v1) = 'Slight margin'
                  and (select cost from _labor where month = (select cur from _fx)) = 60 * (select p0 from _r)
    then '3. MINIMUM labor ÷ 0.85 at Slight margin, = labor at Break even; fee 2,000,000c; min_fee_max; no shortfall: PASS'
    else '3. MINIMUM: FAIL — v1 ' || coalesce((select string_agg(x ->> 'month' || ' fee ' || (x ->> 'fee') || ' min ' || coalesce(x ->> 'min_fee', 'null'), '; ') from _v1, jsonb_array_elements(v -> 'months') x), 'none')
         || ' labor ' || coalesce((select string_agg(month || ' ' || cost, '; ') from _labor), 'none') end
  union all
  select 4, case when (select proposed_by from _prop) = 'seller@fx103' and (select proposed_at from _prop) is not null
                  and (select count(*) from _q, jsonb_array_elements(q) x where x ->> 'id' = (select id::text from _s)) = 1
                  and (select x -> 'kpis' ->> 'status' from _q, jsonb_array_elements(q) x where x ->> 'id' = (select id::text from _s)) is not null
                  and (select x ->> 'client_name' from _q, jsonb_array_elements(q) x where x ->> 'id' = (select id::text from _s)) = '_fx103 Client'
                  and (select count(*) from _q2, jsonb_array_elements(q) x where x ->> 'id' = (select id::text from _s)) = 0
                  and (select proposed_by from _prop2) is null
    then '4. QUEUE proposed_by stamped, queue lists it with a verdict, back to draft clears: PASS'
    else '4. QUEUE: FAIL — ' || coalesce((select proposed_by from _prop), 'null') || ' queue1 ' || (select jsonb_array_length(q) from _q)::text || ' queue2 ' || (select jsonb_array_length(q) from _q2)::text end
  union all
  select 5, case when (select count(*) from _ex, jsonb_array_elements(e) x) = 1
                  and (select (x ->> 'gp_plan')::bigint from _ex, jsonb_array_elements(e) x) = 1000000
                  and (select (x ->> 'labor_plan')::bigint from _ex, jsonb_array_elements(e) x) = round(10 * (select p0 from _r))
                  and (select (x ->> 'hours_plan')::numeric from _ex, jsonb_array_elements(e) x) = 10
                  and (select (x ->> 'gp_measured')::bigint from _ex, jsonb_array_elements(e) x) = 0
    then '5. EXISTING D0 in the window: gp_plan 1,000,000c, labor_plan 10h × P, nothing measured yet: PASS'
    else '5. EXISTING: FAIL — ' || (select e::text from _ex) end
  union all
  select 6, case when (select r ->> 'ok' from _pr) = 'true'
                  and (select rebate_pct || '|' || rebate_basis from _dl where kind = 'search') = '2.000|media'
                  and (select rebate_pct is null and rebate_basis is null from _dl where kind = 'retainer')
                  and (select rebate from _vd) = (select sum(rebate) from _m1)
    then '6. PROMOTE search line carries 2% media, retainer none; view rebate total = scope: PASS'
    else '6. PROMOTE: FAIL — ' || coalesce((select r::text from _pr), 'null') || ' lines ' || coalesce((select string_agg(kind || ' ' || coalesce(rebate_pct::text, 'null') || '/' || coalesce(rebate_basis, 'null'), '; ') from _dl), 'none')
         || ' view ' || coalesce((select rebate::text from _vd), 'null') || ' scope ' || (select sum(rebate) from _m1)::text end
  union all
  select 7, case when (select t ->> 'text' from _t) like '%EMG rebates 2% of media spend to the client, invoiced by the client.%'
                  and (select count(*) from _t, jsonb_array_elements(t -> 'sections') x where x ->> 'key' = 'rebate') = 1
                  and (select t ->> 'text' from _t) like '%Minimum monthly fee ' || fmt_money((select (v -> 'total' ->> 'min_fee_max')::bigint from _v1)) || '.%'
                  and (select t ->> 'text' from _t) not like '%paid search media spend%'
    then '7. TERMS one scope-level rebate sentence, the minimum monthly fee from the highest month: PASS'
    else '7. TERMS: FAIL — ' || (select t ->> 'text' from _t) end
)
select result from r order by n;
rollback;
