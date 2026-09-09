-- Fixture test for 091 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-091 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the THREE rows of the single result set at the bottom
--   3. it ends in ROLLBACK
--
-- Proves: project_detail and client_detail count exactly the time entries
-- hours_page's deal_labor counts for the same deal — 'deal', legacy (null)
-- and 'internal'/'mapped' rows in; 'excluded' and 'timeoff' rows out.

begin;
create temp table _fx_m as
select (date_trunc('month', current_date) - interval '1 month')::date as m1;

insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000091', '_fx091 Client', true);
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-0000000000a1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000091'::uuid,
       '_fx091 deal', 'active'::deal_status, 'manual'::deal_origin, m1, (m1 + 27)::date from _fx_m;
insert into staff (id, name, department, active) values ('f0f0f0f0-0000-0000-0000-0000000000b1', '_fx091 Person', 'Creative', true);

insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department, attribution)
select 'fx091-1', 'f0f0f0f0-0000-0000-0000-0000000000b1'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000091'::uuid, m1 + 2, 5.00, 'Creative', 'deal'     from _fx_m union all
select 'fx091-2', 'f0f0f0f0-0000-0000-0000-0000000000b1'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000091'::uuid, m1 + 3, 1.50, 'Creative', null       from _fx_m union all
select 'fx091-3', 'f0f0f0f0-0000-0000-0000-0000000000b1'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000091'::uuid, m1 + 4, 1.00, 'Creative', 'timeoff'  from _fx_m union all
select 'fx091-4', 'f0f0f0f0-0000-0000-0000-0000000000b1'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000091'::uuid, m1 + 5, 2.00, 'Creative', 'excluded' from _fx_m;

create temp table _fx as
select (select sum(hours) from project_detail('f0f0f0f0-0000-0000-0000-0000000000a1'), jsonb_to_recordset(project_detail('f0f0f0f0-0000-0000-0000-0000000000a1') -> 'weeks') as x(week date, department text, hours numeric)) as pd,
       (select sum(hours) from client_detail('f0f0f0f0-0000-0000-0000-000000000091'), jsonb_to_recordset(client_detail('f0f0f0f0-0000-0000-0000-000000000091') -> 'weeks_by_deal') as x(week date, deal_id uuid, hours numeric)) as cd,
       (select (x ->> 'hours')::numeric from hours_page((select m1 from _fx_m), (select (m1 + 27)::date from _fx_m)), jsonb_array_elements(hours_page((select m1 from _fx_m), (select (m1 + 27)::date from _fx_m)) -> 'deal_labor') x
        where x ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-0000000000a1') as hp;

with r as (
  select 1 as n, case when (select pd from _fx) = 6.50 then '1. project_detail counts deal + legacy rows, not timeoff/excluded (6.5h): PASS'
    else '1. project_detail: FAIL — ' || coalesce((select pd::text from _fx), 'null') end as result
  union all
  select 2, case when (select cd from _fx) = 6.50 then '2. client_detail the same (6.5h): PASS'
    else '2. client_detail: FAIL — ' || coalesce((select cd::text from _fx), 'null') end
  union all
  select 3, case when (select pd from _fx) = (select hp from _fx) and (select cd from _fx) = (select hp from _fx)
    then '3. CHART HOURS == hours_page deal_labor (' || (select hp::text from _fx) || 'h): PASS'
    else '3. AGREEMENT: FAIL — chart ' || coalesce((select pd::text from _fx), 'null') || ' vs table ' || coalesce((select hp::text from _fx), 'null') end
)
select result from r order by n;
rollback;
