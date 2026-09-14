-- Fixture test for 107 — NOT a migration, do not ship this file.
-- Run with 001-107 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the SINGLE result set — every line must say PASS
--   3. it ends in ROLLBACK
--
--   1. PRICES   — the preview of an edited payload (a second retainer line)
--                 prices the EDITED scope: 2 lines in econ, GP = 2 × ($100 + $500)
--   2. WRITES NOTHING — after the preview the scope still has 1 line, its
--                 version and set_at are unchanged, no version row was added
--   3. AGREES   — saving the same payload for real gives the verdict the
--                 preview showed
--   4. REFUSES  — a payload without an id; an approved scope (save_scope's rule)
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * preview_scope: return the page without raising (let the save commit)   -> row 2
--   * preview_scope: skip the save, page the stored scope                     -> row 1

begin;
create temp table _fx as select date_trunc('month', current_date)::date as cur,
  (date_trunc('month', current_date) + interval '1 month')::date as n1;
insert into settings (key, value, set_by) values ('scope_approver_emails', '["fx107@x"]'::jsonb, 'fx107')
on conflict (key) do update set value = excluded.value;
insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000107', '_fx107 Client', true);
insert into staff (id, name, department, active, tracks_capacity) values ('f0f0f0f0-0000-0000-0000-000000000b07', '_fx107 P', 'Paid Media', true, true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-000000000b07'::uuid, (cur - 400)::date, 'hourly'::comp_kind, 5000, 40 from _fx;

create temp table _mk as
select jsonb_build_object('name', '_fx107 A', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000107',
  'deals', jsonb_build_array(jsonb_build_object('name', 'd', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', cur, 'flight_end', (n1 + 27)::date, 'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 100)))),
  'dept_months', jsonb_build_array(jsonb_build_object('department', 'Paid Media', 'month', cur, 'hours', 30)),
  'staff_months', jsonb_build_array(jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-000000000b07', 'department', 'Paid Media', 'month', cur, 'hours', 10))) as pa
from _fx;
create temp table _s as select ((save_scope((select pa from _mk), 'fx107', null)) ->> 'scope_id')::uuid as a;
create temp table _before as select version, set_at, (select count(*) from scope_versions where scope_id = a) as nver,
  (select count(*) from scope_lines sl join scope_deals sd on sd.id = sl.scope_deal_id where sd.scope_id = a) as nlines
  from scopes, _s where id = a;

-- the edited payload: the saved scope plus a $500 retainer line
create temp table _edit as
select jsonb_set((select pa from _mk) || jsonb_build_object('id', (select a from _s)), '{deals,0,lines}',
  jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 100), jsonb_build_object('kind', 'retainer', 'amount', 500))) as p;
create temp table _prev as select preview_scope((select p from _edit), 'fx107') as r;
create temp table _after as select version, set_at, (select count(*) from scope_versions where scope_id = a) as nver,
  (select count(*) from scope_lines sl join scope_deals sd on sd.id = sl.scope_deal_id where sd.scope_id = a) as nlines
  from scopes, _s where id = a;
-- now save for real and compare
select save_scope((select p from _edit), 'fx107', null);
create temp table _real as select scope_verdict((select a from _s)) as j;
create temp table _noid as select preview_scope((select pa from _mk), 'fx107') as r;
select set_scope_status((select a from _s), 'proposed', 'fx107@x');
select approve_scope((select a from _s), 'fx107@x');
create temp table _appr as select preview_scope((select p from _edit), 'fx107') as r;

with r(n, result) as (
  select 1, case when (select (r ->> 'ok')::boolean from _prev)
                  and (select jsonb_array_length(r -> 'page' -> 'econ') from _prev) = 4        -- 2 lines × 2 months
                  and (select (r -> 'page' -> 'verdict' -> 'total' ->> 'gp')::bigint from _prev) = 1200
                  and (select r -> 'page' ->> 'id' from _prev) = (select a::text from _s)
    then '1. PRICES the preview prices the EDITED payload: 4 line-months, GP 1,200 = 2 × (100 + 500): PASS'
    else '1. PRICES: FAIL — ' || (select coalesce(r ->> 'ok', 'null') || ' econ ' || coalesce(jsonb_array_length(r -> 'page' -> 'econ')::text, 'null') || ' gp ' || coalesce(r -> 'page' -> 'verdict' -> 'total' ->> 'gp', 'null') || ' ' || coalesce(r ->> 'reason', '') from _prev) end
  union all
  select 2, case when (select version from _before) = (select version from _after)
                  and (select set_at from _before) = (select set_at from _after)
                  and (select nver from _before) = (select nver from _after)
                  and (select nlines from _before) = 1 and (select nlines from _after) = 1
    then '2. WRITES NOTHING version, set_at, version rows and the single line are untouched by the preview: PASS'
    else '2. WRITES NOTHING: FAIL — before v' || (select version from _before) || ' nver ' || (select nver from _before) || ' lines ' || (select nlines from _before)
      || ' after v' || (select version from _after) || ' nver ' || (select nver from _after) || ' lines ' || (select nlines from _after) end
  union all
  select 3, case when (select r -> 'page' -> 'verdict' from _prev) = (select j from _real)
    then '3. AGREES the real save''s verdict equals the preview''s, key for key: PASS'
    else '3. AGREES: FAIL — preview total ' || (select coalesce((r -> 'page' -> 'verdict' -> 'total')::text, 'null') from _prev) || ' real total ' || (select (j -> 'total')::text from _real) end
  union all
  select 4, case when not (select (r ->> 'ok')::boolean from _noid) and (select r ->> 'reason' from _noid) like '%id%'
                  and not (select (r ->> 'ok')::boolean from _appr) and (select r ->> 'reason' from _appr) like '%approved%'
    then '4. REFUSES a payload without an id, and an approved scope (save_scope''s own rule): PASS'
    else '4. REFUSES: FAIL — noid ' || (select r::text from _noid) || ' approved ' || (select r::text from _appr) end
)
select result from r order by n;
rollback;
