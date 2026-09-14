-- Fixture test for 112 — NOT a migration, do not ship this file.
-- Run with 001-112 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the SINGLE result set — every line must say PASS
--   3. it ends in ROLLBACK
--
--   1. HOURS     — benchmark_deal_hours: per department per month, excluded and
--                  time-off rows absent, the entry's own department when the
--                  person has none, the running month flagged open
--   2. AGREES    — an enrolled deal-month's hours equal v_benchmark_observed's
--   3. PLATFORMS — 'viant' and 'cm360' uploads are accepted; a non-key is refused
--   4. DEFAULTS  — the four new team defaults exist, an existing key kept its value,
--                  placements is in the driver order exactly once
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * benchmark_deal_hours: count excluded rows                          -> row 1
--   * benchmark_deal_hours: closed = month <= current (running month closed) -> row 1
--   * benchmark_deal_hours: department = te.department first             -> row 1

begin;
create temp table _fx as select date_trunc('month', current_date)::date as cur,
  (date_trunc('month', current_date) - interval '1 month')::date as p1;
insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000112', '_fx112 Client', true);
insert into staff (id, name, department, active, tracks_capacity) values
  ('f0f0f0f0-0000-0000-0000-000000000a12', '_fx112 P', 'Paid Media', true, true),
  ('f0f0f0f0-0000-0000-0000-000000000b12', '_fx112 Q', 'Programmatic', true, true),
  ('f0f0f0f0-0000-0000-0000-000000000c12', '_fx112 N nodept', null, true, true);
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-0000000dd112', 'f0f0f0f0-0000-0000-0000-000000000112', '_fx112 Deal', 'active', 'manual', (p1 - 40)::date, (cur + 60)::date from _fx;
insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, attribution, department)
select '_fx112_1'::text, 'f0f0f0f0-0000-0000-0000-000000000a12'::uuid, 'f0f0f0f0-0000-0000-0000-0000000dd112'::uuid, 'f0f0f0f0-0000-0000-0000-000000000112'::uuid, (p1 + 3)::date, 6::numeric, 'deal'::text, 'Wrong Dept'::text from _fx union all
select '_fx112_2', 'f0f0f0f0-0000-0000-0000-000000000a12', 'f0f0f0f0-0000-0000-0000-0000000dd112', 'f0f0f0f0-0000-0000-0000-000000000112', (p1 + 9)::date, 4, 'deal', null::text from _fx union all
select '_fx112_3', 'f0f0f0f0-0000-0000-0000-000000000b12', 'f0f0f0f0-0000-0000-0000-0000000dd112', 'f0f0f0f0-0000-0000-0000-000000000112', (p1 + 9)::date, 5, 'mapped', null from _fx union all
select '_fx112_4', 'f0f0f0f0-0000-0000-0000-000000000c12', 'f0f0f0f0-0000-0000-0000-0000000dd112', 'f0f0f0f0-0000-0000-0000-000000000112', (p1 + 12)::date, 2, 'deal', 'AdOps' from _fx union all
select '_fx112_5', 'f0f0f0f0-0000-0000-0000-000000000a12', 'f0f0f0f0-0000-0000-0000-0000000dd112', 'f0f0f0f0-0000-0000-0000-000000000112', (p1 + 15)::date, 7, 'excluded', null from _fx union all
select '_fx112_6', 'f0f0f0f0-0000-0000-0000-000000000a12', 'f0f0f0f0-0000-0000-0000-0000000dd112', 'f0f0f0f0-0000-0000-0000-000000000112', (p1 + 16)::date, 8, 'timeoff', null from _fx union all
select '_fx112_7', 'f0f0f0f0-0000-0000-0000-000000000a12', 'f0f0f0f0-0000-0000-0000-0000000dd112', 'f0f0f0f0-0000-0000-0000-000000000112', (cur + 1)::date, 3, 'deal', null from _fx;

create temp table _h as select x from jsonb_array_elements(benchmark_deal_hours('f0f0f0f0-0000-0000-0000-0000000dd112')) x;
create temp table _hv as select x ->> 'department' as dep, (x ->> 'month')::date as month, (x ->> 'hours')::numeric as hours, (x ->> 'closed')::boolean as closed, (x ->> 'people')::int as people from _h;

-- 2. an enrolled upload for Paid Media last month → the observed view's hours
create temp table _up as select record_benchmark_observations(
  jsonb_build_object('deal_id', 'f0f0f0f0-0000-0000-0000-0000000dd112', 'platform', 'viant', 'department', 'Paid Media', 'filename', 'x.csv', 'parser', 'dsp-daily@1', 'row_count', 1, 'summary', '{}'::jsonb),
  jsonb_build_array(jsonb_build_object('month', (select p1 from _fx), 'drivers', jsonb_build_object('spend', 100000, 'active_campaigns', 2))), 'fx112') as r;
create temp table _obs as select hours from v_benchmark_observed where deal_id = 'f0f0f0f0-0000-0000-0000-0000000dd112' and department = 'Paid Media' and month = (select p1 from _fx);

-- 3. platform keys
create temp table _pl (k text, ok boolean);
do $$ begin
  begin insert into benchmark_uploads (deal_id, platform, department) values ('f0f0f0f0-0000-0000-0000-0000000dd112', 'cm360', 'AdOps'); insert into _pl values ('cm360', true); exception when check_violation then insert into _pl values ('cm360', false); end;
  begin insert into benchmark_uploads (deal_id, platform, department) values ('f0f0f0f0-0000-0000-0000-0000000dd112', 'Bad Platform!', 'AdOps'); insert into _pl values ('bad', true); exception when check_violation then insert into _pl values ('bad', false); end;
end $$;

with r(n, result) as (
  select 1, case when (select count(*) from _hv) = 4
                  and (select hours from _hv where dep = 'Paid Media' and month = (select p1 from _fx)) = 10
                  and (select people from _hv where dep = 'Paid Media' and month = (select p1 from _fx)) = 1
                  and (select closed from _hv where dep = 'Paid Media' and month = (select p1 from _fx))
                  and (select hours from _hv where dep = 'Programmatic' and month = (select p1 from _fx)) = 5
                  and (select hours from _hv where dep = 'AdOps' and month = (select p1 from _fx)) = 2
                  and (select hours from _hv where dep = 'Paid Media' and month = (select cur from _fx)) = 3
                  and not (select closed from _hv where dep = 'Paid Media' and month = (select cur from _fx))
    then '1. HOURS Paid Media 10h last month (staff department wins over the entry''s), Programmatic 5h, AdOps 2h from the entry''s own department, 3h this month flagged open; excluded 7h and time-off 8h absent: PASS'
    else '1. HOURS: FAIL — ' || coalesce((select string_agg(dep || ' ' || month || ' ' || hours || 'h' || case when closed then ' closed' else ' open' end || ' p' || people, '; ' order by dep, month) from _hv), 'none') end
  union all
  select 2, case when (select (r ->> 'ok')::boolean from _up) and (select hours from _obs) = (select hours from _hv where dep = 'Paid Media' and month = (select p1 from _fx))
    then '2. AGREES the observed view and benchmark_deal_hours count the same 10h for the enrolled Paid Media month: PASS'
    else '2. AGREES: FAIL — upload ' || (select r::text from _up) || ' observed ' || coalesce((select hours::text from _obs), 'null') end
  union all
  select 3, case when (select ok from _pl where k = 'cm360') and not (select ok from _pl where k = 'bad')
                  and exists (select 1 from benchmark_uploads where platform = 'viant' and deal_id = 'f0f0f0f0-0000-0000-0000-0000000dd112')
    then '3. PLATFORMS viant and cm360 uploads accepted, "Bad Platform!" refused by the shape check: PASS'
    else '3. PLATFORMS: FAIL — ' || (select string_agg(k || '=' || ok::text, ', ') from _pl) end
  union all
  select 4, case when (select value ->> 'viant' from settings where key = 'scope_platform_team_defaults') = 'Programmatic'
                  and (select value ->> 'reddit' from settings where key = 'scope_platform_team_defaults') = 'Paid Media'
                  and (select value ->> 'linkedin' from settings where key = 'scope_platform_team_defaults') = 'Paid Media'
                  and (select value ->> 'cm360' from settings where key = 'scope_platform_team_defaults') = 'AdOps'
                  and (select value ->> 'google_ads' from settings where key = 'scope_platform_team_defaults') = 'Paid Media'
                  and (select count(*) from settings s, jsonb_array_elements_text(s.value) e where s.key = 'scope_driver_order' and e = 'placements') = 1
    then '4. DEFAULTS viant / reddit / linkedin / cm360 added, google_ads kept, placements in the driver order once: PASS'
    else '4. DEFAULTS: FAIL — ' || (select value::text from settings where key = 'scope_platform_team_defaults') || ' order ' || (select value::text from settings where key = 'scope_driver_order') end
)
select result from r order by n;
rollback;
