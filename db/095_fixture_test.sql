-- Fixture test for 095 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-095 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
-- Two people (P at 37.5 h/wk, Q at 40), three deals (D1 live through next
-- month, D2 live but ended last month, D3 live and HIDDEN), counted and
-- uncounted hours in the three trailing months plus an older one, a human
-- row on (P, D1, this month), and a stale seed row on (Q, D2, this month).
--
--   1. AVERAGE   — seed hours for (P, D1) = counted 15h / 3 = 5.00, not 15/2
--                  (P logged in only two of the three months).
--   2. MONTHS    — rows exist for this month and next (D1's remaining
--                  flight), none for D2 (ended) and none for D3 (hidden).
--   3. HUMAN     — the human row keeps 12h and its set_by.
--   4. FILTER    — excluded, timeoff and older-than-window hours are not
--                  counted: Q's average is 6/3 = 2.00.
--   5. STALE     — the pre-existing seed row on (Q, D2) is deleted.
--   6. RERUN     — a second run writes the same rows, no duplicates.
--   7. CAPACITY  — P this month = round(37.5/5 × business days × 80%, 2),
--                  committed = 12 (the human row; the seed left it alone).
--   8. PAGE      — assignments_page carries the same trailing average and
--                  the seed rows with their provenance; no cost key anywhere.
--   9. CLEAR     — clear_seed_assignments deletes exactly the seed rows; the
--                  human row survives.
--
-- Mutation check (PGlite bed, before shipping) — each must FAIL:
--   * basis: divide by count(distinct month) instead of lookback   -> row 1
--   * basis: drop "d.flight_end >= cur"                            -> row 2 (D2 rows)
--   * basis: drop "not d.hidden"                                   -> row 2 (D3 rows)
--   * seed:  drop the WHERE on the upsert                          -> row 3
--   * basis: drop the attribution filter                           -> row 4
--   * seed:  drop the stale delete                                 -> row 5
--   * capacity: weekly*52/12 instead of business days              -> row 7
--   * clear: unconditional delete                                  -> row 9

begin;
create temp table _fx_m as
select date_trunc('month', current_date)::date                        as cur,
       (date_trunc('month', current_date) - interval '1 month')::date  as m1,
       (date_trunc('month', current_date) - interval '2 month')::date  as m2,
       (date_trunc('month', current_date) - interval '3 month')::date  as m3,
       (date_trunc('month', current_date) - interval '4 month')::date  as m4,
       (date_trunc('month', current_date) + interval '1 month')::date  as n1;

insert into settings (key, value, set_by) values
  ('assignments_seed_lookback_months', '3'::jsonb, 'fx095'),
  ('scope_target_utilization_pct', '80'::jsonb, 'fx095')
on conflict (key) do update set value = excluded.value;

insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000095', '_fx095 Client', true);
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, hidden)
select 'f0f0f0f0-0000-0000-0000-0000000000d1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, '_fx095 D1 live',
       'active'::deal_status, 'manual'::deal_origin, m3, (n1 + 20)::date, false from _fx_m union all
select 'f0f0f0f0-0000-0000-0000-0000000000d2'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, '_fx095 D2 ended',
       'active'::deal_status, 'manual'::deal_origin, m3, (m1 + 27)::date, false from _fx_m union all
select 'f0f0f0f0-0000-0000-0000-0000000000d3'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, '_fx095 D3 hidden',
       'active'::deal_status, 'manual'::deal_origin, m3, (n1 + 20)::date, true from _fx_m;

insert into staff (id, name, department, active, tracks_capacity) values
  ('f0f0f0f0-0000-0000-0000-0000000000b5', '_fx095 Person P', 'Paid Media',   true, true),
  ('f0f0f0f0-0000-0000-0000-0000000000c5', '_fx095 Person Q', 'Programmatic', true, true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, (m4 - 60)::date, 'hourly'::comp_kind, 5000, 37.5 from _fx_m union all
select 'f0f0f0f0-0000-0000-0000-0000000000c5'::uuid, (m4 - 60)::date, 'hourly'::comp_kind, 8000, 40   from _fx_m;

insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department, attribution)
-- P on D1: 10h in m1, 5h in m2, nothing in m3 -> 15/3 = 5.00
select 'fx095-1', 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, m1 + 3,  10.00, 'Paid Media', 'deal'     from _fx_m union all
select 'fx095-2', 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, m2 + 9,   5.00, 'Paid Media', null       from _fx_m union all
-- uncounted: excluded, timeoff, and an m4 row outside the 3-month window
select 'fx095-3', 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, m1 + 4,   4.00, 'Paid Media', 'excluded' from _fx_m union all
select 'fx095-4', 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, m1 + 5,   3.00, 'Paid Media', 'timeoff'  from _fx_m union all
select 'fx095-5', 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, m4 + 5,   8.00, 'Paid Media', 'deal'     from _fx_m union all
-- Q on D1: 6h in m3 -> 6/3 = 2.00
select 'fx095-6', 'f0f0f0f0-0000-0000-0000-0000000000c5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, m3 + 2,   6.00, 'Programmatic', 'deal'   from _fx_m union all
-- P on D2 (ended) and D3 (hidden): must produce no seed rows
select 'fx095-7', 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d2'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, m1 + 6,   7.00, 'Paid Media', 'deal'     from _fx_m union all
select 'fx095-8', 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d3'::uuid, 'f0f0f0f0-0000-0000-0000-000000000095'::uuid, m1 + 7,   9.00, 'Paid Media', 'deal'     from _fx_m;

-- a human row the seed must not touch, and a stale seed row it must delete
insert into assignments (staff_id, deal_id, month, hours, set_by)
select 'f0f0f0f0-0000-0000-0000-0000000000b5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d1'::uuid, cur, 12.00, 'human@fx095' from _fx_m union all
select 'f0f0f0f0-0000-0000-0000-0000000000c5'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d2'::uuid, cur, 3.00,  'seed:trailing-actuals' from _fx_m;

create temp table _run1 as select seed_assignments(3, 'fx095') as r;
create temp table _a1 as
select a.staff_id, a.deal_id, a.month, a.hours, a.set_by from assignments a
where a.deal_id in ('f0f0f0f0-0000-0000-0000-0000000000d1', 'f0f0f0f0-0000-0000-0000-0000000000d2', 'f0f0f0f0-0000-0000-0000-0000000000d3');

create temp table _cap as
select * from staff_capacity((select cur from _fx_m), (select cur from _fx_m))
where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000b5';
-- independent business-day count: dow 1..5
create temp table _bd as
select count(*)::int as days from _fx_m, generate_series(cur, (n1 - 1)::date, interval '1 day') d
where extract(dow from d) between 1 and 5;

create temp table _page as select assignments_page((select cur from _fx_m), (select n1 from _fx_m)) as p;

create temp table _run2 as select seed_assignments(3, 'fx095') as r;
create temp table _a2 as
select a.staff_id, a.deal_id, a.month, a.hours, a.set_by from assignments a
where a.deal_id in ('f0f0f0f0-0000-0000-0000-0000000000d1', 'f0f0f0f0-0000-0000-0000-0000000000d2', 'f0f0f0f0-0000-0000-0000-0000000000d3');

create temp table _clr as select clear_seed_assignments() as r;
create temp table _a3 as
select a.staff_id, a.deal_id, a.month, a.hours, a.set_by from assignments a
where a.deal_id in ('f0f0f0f0-0000-0000-0000-0000000000d1', 'f0f0f0f0-0000-0000-0000-0000000000d2', 'f0f0f0f0-0000-0000-0000-0000000000d3');

with r(n, result) as (
  select 1, case when (select hours from _a1 where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000b5'
                        and deal_id = 'f0f0f0f0-0000-0000-0000-0000000000d1' and month = (select n1 from _fx_m)) = 5.00
    then '1. AVERAGE (P, D1) next month = 15h/3 = 5.00: PASS'
    else '1. AVERAGE: FAIL — got ' || coalesce((select hours::text from _a1 where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000b5'
                        and deal_id = 'f0f0f0f0-0000-0000-0000-0000000000d1' and month = (select n1 from _fx_m)), 'no row') end
  union all
  select 2, case when (select count(*) from _a1 where set_by = 'seed:trailing-actuals') = 3
                  and (select count(*) from _a1 where deal_id in ('f0f0f0f0-0000-0000-0000-0000000000d2', 'f0f0f0f0-0000-0000-0000-0000000000d3')) = 0
                  and (select count(*) from _a1 where deal_id = 'f0f0f0f0-0000-0000-0000-0000000000d1'
                        and month in ((select cur from _fx_m), (select n1 from _fx_m))) = 4
    then '2. MONTHS 3 seed rows, D1 this+next month only, none for ended/hidden: PASS'
    else '2. MONTHS: FAIL — ' || (select string_agg(deal_id::text || ' ' || month::text || ' ' || hours::text || ' ' || set_by, '; ' order by deal_id, month) from _a1) end
  union all
  select 3, case when (select hours || '|' || set_by from _a1 where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000b5'
                        and deal_id = 'f0f0f0f0-0000-0000-0000-0000000000d1' and month = (select cur from _fx_m)) = '12.00|human@fx095'
    then '3. HUMAN row untouched (12h, human@fx095): PASS'
    else '3. HUMAN: FAIL — ' || coalesce((select hours || '|' || set_by from _a1 where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000b5'
                        and deal_id = 'f0f0f0f0-0000-0000-0000-0000000000d1' and month = (select cur from _fx_m)), 'no row') end
  union all
  select 4, case when (select hours from _a1 where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000c5'
                        and deal_id = 'f0f0f0f0-0000-0000-0000-0000000000d1' and month = (select cur from _fx_m)) = 2.00
    then '4. FILTER Q = 6h/3 = 2.00; excluded/timeoff/older hours not counted: PASS'
    else '4. FILTER: FAIL — got ' || coalesce((select hours::text from _a1 where staff_id = 'f0f0f0f0-0000-0000-0000-0000000000c5'
                        and deal_id = 'f0f0f0f0-0000-0000-0000-0000000000d1' and month = (select cur from _fx_m)), 'no row') end
  union all
  select 5, case when not exists (select 1 from _a1 where deal_id = 'f0f0f0f0-0000-0000-0000-0000000000d2')
                  and ((select r from _run1) ->> 'rows_deleted')::int = 1
    then '5. STALE seed row on (Q, D2) deleted: PASS'
    else '5. STALE: FAIL — rows_deleted ' || coalesce((select r ->> 'rows_deleted' from _run1), 'null') end
  union all
  select 6, case when (select count(*) from _a2) = (select count(*) from _a1)
                  and ((select r from _run2) ->> 'rows_written')::int = 3
                  and not exists (select 1 from _a1 a full join _a2 b using (staff_id, deal_id, month)
                                  where a.hours is distinct from b.hours or a.set_by is distinct from b.set_by)
    then '6. RERUN identical, 3 rows rewritten, no duplicates: PASS'
    else '6. RERUN: FAIL — run1 ' || (select count(*) from _a1)::text || ' rows, run2 ' || (select count(*) from _a2)::text
         || ' rows, rows_written ' || coalesce((select r ->> 'rows_written' from _run2), 'null') end
  union all
  select 7, case when (select capacity_hours from _cap) = round(37.5 / 5 * (select days from _bd) * 80 / 100, 2)
                  and (select committed_hours from _cap) = 12.00
                  and (select free_hours from _cap) = round(37.5 / 5 * (select days from _bd) * 80 / 100, 2) - 12.00
    then '7. CAPACITY P = 7.5h × ' || (select days from _bd)::text || ' business days × 80% = '
         || (select capacity_hours from _cap)::text || ', committed 12 (the human row; the seed skipped it): PASS'
    else '7. CAPACITY: FAIL — ' || coalesce((select 'cap ' || capacity_hours::text || ' committed ' || committed_hours::text || ' free ' || free_hours::text || ' bizdays ' || business_days::text from _cap), 'no row')
         || ' want cap ' || round(37.5 / 5 * (select days from _bd) * 80 / 100, 2)::text end
  union all
  select 8, case when (select count(*) from jsonb_array_elements((select p from _page) -> 'trailing') t
                       where t ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-0000000000b5'
                         and t ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-0000000000d1' and (t ->> 'avg_hours')::numeric = 5.00) = 1
                  and (select count(*) from jsonb_array_elements((select p from _page) -> 'assignments') a
                       where a ->> 'set_by' = 'seed:trailing-actuals'
                         and a ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-0000000000d1') = 3
                  and position('cost' in (select p::text from _page)) = 0
                  and position('rate' in (select p::text from _page)) = 0
                  and ((select p from _page) -> 'settings' ->> 'utilization_pct')::numeric = 80
    then '8. PAGE trailing 5.00, 3 seed rows with provenance, no cost/rate key: PASS'
    else '8. PAGE: FAIL — trailing ' || coalesce((select string_agg(t ->> 'avg_hours', ',') from jsonb_array_elements((select p from _page) -> 'trailing') t
                       where t ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-0000000000b5'), 'none')
         || ' seedrows ' || (select count(*) from jsonb_array_elements((select p from _page) -> 'assignments') a where a ->> 'set_by' = 'seed:trailing-actuals')::text
         || ' cost@' || position('cost' in (select p::text from _page))::text || ' rate@' || position('rate' in (select p::text from _page))::text end
  union all
  select 9, case when (select count(*) from _a3) = 1
                  and (select set_by from _a3) = 'human@fx095'
                  and ((select r from _clr) ->> 'rows_deleted')::int = 3
    then '9. CLEAR deletes the 3 seed rows, the human row survives: PASS'
    else '9. CLEAR: FAIL — ' || (select count(*) from _a3)::text || ' rows left, rows_deleted '
         || coalesce((select r ->> 'rows_deleted' from _clr), 'null') end
)
select result from r order by n;
rollback;
