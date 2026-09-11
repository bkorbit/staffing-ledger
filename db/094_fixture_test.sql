-- Fixture test for 094 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-094 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
-- Proves, for one deal with two people at two rates:
--   1. LABOR   — project_detail.labor_actual for a closed month is exactly
--                hours × staff_hourly_cost(person, day) over the rows
--                hours_page counts: 'deal', legacy null and 'mapped' rows in;
--                'timeoff' and 'excluded' rows out; a row with no staff has
--                hours but no rate and adds nothing.
--   2. PAL     — pal_actual = gp_actual − labor_actual, to the cent.
--   3. HOURS-ONLY MONTH — a closed month with hours and no invoice, plan or
--                flight coverage has a row: revenue 0, pal = −labor.
--   4. RUNNING MONTH — the current month's row carries null labor and null
--                pal (hours are logged, the month is not measured).
--   5. CLIENT  — client_detail returns the same labor and pal per month.
--   6. TABLE   — the sum over the two closed months equals hours_page's
--                deal_labor cost for the same deal and range: chart == table.
--
-- Mutation check (PGlite bed, before shipping) — each must FAIL:
--   * drop "select month from labor" from months            -> row 3
--   * drop the "< cur" guard on labor_actual                -> row 4
--   * join day_rates on staff_id only (no worked_on)        -> row 1 (two rates)
--   * client_detail: pal without "- m.labor_actual"         -> row 5

begin;
create temp table _fx_m as
select date_trunc('month', current_date)::date                        as cur,
       (date_trunc('month', current_date) - interval '1 month')::date  as m1,
       (date_trunc('month', current_date) - interval '2 month')::date  as m2;

insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000094', '_fx094 Client', true);
insert into qbo_projects (id, name, hidden) values ('fx094-proj', '_fx094 Project', false);
-- the flight covers m1 only: m2 must reach the payload through its hours alone
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, qbo_project_id)
select 'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid,
       '_fx094 deal', 'active'::deal_status, 'manual'::deal_origin, m1, (m1 + 27)::date, 'fx094-proj' from _fx_m;

insert into staff (id, name, department, active) values
  ('f0f0f0f0-0000-0000-0000-0000000000b4', '_fx094 Person P', 'Creative',   true),
  ('f0f0f0f0-0000-0000-0000-0000000000c4', '_fx094 Person Q', 'Paid Media', true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-0000000000b4'::uuid, (m2 - 60)::date, 'hourly'::comp_kind, 5000, 40 from _fx_m union all
select 'f0f0f0f0-0000-0000-0000-0000000000c4'::uuid, (m2 - 60)::date, 'hourly'::comp_kind, 8000, 40 from _fx_m;

insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department, attribution)
select 'fx094-1', 'f0f0f0f0-0000-0000-0000-0000000000b4'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, m1 + 2,  5.00, 'Creative',   'deal'         from _fx_m union all
select 'fx094-2', 'f0f0f0f0-0000-0000-0000-0000000000b4'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, m1 + 3,  3.00, 'Creative',   null           from _fx_m union all
select 'fx094-3', 'f0f0f0f0-0000-0000-0000-0000000000c4'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, m1 + 2,  1.00, 'Paid Media', 'mapped'       from _fx_m union all
select 'fx094-4', 'f0f0f0f0-0000-0000-0000-0000000000b4'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, m1 + 4,  1.25, 'Creative',   'timeoff'      from _fx_m union all
select 'fx094-5', 'f0f0f0f0-0000-0000-0000-0000000000b4'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, m1 + 5,  2.75, 'Creative',   'excluded'     from _fx_m union all
select 'fx094-6', null,                                          'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, m1 + 6,  0.50, 'Creative',   'unknown_user' from _fx_m union all
select 'fx094-7', 'f0f0f0f0-0000-0000-0000-0000000000b4'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, m2 + 10, 2.00, 'Creative',   'deal'         from _fx_m union all
select 'fx094-8', 'f0f0f0f0-0000-0000-0000-0000000000b4'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a4'::uuid, 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, cur + 1, 4.00, 'Creative',   'deal'         from _fx_m;

-- one invoice in m1, no COGS: gp_actual(m1) = 700000
insert into invoices (id, client_id, qbo_project_id, issued_on, total, balance)
select 'fx094-i1', 'f0f0f0f0-0000-0000-0000-000000000094'::uuid, 'fx094-proj', m1 + 15, 700000, 0 from _fx_m;

-- expected labor, the same function the RPC prices with
create temp table _want as
select (5 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000b4', m1 + 2)
      + 3 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000b4', m1 + 3)
      + 1 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000c4', m1 + 2))::bigint as labor_m1,
       (2 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-0000000000b4', m2 + 10))::bigint    as labor_m2
from _fx_m;

create temp table _pd as
select x.* from jsonb_to_recordset(project_detail('f0f0f0f0-0000-0000-0000-0000000000a4') -> 'months')
  as x(month date, rev_actual bigint, gp_actual bigint, labor_actual bigint, pal_actual bigint);
create temp table _cd as
select x.* from jsonb_to_recordset(client_detail('f0f0f0f0-0000-0000-0000-000000000094') -> 'months')
  as x(month date, rev_actual bigint, gp_actual bigint, labor_actual bigint, pal_actual bigint);
create temp table _hp as
select (x ->> 'cost')::bigint as cost
from hours_page((select m2 from _fx_m), (select (m1 + 27)::date from _fx_m)) hp,
     jsonb_array_elements(hp -> 'deal_labor') x
where x ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-0000000000a4';

with r(n, result) as (
  select 1, case when (select labor_actual from _pd where month = (select m1 from _fx_m)) = (select labor_m1 from _want)
    then '1. LABOR m1 = 5h+3h at P''s rate + 1h at Q''s rate (' || (select labor_m1 from _want)::text || 'c): PASS'
    else '1. LABOR m1: FAIL — got ' || coalesce((select labor_actual::text from _pd where month = (select m1 from _fx_m)), 'null')
         || ' want ' || coalesce((select labor_m1::text from _want), 'null') end
  union all
  select 2, case when (select pal_actual from _pd where month = (select m1 from _fx_m)) = 700000 - (select labor_m1 from _want)
                  and (select gp_actual from _pd where month = (select m1 from _fx_m)) = 700000
    then '2. PAL m1 = 700000 − labor: PASS'
    else '2. PAL m1: FAIL — pal ' || coalesce((select pal_actual::text from _pd where month = (select m1 from _fx_m)), 'null')
         || ' gp ' || coalesce((select gp_actual::text from _pd where month = (select m1 from _fx_m)), 'null') end
  union all
  select 3, case when (select rev_actual from _pd where month = (select m2 from _fx_m)) = 0
                  and (select pal_actual from _pd where month = (select m2 from _fx_m)) = -(select labor_m2 from _want)
    then '3. HOURS-ONLY MONTH m2 has a row, revenue 0, pal = −labor: PASS'
    else '3. HOURS-ONLY MONTH m2: FAIL — ' || coalesce((select 'rev ' || rev_actual::text || ' pal ' || coalesce(pal_actual::text, 'null')
                                                       from _pd where month = (select m2 from _fx_m)), 'no row') end
  union all
  select 4, case when exists (select 1 from _pd where month = (select cur from _fx_m))
                  and (select labor_actual from _pd where month = (select cur from _fx_m)) is null
                  and (select pal_actual from _pd where month = (select cur from _fx_m)) is null
    then '4. RUNNING MONTH labor and pal are null: PASS'
    else '4. RUNNING MONTH: FAIL — ' || coalesce((select 'labor ' || coalesce(labor_actual::text, 'null') || ' pal ' || coalesce(pal_actual::text, 'null')
                                                 from _pd where month = (select cur from _fx_m)), 'no row') end
  union all
  select 5, case when (select count(*) from _pd p join _cd c on c.month = p.month
                       where p.labor_actual is distinct from c.labor_actual or p.pal_actual is distinct from c.pal_actual) = 0
                  and (select count(*) from _cd where month in ((select m1 from _fx_m), (select m2 from _fx_m))) = 2
    then '5. CLIENT_DETAIL matches project_detail month for month: PASS'
    else '5. CLIENT_DETAIL: FAIL — ' || coalesce((select string_agg(c.month::text || ' client ' || coalesce(c.pal_actual::text, 'null')
                                                    || ' vs project ' || coalesce(p.pal_actual::text, 'null'), '; ' order by c.month)
                                                 from _cd c left join _pd p on p.month = c.month), 'no rows') end
  union all
  select 6, case when (select sum(labor_actual) from _pd where month < (select cur from _fx_m)) = (select cost from _hp)
    then '6. CHART LABOR == hours_page deal_labor (' || (select cost from _hp)::text || 'c): PASS'
    else '6. CHART vs TABLE: FAIL — chart ' || coalesce((select sum(labor_actual)::text from _pd where month < (select cur from _fx_m)), 'null')
         || ' table ' || coalesce((select cost::text from _hp), 'null') end
)
select result from r order by n;
rollback;
