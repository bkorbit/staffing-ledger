-- Fixture test for 106 — NOT a migration, do not ship this file.
-- Run with 001-106 applied, then re-run 097, 101, 103, 104 and 105's fixtures:
-- every one must still PASS to the cent (they price the same scopes through
-- the rewritten functions).
--   1. paste this whole file (it opens its own transaction)
--   2. read the SINGLE result set — every line must say PASS
--   3. it ends in ROLLBACK
--
--   1. MEMO     — staff_rates_months answers the same cold (no cache) and warm
--                 (filled); the fill covers exactly the plannable person-months;
--                 a second fill writes nothing
--   2. TWIN     — scope_page's verdict is scope_verdict's; cached_hourly_cost is
--                 staff_hourly_cost with or without a memo row; the verdict does
--                 not move when the memo is emptied
--   3. STALE    — a comp change drops that person's memo rows (the next read
--                 shows the new rate); a burden setting empties the memo; an
--                 unrelated setting leaves it alone
--   4. HISTORY  — a future-only window skips project_detail / client_detail and
--                 shows 0 measured; a window reaching a closed month prices the
--                 counted hours exactly as project_detail does, on both the
--                 existing-deals panel and the verdict's client roll-up
--   5. DELETE   — a draft goes by anyone with everything under it; an approved
--                 scope refuses a stranger, goes for an approver and takes its
--                 reserved hours with it; a promoted scope never goes
--   6. ACT      — scope_act saves and returns the fresh page in one call;
--                 an unknown action is refused; delete returns no page
--   7. LIST     — scoping_list carries every key the list view reads
--   8. QUICK    — quick_check prices typed hours at band_rate(dept, null)
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * staff_rates_months: cold fallback returns null instead of the live rate  -> row 1
--   * staff_rate_cache_invalidate: ignore settings                              -> row 3
--   * scope_existing_deals: measured side only when the window is FUTURE (>)   -> row 4
--   * scope_verdict_calc: never consult client_detail                          -> row 4
--   * delete_scope: allow a promoted scope                                      -> row 5

begin;
create temp table _fx as select date_trunc('month', current_date)::date as cur,
  (date_trunc('month', current_date) + interval '1 month')::date as n1,
  (date_trunc('month', current_date) - interval '1 month')::date as p1;
insert into settings (key, value, set_by) values
  ('scope_comp_bands', '[{"name":"Band 1","upto_c":4500},{"name":"Band 2","upto_c":7500},{"name":"Band 3","upto_c":11500},{"name":"Band 4","upto_c":null}]'::jsonb, 'fx106'),
  ('scope_approver_emails', '["fx106@x"]'::jsonb, 'fx106')
on conflict (key) do update set value = excluded.value;
insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000106', '_fx106 Client', true);
insert into staff (id, name, department, active, tracks_capacity) values
  ('f0f0f0f0-0000-0000-0000-000000000b06', '_fx106 P', 'Paid Media', true, true),
  ('f0f0f0f0-0000-0000-0000-000000000c06', '_fx106 Q', 'Paid Media', true, true),
  ('f0f0f0f0-0000-0000-0000-000000000d06', '_fx106 R inactive', 'Paid Media', false, true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-000000000b06'::uuid, (cur - 400)::date, 'hourly'::comp_kind, 5000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000c06'::uuid, (cur - 400)::date, 'hourly'::comp_kind, 8000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000d06'::uuid, (cur - 400)::date, 'hourly'::comp_kind, 9000, 40 from _fx;
-- the client's live deal: a $1,000 retainer from last month, 15 counted hours
-- last month, 10 planned hours this month
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-00000000dd06', 'f0f0f0f0-0000-0000-0000-000000000106', '_fx106 Old', 'active', 'manual', p1, (n1 + interval '3 month')::date from _fx;
insert into deal_lines (deal_id, kind, amount, billing_day) values ('f0f0f0f0-0000-0000-0000-00000000dd06', 'retainer', 100000, 'first');
insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, attribution)
select '_fx106_te1', 'f0f0f0f0-0000-0000-0000-000000000b06', 'f0f0f0f0-0000-0000-0000-00000000dd06', 'f0f0f0f0-0000-0000-0000-000000000106', (p1 + 5)::date, 15, 'deal' from _fx;
insert into assignments (staff_id, deal_id, month, hours, set_by)
select 'f0f0f0f0-0000-0000-0000-000000000b06', 'f0f0f0f0-0000-0000-0000-00000000dd06', cur, 10, 'fx106' from _fx;

-- payload maker: a one-retainer deal over [f0, f1] with Paid Media demand and P named
create temp table _mk as
select jsonb_build_object('name', '_fx106 A', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000106',
  'deals', jsonb_build_array(jsonb_build_object('name', 'd', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', cur, 'flight_end', (n1 + 27)::date, 'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 100)))),
  'dept_months', jsonb_build_array(jsonb_build_object('department', 'Paid Media', 'month', cur, 'hours', 30)),
  'staff_months', jsonb_build_array(jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-000000000b06', 'department', 'Paid Media', 'month', cur, 'hours', 10))) as pa,
 jsonb_build_object('name', '_fx106 B', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000106',
  'deals', jsonb_build_array(jsonb_build_object('name', 'd', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', p1, 'flight_end', (cur + 27)::date, 'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 100)))),
  'dept_months', jsonb_build_array(jsonb_build_object('department', 'Paid Media', 'month', p1, 'hours', 10), jsonb_build_object('department', 'Paid Media', 'month', cur, 'hours', 10)),
  'staff_months', jsonb_build_array(jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-000000000b06', 'department', 'Paid Media', 'month', p1, 'hours', 10))) as pb
from _fx;
create temp table _s as select
  ((save_scope((select pa from _mk), 'fx106', null)) ->> 'scope_id')::uuid as a,
  ((save_scope((select pb from _mk), 'fx106', null)) ->> 'scope_id')::uuid as b,
  ((save_scope((select pa from _mk) || '{"name":"_fx106 C"}', 'fx106', null)) ->> 'scope_id')::uuid as c,
  ((save_scope((select pa from _mk) || '{"name":"_fx106 D"}', 'fx106', null)) ->> 'scope_id')::uuid as d;

-- 1. MEMO: cold, fill, warm
delete from staff_rate_cache;
create temp table _cold as select r.*, staff_hourly_cost(r.staff_id, r.month) as live from staff_rates_months((select cur from _fx), (select n1 from _fx)) r where r.staff_id::text like 'f0f0f0f0-0000-0000-0000-000000000_06';
create temp table _fill1 as select staff_rate_cache_fill((select cur from _fx), (select n1 from _fx)) as n;
create temp table _warm as select r.*, staff_hourly_cost(r.staff_id, r.month) as live from staff_rates_months((select cur from _fx), (select n1 from _fx)) r where r.staff_id::text like 'f0f0f0f0-0000-0000-0000-000000000_06';
create temp table _fill2 as select staff_rate_cache_fill((select cur from _fx), (select n1 from _fx)) as n;
create temp table _cache1 as select staff_id, month, rate from staff_rate_cache where staff_id::text like 'f0f0f0f0-0000-0000-0000-000000000_06';

-- 2. TWIN
create temp table _pgA as select scope_page((select a from _s)) as j;
create temp table _vA as select scope_verdict((select a from _s)) as j;
create temp table _chc1 as select cached_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b06', cur) as c, staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b06', cur) as h from _fx;
delete from staff_rate_cache where staff_id = 'f0f0f0f0-0000-0000-0000-000000000b06';
create temp table _chc2 as select cached_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b06', cur) as c, staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b06', cur) as h from _fx;
create temp table _vA2 as select scope_verdict((select a from _s)) as j;

-- 3. STALE
select staff_rate_cache_fill((select cur from _fx), (select n1 from _fx));
update comp_periods set hourly_cost = 5500 where staff_id = 'f0f0f0f0-0000-0000-0000-000000000b06';
create temp table _afterComp as select
  (select count(*) from staff_rate_cache where staff_id = 'f0f0f0f0-0000-0000-0000-000000000b06') as p_rows,
  (select count(*) from staff_rate_cache where staff_id = 'f0f0f0f0-0000-0000-0000-000000000c06') as q_rows,
  cached_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b06', (select cur from _fx)) as p_cached,
  staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b06', (select cur from _fx)) as p_live,
  (select rate from _warm where staff_id = 'f0f0f0f0-0000-0000-0000-000000000b06' and month = (select cur from _fx)) as p_before;
select staff_rate_cache_fill((select cur from _fx), (select n1 from _fx));
insert into settings (key, value, set_by) values ('fica_ss_rate', to_jsonb('6.2'::text), 'fx106') on conflict (key) do update set value = excluded.value, set_by = 'fx106';
create temp table _afterBurden as select count(*) as n from staff_rate_cache;
select staff_rate_cache_fill((select cur from _fx), (select n1 from _fx));
insert into settings (key, value, set_by) values ('_fx106_probe', '1'::jsonb, 'fx106') on conflict (key) do update set value = excluded.value;
create temp table _afterOther as select count(*) as n from staff_rate_cache where staff_id::text like 'f0f0f0f0-0000-0000-0000-000000000_06';

-- 4. HISTORY
create temp table _exA as select x from jsonb_array_elements(scope_existing_deals((select a from _s))) x where x ->> 'id' = 'f0f0f0f0-0000-0000-0000-00000000dd06';
create temp table _exB as select x from jsonb_array_elements(scope_existing_deals((select b from _s))) x where x ->> 'id' = 'f0f0f0f0-0000-0000-0000-00000000dd06';
create temp table _clA as select x from jsonb_array_elements(scope_verdict((select a from _s)) -> 'client') x where (x ->> 'month')::date = (select cur from _fx);
create temp table _clB as select x from jsonb_array_elements(scope_verdict((select b from _s)) -> 'client') x where (x ->> 'month')::date = (select p1 from _fx);
create temp table _wantHist as select
  round(15 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b06', (p1 + 5)::date))::bigint as labor_measured,
  round(10 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b06', cur))::bigint as labor_plan_cur,
  (select (x ->> 'labor_actual')::bigint from jsonb_array_elements(project_detail('f0f0f0f0-0000-0000-0000-00000000dd06') -> 'months') x where (x ->> 'month')::date = p1) as pd_labor
from _fx;

-- 7. LIST (before anything is deleted)
create temp table _list as select scoping_list() as j;

-- 5. DELETE
create temp table _delC as select delete_scope((select c from _s), 'nobody@x') as r;
select set_scope_status((select b from _s), 'proposed', 'fx106@x');
select approve_scope((select b from _s), 'fx106@x');
create temp table _asgB as select count(*) as n from assignments where scope_id = (select b from _s);
create temp table _delB1 as select delete_scope((select b from _s), 'nobody@x') as r;
create temp table _delB2 as select delete_scope((select b from _s), 'fx106@x') as r;
select set_scope_status((select d from _s), 'proposed', 'fx106@x');
select approve_scope((select d from _s), 'fx106@x');
update scopes set status = 'promoted', promoted_at = now() where id = (select d from _s);
create temp table _delD as select delete_scope((select d from _s), 'fx106@x') as r;

-- 6. ACT
create temp table _act1 as select scope_act('save', (select a from _s), 'fx106@x',
  jsonb_build_object('payload', (select pa from _mk) || jsonb_build_object('id', (select a from _s), 'name', '_fx106 A2'), 'label', 'v2')) as r;
create temp table _vA3 as select scope_verdict((select a from _s)) as j;
create temp table _act2 as select scope_act('bogus', (select a from _s), 'fx106@x', '{}'::jsonb) as r;
create temp table _act3 as select scope_act('delete', (select a from _s), 'fx106@x', '{}'::jsonb) as r;

-- 8. QUICK
create temp table _qc as select quick_check('search', 10000000, 10, 3, '{"Paid Media": 20}'::jsonb) as j;
create temp table _qcWant as select round(20 * band_rate('Paid Media', null, cur))::bigint as labor_month from _fx;

with r(n, result) as (
  select 1, case when (select count(*) from _cold) = 4 and (select count(*) from _warm) = 4
                  and not exists (select * from _cold except select * from _warm)
                  and not exists (select * from _warm except select * from _cold)
                  and (select bool_and(rate = live) from _warm)   -- live pinned at capture: row 3 changes P's comp later
                  and (select count(*) from _cache1) = 4
                  and not exists (select 1 from _cache1 where staff_id = 'f0f0f0f0-0000-0000-0000-000000000d06')
                  and (select n from _fill2) = 0
    then '1. MEMO cold = warm = staff_hourly_cost per person-month; the fill covers P and Q in both months, not the inactive R; a second fill writes 0: PASS'
    else '1. MEMO: FAIL — cold ' || (select count(*) from _cold) || ' warm ' || (select count(*) from _warm) || ' cache ' || (select count(*) from _cache1) || ' fill2 ' || (select n from _fill2)
      || ' cold rates ' || coalesce((select string_agg(coalesce(rate::text, 'null'), ',') from _cold), '-') end
  union all
  select 2, case when (select j -> 'verdict' from _pgA) = (select j from _vA)
                  and (select c = h from _chc1) and (select c = h from _chc2)
                  and (select j from _vA2) = (select j from _vA)
    then '2. TWIN scope_page.verdict = scope_verdict; cached_hourly_cost = staff_hourly_cost with and without a memo row; the verdict does not move when the memo is emptied: PASS'
    else '2. TWIN: FAIL — page=verdict ' || ((select j -> 'verdict' from _pgA) = (select j from _vA))::text
      || ' chc1 ' || (select c::text || '/' || h::text from _chc1) || ' chc2 ' || (select coalesce(c::text, 'null') || '/' || h::text from _chc2)
      || ' verdict stable ' || ((select j from _vA2) = (select j from _vA))::text end
  union all
  select 3, case when (select p_rows from _afterComp) = 0 and (select q_rows from _afterComp) = 2
                  and (select p_cached = p_live from _afterComp) and (select p_live <> p_before from _afterComp)
                  and (select n from _afterBurden) = 0
                  and (select n from _afterOther) = 4
    then '3. STALE a comp change drops P''s memo rows and the next read is the new rate; a burden setting empties the memo; an unrelated setting leaves it: PASS'
    else '3. STALE: FAIL — p_rows ' || (select p_rows from _afterComp) || ' q_rows ' || (select q_rows from _afterComp)
      || ' cached ' || (select coalesce(p_cached::text, 'null') from _afterComp) || ' live ' || (select p_live from _afterComp) || ' before ' || (select p_before from _afterComp)
      || ' after burden ' || (select n from _afterBurden) || ' after other ' || (select n from _afterOther) end
  union all
  select 4, case when (select (x ->> 'labor_measured')::bigint from _exA) = 0 and (select (x ->> 'hours_measured')::numeric from _exA) = 0
                  and (select (x ->> 'gp_plan')::bigint from _exA) = 200000
                  and (select (x ->> 'labor_plan')::bigint from _exA) = (select labor_plan_cur from _wantHist)
                  and (select (x ->> 'labor_measured')::bigint from _exB) = (select labor_measured from _wantHist)
                  and (select (x ->> 'labor_measured')::bigint from _exB) = (select pd_labor from _wantHist)
                  and (select (x ->> 'hours_measured')::numeric from _exB) = 15
                  and (select (x ->> 'gp_existing')::bigint from _clA) = 100000
                  and (select (x ->> 'labor_existing')::bigint from _clA) = (select labor_plan_cur from _wantHist)
                  and (select (x ->> 'labor_existing')::bigint from _clB) = (select labor_measured from _wantHist)
    then '4. HISTORY future window: 0 measured, plan = 2 × $1,000 and 10 h × P''s rate; window from last month: 15 h priced exactly as project_detail, on the existing-deals panel AND the client roll-up: PASS'
    else '4. HISTORY: FAIL — A ' || coalesce((select x::text from _exA), 'no row') || ' B ' || coalesce((select x::text from _exB), 'no row')
      || ' clA ' || coalesce((select x::text from _clA), 'no row') || ' clB ' || coalesce((select x::text from _clB), 'no row')
      || ' want ' || (select to_jsonb(w)::text from _wantHist w) end
  union all
  select 5, case when (select (r ->> 'ok')::boolean from _delC)
                  and not exists (select 1 from scopes where id = (select c from _s))
                  and not exists (select 1 from scope_deals where scope_id = (select c from _s))
                  and not exists (select 1 from scope_versions where scope_id = (select c from _s))
                  and (select n from _asgB) = 1
                  and not (select (r ->> 'ok')::boolean from _delB1)
                  and (select (r ->> 'ok')::boolean from _delB2) and (select (r ->> 'assignments_deleted')::int from _delB2) = 1
                  and not exists (select 1 from assignments where scope_id = (select b from _s))
                  and not exists (select 1 from scopes where id = (select b from _s))
                  and not (select (r ->> 'ok')::boolean from _delD) and (select r ->> 'reason' from _delD) like '%promoted%'
                  and exists (select 1 from scopes where id = (select d from _s))
    then '5. DELETE draft by anyone with its children; approved refuses a stranger, goes for an approver with its 1 reserved assignment; promoted stays: PASS'
    else '5. DELETE: FAIL — C ' || (select r::text from _delC) || ' asgB ' || (select n from _asgB) || ' B1 ' || (select r::text from _delB1)
      || ' B2 ' || (select r::text from _delB2) || ' D ' || (select r::text from _delD) end
  union all
  select 6, case when (select (r ->> 'ok')::boolean from _act1)
                  and (select r -> 'page' ->> 'id' from _act1) = (select a::text from _s)
                  and (select r -> 'page' ->> 'name' from _act1) = '_fx106 A2'
                  and (select r -> 'page' -> 'verdict' from _act1) = (select j from _vA3)
                  and (select (r ->> 'version')::int from _act1) = 2
                  and not (select (r ->> 'ok')::boolean from _act2)
                  and (select (r ->> 'ok')::boolean from _act3) and not (select r ? 'page' from _act3)
                  and not exists (select 1 from scopes where id = (select a from _s))
    then '6. ACT save returns v2 and the fresh page (name, verdict = scope_verdict); unknown action refused; delete returns no page and the scope is gone: PASS'
    else '6. ACT: FAIL — save ' || (select coalesce(r ->> 'ok', 'null') || ' v' || coalesce(r ->> 'version', '?') || ' page.id ' || coalesce(r -> 'page' ->> 'id', 'null') || ' name ' || coalesce(r -> 'page' ->> 'name', 'null') from _act1)
      || ' bogus ' || (select r::text from _act2) || ' delete ' || (select r::text from _act3) end
  union all
  select 7, case when (select j ?& array['scopes', 'pipeline', 'promotions', 'dismissals', 'deals', 'clients', 'settings', 'scoped', 'departments'] from _list)
                  and exists (select 1 from _list, jsonb_array_elements(j -> 'scopes') s where s ->> 'id' = (select a::text from _s))
                  and exists (select 1 from _list, jsonb_array_elements(j -> 'deals') d where d ->> 'id' = 'f0f0f0f0-0000-0000-0000-00000000dd06')
                  and (select j -> 'settings' -> 'scope_approver_emails' from _list) = '["fx106@x"]'::jsonb
                  and exists (select 1 from _list, jsonb_array_elements_text(j -> 'departments') d where d = 'Paid Media')
    then '7. LIST scoping_list carries scopes, pipeline, promotions, dismissals, deals, clients, settings, scoped, departments — with the fixture scope, deal, approvers and department: PASS'
    else '7. LIST: FAIL — keys ' || (select string_agg(k, ',') from _list, jsonb_object_keys(j) k) end
  union all
  select 8, case when (select (j ->> 'labor_month')::bigint from _qc) = (select labor_month from _qcWant)
                  and (select (j ->> 'gp_month')::bigint from _qc) = 1000000
                  and (select (j ->> 'hours_month')::numeric from _qc) = 20
                  and (select j ->> 'hours_method' from _qc) = 'typed'
    then '8. QUICK typed 20 h priced at band_rate(Paid Media, null) on the memo; gp 10% of $100k: PASS'
    else '8. QUICK: FAIL — ' || (select j::text from _qc) || ' want labor ' || (select labor_month from _qcWant) end
)
select result from r order by n;
rollback;
