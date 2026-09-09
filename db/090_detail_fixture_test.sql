-- Fixture test for 090_detail_zero_months_and_weeks_by_deal — NOT a migration, do not ship this file.
-- (Renamed from 090_fixture_test.sql: another migration shares the number 090 and needed that name.)
-- Run against a scratch db (or prod, rolled back) with 001-090 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the FIVE rows of the single result set at the bottom
--   3. it ends in ROLLBACK — every fixture row is undone. Do not commit it.
--
-- What is being proved (088/089_fixture_test still cover the arithmetic;
-- this file covers only what 090 changed):
--   1. ZERO, NOT NULL — a closed month inside the flight with no invoice and
--      no bill reports rev_actual = 0, cogs_actual = 0, gp_actual = 0, for
--      BOTH project_detail and client_detail.
--   2. NULL STAYS NULL — the current month (not closed) still reports null,
--      even though it has an invoice.
--   3. NO NEW MONTHS — the zero fill does not add months: the list is still
--      the flight's months ∪ plan ∪ actual.
--   4. WEEKS BY DEAL — client_detail.weeks_by_deal sums to the same total as
--      weeks (by department), and per deal equals project_detail's total.
--   5. DEALS — client_detail.deals lists the client's deals with names, in
--      flight_start order.

begin;

create temp table _fx_m as
select (date_trunc('month', current_date) - interval '3 month')::date as m1,
       (date_trunc('month', current_date) - interval '2 month')::date as m2,   -- the empty month
       (date_trunc('month', current_date) - interval '1 month')::date as m3,
       date_trunc('month', current_date)::date                       as cur;

insert into qbo_projects (id, name, is_project) values ('fx090-p1', '_fx090 P1', true), ('fx090-p2', '_fx090 P2', true);
insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000090', '_fx090 Client', true);
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, qbo_project_id)
select 'f0f0f0f0-0000-0000-0000-0000000000a0'::uuid, 'f0f0f0f0-0000-0000-0000-000000000090'::uuid,
       '_fx090 later deal', 'active'::deal_status, 'manual'::deal_origin, (m2 + 5)::date, (m3 + 25)::date, 'fx090-p2' from _fx_m
union all
select 'f0f0f0f0-0000-0000-0000-0000000000b0'::uuid, 'f0f0f0f0-0000-0000-0000-000000000090'::uuid,
       '_fx090 earlier deal', 'active'::deal_status, 'manual'::deal_origin, (m1 + 2)::date, (m3 + 25)::date, 'fx090-p1' from _fx_m;

insert into staff (id, name, department, active) values ('f0f0f0f0-0000-0000-0000-0000000000c0', '_fx090 Person', 'Paid Media', true);
insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department)
select 'fx090-t1', 'f0f0f0f0-0000-0000-0000-0000000000c0'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000b0'::uuid, 'f0f0f0f0-0000-0000-0000-000000000090'::uuid, m1 + 8, 6.00, 'Paid Media' from _fx_m union all
select 'fx090-t2', 'f0f0f0f0-0000-0000-0000-0000000000c0'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a0'::uuid, 'f0f0f0f0-0000-0000-0000-000000000090'::uuid, m1 + 8, 1.50, 'Paid Media' from _fx_m union all
select 'fx090-t3', 'f0f0f0f0-0000-0000-0000-0000000000c0'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a0'::uuid, 'f0f0f0f0-0000-0000-0000-000000000090'::uuid, m3 + 1, 2.25, 'Paid Media' from _fx_m;

-- invoices in m1 and m3 only — m2 is the closed, empty month; cur has one too
insert into invoices (id, client_id, qbo_project_id, issued_on, total, balance)
select 'fx090-i1', 'f0f0f0f0-0000-0000-0000-000000000090'::uuid, 'fx090-p1', m1 + 10, 1000000, 0 from _fx_m union all
select 'fx090-i2', 'f0f0f0f0-0000-0000-0000-000000000090'::uuid, 'fx090-p1', m3 + 10, 2000000, 0 from _fx_m union all
select 'fx090-i3', 'f0f0f0f0-0000-0000-0000-000000000090'::uuid, 'fx090-p1', cur + 1, 3000000, 3000000 from _fx_m;

create temp table _fx_pd as select project_detail('f0f0f0f0-0000-0000-0000-0000000000b0') as j;
create temp table _fx_cd as select client_detail('f0f0f0f0-0000-0000-0000-000000000090') as j;
create temp table _fx_pd_m as select * from _fx_pd, jsonb_to_recordset(j -> 'months') as x(month date, rev_actual bigint, cogs_actual bigint, gp_actual bigint);
create temp table _fx_cd_m as select * from _fx_cd, jsonb_to_recordset(j -> 'months') as x(month date, rev_actual bigint, cogs_actual bigint, gp_actual bigint);

with r as (
  select 1 as n, case when (select rev_actual from _fx_pd_m where month = (select m2 from _fx_m)) = 0
                       and (select cogs_actual from _fx_pd_m where month = (select m2 from _fx_m)) = 0
                       and (select gp_actual from _fx_pd_m where month = (select m2 from _fx_m)) = 0
                       and (select rev_actual from _fx_cd_m where month = (select m2 from _fx_m)) = 0
                       and (select gp_actual from _fx_cd_m where month = (select m2 from _fx_m)) = 0
    then '1. EMPTY CLOSED MONTH IS 0 NOT NULL (project_detail and client_detail): PASS'
    else '1. ZERO FILL: FAIL — project m2 rev=' || coalesce((select rev_actual::text from _fx_pd_m where month = (select m2 from _fx_m)), 'null')
         || ' client m2 rev=' || coalesce((select rev_actual::text from _fx_cd_m where month = (select m2 from _fx_m)), 'null') end as result
  union all
  select 2, case when not exists (select 1 from _fx_pd_m where month >= (select cur from _fx_m) and rev_actual is not null)
                  and not exists (select 1 from _fx_cd_m where month >= (select cur from _fx_m) and rev_actual is not null)
    then '2. CURRENT MONTH STAYS NULL (has an invoice, is not closed): PASS'
    else '2. CURRENT MONTH: FAIL — reported as measured' end
  union all
  select 3, case when (select count(*) from _fx_pd_m) = 3 and (select min(month) from _fx_pd_m) = (select m1 from _fx_m)
                  and (select count(*) from _fx_cd_m) = 3
    then '3. MONTH LIST UNCHANGED (3 flight months, no extra rows from the zero fill): PASS'
    else '3. MONTH LIST: FAIL — project ' || (select count(*)::text from _fx_pd_m) || ' rows, client ' || (select count(*)::text from _fx_cd_m) end
  union all
  select 4, case when (select sum(hours) from _fx_cd, jsonb_to_recordset(j -> 'weeks_by_deal') as x(week date, deal_id uuid, hours numeric)) = 9.75
                  and (select sum(hours) from _fx_cd, jsonb_to_recordset(j -> 'weeks') as x(week date, department text, hours numeric)) = 9.75
                  and (select sum(hours) from _fx_cd, jsonb_to_recordset(j -> 'weeks_by_deal') as x(week date, deal_id uuid, hours numeric)
                       where deal_id = 'f0f0f0f0-0000-0000-0000-0000000000b0') = 6.00
                  and (select sum(hours) from _fx_pd, jsonb_to_recordset(j -> 'weeks') as x(week date, department text, hours numeric)) = 6.00
    then '4. WEEKS_BY_DEAL SUMS TO WEEKS (9.75h) AND PER DEAL TO project_detail (6h): PASS'
    else '4. WEEKS BY DEAL: FAIL — total ' || coalesce((select sum(hours)::text from _fx_cd, jsonb_to_recordset(j -> 'weeks_by_deal') as x(week date, deal_id uuid, hours numeric)), 'null') end
  union all
  select 5, case when (select string_agg(name, ' | ' order by ord) from _fx_cd, jsonb_array_elements(j -> 'deals') with ordinality as x(e, ord), lateral (select e ->> 'name' as name) n)
                    = '_fx090 earlier deal | _fx090 later deal'
    then '5. DEALS NAMED, IN FLIGHT-START ORDER: PASS'
    else '5. DEALS: FAIL — ' || coalesce((select string_agg(e ->> 'name', ' | ') from _fx_cd, jsonb_array_elements(j -> 'deals') e), 'null') end
)
select result from r order by n;
rollback;
