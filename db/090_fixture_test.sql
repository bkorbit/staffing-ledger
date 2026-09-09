-- Fixture test for 090 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-090 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the SEVEN rows of the single result set at the bottom
--   3. it ends in ROLLBACK — every fixture row is undone. Do not commit it.
--
-- What is being proved:
--   1. hours_page deal_labor counts 'deal' rows AND legacy (null attribution)
--      rows, and leaves a 'timeoff' row on the same deal out.
--   2. hours_page staff_hours_month: the excluded person contributes nothing;
--      the working person's total is exact and includes uncoded/unmatched/
--      internal rows (they are real hours, just not on a deal yet).
--   3. unmapped_hours total and group count are exact: uncoded, unmatched,
--      unknown_user and excluded — and NOT internal, deal, timeoff or legacy.
--   4. the uncoded group carries exact hours, its one person, its one month,
--      and no mapping.
--   5. the excluded group is keyed to the excluded PERSON (excluded_staff_id),
--      since the fix for it is staff.exclude_hours, not the jobcode.
--   6. an unknown-user row (staff_id null) is kept and labelled '(unknown user)'.
--   7. a qbtime_jobcode_map row shows up on its group so the panel can say
--      "already mapped, waiting for the next sync".
--
-- Adversarial on purpose: two people, one excluded; the same jobcode split
-- across an uncoded row and an excluded row; a legacy null-attribution row; a
-- timeoff row ON the deal; a staff-less row. Single-row fixtures would pass
-- while getting the group keys wrong.

begin;

insert into clients (id, name) values ('0f090000-0000-0000-0000-000000000001', 'fx090 client');
insert into staff (id, name, department, active, exclude_hours) values
  ('0f090000-0000-0000-0000-00000000000a', 'fx090 Worker', 'Creative', true, false),
  ('0f090000-0000-0000-0000-00000000000b', 'fx090 Excluded', 'Creative', false, true);
insert into deals (id, client_id, name, status, flight_start, flight_end) values
  ('0f090000-0000-0000-0000-0000000000dd', '0f090000-0000-0000-0000-000000000001', 'fx090 deal', 'won', '2026-07-01', '2026-09-30');

insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department, source, qbtime_jobcode_id, jobcode_name, attribution) values
  ('fx090:1', '0f090000-0000-0000-0000-00000000000a', '0f090000-0000-0000-0000-0000000000dd', '0f090000-0000-0000-0000-000000000001', '2026-08-03', 5.00, 'Creative', 'qbtime', 900, 'Acme › 26acme260101 Acme Web', 'deal'),
  ('fx090:2', '0f090000-0000-0000-0000-00000000000a', null, null, '2026-08-04', 3.00, 'Creative', 'qbtime', 111, 'Acme › Web', 'uncoded'),
  ('fx090:3', '0f090000-0000-0000-0000-00000000000b', null, null, '2026-08-04', 2.00, 'Creative', 'qbtime', 111, 'Acme › Web', 'excluded'),
  ('fx090:4', '0f090000-0000-0000-0000-00000000000a', null, null, '2026-08-05', 4.00, 'Creative', 'qbtime', 5, 'Internal', 'internal'),
  ('fx090:5', '0f090000-0000-0000-0000-00000000000a', '0f090000-0000-0000-0000-0000000000dd', '0f090000-0000-0000-0000-000000000001', '2026-08-06', 1.00, 'Creative', 'qbtime', 900, 'Acme › 26acme260101 Acme Web', 'timeoff'),
  ('fx090:6', null, null, null, '2026-08-07', 1.50, null, 'qbtime', 222, 'Foo › Bar', 'unknown_user'),
  ('fx090:7', '0f090000-0000-0000-0000-00000000000a', null, null, '2026-08-10', 2.50, 'Creative', 'qbtime', 333, 'Zed › 26zzzz260101 Zed', 'unmatched'),
  ('fx090:8', '0f090000-0000-0000-0000-00000000000a', '0f090000-0000-0000-0000-0000000000dd', '0f090000-0000-0000-0000-000000000001', '2026-08-11', 1.00, 'Creative', 'qbtime', null, null, null);

insert into qbtime_jobcode_map (qbtime_jobcode_id, jobcode_name, resolution, set_by)
  values (333, 'Zed › 26zzzz260101 Zed', 'internal', 'fx090');

create temp table _fx_hp as select hours_page('2026-08-01', '2026-08-31') as j;
create temp table _fx_um as select unmapped_hours('2026-08-01', '2026-08-31') as j;
create temp table _fx_g as
  select x as g from _fx_um, jsonb_array_elements(j -> 'groups') x;

with r(n, result) as (
  select 1, case when (select (x ->> 'hours')::numeric from _fx_hp, jsonb_array_elements(j -> 'deal_labor') x
                       where x ->> 'deal_id' = '0f090000-0000-0000-0000-0000000000dd') = 6.00
    then '1. DEAL LABOR = deal + legacy rows, timeoff row excluded (6.00h): PASS'
    else '1. DEAL LABOR: FAIL — got ' || coalesce((select x ->> 'hours' from _fx_hp, jsonb_array_elements(j -> 'deal_labor') x
                       where x ->> 'deal_id' = '0f090000-0000-0000-0000-0000000000dd'), 'null') end
  union all
  select 2, case when (select (x ->> 'hours')::numeric from _fx_hp, jsonb_array_elements(j -> 'staff_hours_month') x
                       where x ->> 'staff_id' = '0f090000-0000-0000-0000-00000000000a') = 15.50
                 and not exists (select 1 from _fx_hp, jsonb_array_elements(j -> 'staff_hours_month') x
                       where x ->> 'staff_id' = '0f090000-0000-0000-0000-00000000000b')
    then '2. STAFF HOURS: worker 15.50h exact, excluded person contributes nothing: PASS'
    else '2. STAFF HOURS: FAIL — worker ' || coalesce((select x ->> 'hours' from _fx_hp, jsonb_array_elements(j -> 'staff_hours_month') x
                       where x ->> 'staff_id' = '0f090000-0000-0000-0000-00000000000a'), 'null')
         || ', excluded rows ' || (select count(*) from _fx_hp, jsonb_array_elements(j -> 'staff_hours_month') x
                       where x ->> 'staff_id' = '0f090000-0000-0000-0000-00000000000b')::text end
  union all
  select 3, case when (select (j ->> 'total_hours')::numeric from _fx_um) = 9.00
                 and (select count(*) from _fx_g) = 4
    then '3. UNMAPPED TOTAL 9.00h IN 4 GROUPS (uncoded, excluded, unknown_user, unmatched; not internal/deal/timeoff/legacy): PASS'
    else '3. UNMAPPED: FAIL — total ' || coalesce((select j ->> 'total_hours' from _fx_um), 'null')
         || ', groups ' || (select count(*) from _fx_g)::text end
  union all
  select 4, case when (select (g ->> 'hours')::numeric from _fx_g where (g ->> 'qbtime_jobcode_id') = '111' and g ->> 'attribution' = 'uncoded') = 3.00
                 and (select g -> 'people' from _fx_g where (g ->> 'qbtime_jobcode_id') = '111' and g ->> 'attribution' = 'uncoded')
                     = '[{"name":"fx090 Worker","hours":3.00}]'::jsonb
                 and (select g -> 'months' from _fx_g where (g ->> 'qbtime_jobcode_id') = '111' and g ->> 'attribution' = 'uncoded')
                     = '[{"month":"2026-08-01","hours":3.00}]'::jsonb
                 and (select g -> 'mapping' from _fx_g where (g ->> 'qbtime_jobcode_id') = '111' and g ->> 'attribution' = 'uncoded') = 'null'::jsonb
    then '4. UNCODED GROUP: 3.00h, one person, one month, no mapping: PASS'
    else '4. UNCODED GROUP: FAIL — ' || coalesce((select g::text from _fx_g where (g ->> 'qbtime_jobcode_id') = '111' and g ->> 'attribution' = 'uncoded'), 'missing') end
  union all
  select 5, case when (select g ->> 'excluded_staff_id' from _fx_g where g ->> 'attribution' = 'excluded') = '0f090000-0000-0000-0000-00000000000b'
                 and (select (g ->> 'hours')::numeric from _fx_g where g ->> 'attribution' = 'excluded') = 2.00
    then '5. EXCLUDED GROUP keyed to the excluded person, 2.00h: PASS'
    else '5. EXCLUDED GROUP: FAIL — ' || coalesce((select g::text from _fx_g where g ->> 'attribution' = 'excluded'), 'missing') end
  union all
  select 6, case when (select g -> 'people' -> 0 ->> 'name' from _fx_g where g ->> 'attribution' = 'unknown_user') = '(unknown user)'
                 and (select (g ->> 'hours')::numeric from _fx_g where g ->> 'attribution' = 'unknown_user') = 1.50
    then '6. UNKNOWN USER row kept, labelled, 1.50h: PASS'
    else '6. UNKNOWN USER: FAIL — ' || coalesce((select g::text from _fx_g where g ->> 'attribution' = 'unknown_user'), 'missing') end
  union all
  select 7, case when (select g -> 'mapping' ->> 'resolution' from _fx_g where (g ->> 'qbtime_jobcode_id') = '333') = 'internal'
    then '7. EXISTING MAPPING shown on its group: PASS'
    else '7. MAPPING: FAIL — ' || coalesce((select g -> 'mapping' from _fx_g where (g ->> 'qbtime_jobcode_id') = '333')::text, 'missing') end
)
select result from r order by n;
rollback;
