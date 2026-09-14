-- Fixture test for 108 — NOT a migration, do not ship this file.
-- Run with 001-108 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the SINGLE result set — every line must say PASS
--   3. it ends in ROLLBACK
--
-- Two people, one retainer deal ($3,000/mo), a range of last month + this
-- month. Hours: A 4h last month, A 3h + B 6h this month on the deal, plus an
-- EXCLUDED 2h row and an internal (no deal) 1h row that must not appear in the
-- per-deal keys. Assignments: A 10h last month, A 8h + B 5h this month, and
-- A 12h NEXT month, which is outside the range and must not appear.
--
--   1. HOURS BY MONTH  — staff_hours_deal_month is exactly 3 rows, hours and
--                        cents as per day rate; it sums to staff_hours_deal
--   2. PLAN BY MONTH   — staff_deal_planned_month is exactly 3 rows (next
--                        month excluded) and sums to staff_deal_planned
--   3. FORECAST        — deal_forecast carries THIS month only (300,000c) and
--                        no closed month; measured_before is this month
--   4. RATES           — staff_rate_month prices both people for THIS month
--                        only, at staff_hourly_cost(person, month 1st)
--   5. OLD KEYS        — deal_labor 13h, staff_planned A 18h, deal_planned
--                        23h: the pre-108 keys still read as 090 wrote them
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * deal_forecast: drop `and f.month >= cur`                          -> row 3
--   * staff_rate_month: pass date_trunc(p_from) instead of greatest(..)  -> row 4
--   * staff_hours_deal_month: drop `where deal_id is not null`           -> row 1

begin;
create temp table _fx as select date_trunc('month', current_date)::date as cur,
  (date_trunc('month', current_date) - interval '1 month')::date as m0,
  (date_trunc('month', current_date) + interval '1 month')::date as n1;
insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000108', '_fx108 Client', true);
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-000000000d08', 'f0f0f0f0-0000-0000-0000-000000000108', '_fx108 retainer', 'active', 'manual', m0, (n1 + 27)::date from _fx;
insert into deal_lines (deal_id, kind, label, amount, budget, fee_pct, margin_pct, rate, hours_per_month, media_funding, billing_day) values
  ('f0f0f0f0-0000-0000-0000-000000000d08', 'retainer', null, 300000, 0, 0, null, 0, 0, 'client', 'first');
insert into staff (id, name, department, active, tracks_capacity) values
  ('f0f0f0f0-0000-0000-0000-000000000a08', '_fx108 A', 'Paid Media', true, true),
  ('f0f0f0f0-0000-0000-0000-000000000b08', '_fx108 B', 'Creative', true, true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-000000000a08'::uuid, (m0 - 400)::date, 'hourly'::comp_kind, 5000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000b08'::uuid, (m0 - 400)::date, 'hourly'::comp_kind, 7000, 40 from _fx;
insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, attribution)
select 'fx108-1', 'f0f0f0f0-0000-0000-0000-000000000a08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000108'::uuid, m0 + 2, 4.00, 'deal' from _fx union all
select 'fx108-2', 'f0f0f0f0-0000-0000-0000-000000000a08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000108'::uuid, cur,    3.00, 'deal' from _fx union all
select 'fx108-3', 'f0f0f0f0-0000-0000-0000-000000000b08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000108'::uuid, cur,    6.00, 'deal' from _fx union all
select 'fx108-4', 'f0f0f0f0-0000-0000-0000-000000000a08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000108'::uuid, cur,    2.00, 'excluded' from _fx union all
select 'fx108-5', 'f0f0f0f0-0000-0000-0000-000000000a08'::uuid, null, null, cur, 1.00, 'internal' from _fx;
insert into assignments (staff_id, deal_id, month, hours, set_by)
select 'f0f0f0f0-0000-0000-0000-000000000a08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d08'::uuid, m0, 10, 'fx108' from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000a08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d08'::uuid, cur, 8, 'fx108' from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000b08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d08'::uuid, cur, 5, 'fx108' from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000a08'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d08'::uuid, n1, 12, 'fx108' from _fx;

create temp table _hp as select hours_page((select m0 from _fx), ((select n1 from _fx) - 1)::date) as j;
create temp table _hdm as select (e ->> 'staff_id')::uuid as staff_id, (e ->> 'deal_id')::uuid as deal_id, (e ->> 'month')::date as month,
  (e ->> 'hours')::numeric as hours, (e ->> 'cost')::bigint as cost
  from _hp, jsonb_array_elements(j -> 'staff_hours_deal_month') e where e ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-000000000d08';
create temp table _pdm as select (e ->> 'staff_id')::uuid as staff_id, (e ->> 'month')::date as month, (e ->> 'planned_hours')::numeric as planned
  from _hp, jsonb_array_elements(j -> 'staff_deal_planned_month') e where e ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-000000000d08';
create temp table _df as select (e ->> 'month')::date as month, (e ->> 'billable')::bigint as billable
  from _hp, jsonb_array_elements(j -> 'deal_forecast') e where e ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-000000000d08';
create temp table _rm as select (e ->> 'staff_id')::uuid as staff_id, (e ->> 'month')::date as month, (e ->> 'rate')::bigint as rate
  from _hp, jsonb_array_elements(j -> 'staff_rate_month') e
  where e ->> 'staff_id' in ('f0f0f0f0-0000-0000-0000-000000000a08', 'f0f0f0f0-0000-0000-0000-000000000b08');
create temp table _sd as select (e ->> 'staff_id')::uuid as staff_id, (e ->> 'hours')::numeric as hours, (e ->> 'cost')::bigint as cost
  from _hp, jsonb_array_elements(j -> 'staff_hours_deal') e where e ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-000000000d08';

with r(n, result) as (
  select 1, case when (select count(*) from _hdm) = 3
                  and not exists (select 1 from _hp, jsonb_array_elements(j -> 'staff_hours_deal_month') e
                                  where e ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-000000000a08' and e ->> 'deal_id' is null)
                  and (select hours || '|' || cost from _hdm, _fx where staff_id = 'f0f0f0f0-0000-0000-0000-000000000a08' and month = m0)
                      = '4.00|' || (4 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000a08', (select m0 + 2 from _fx)))
                  and (select hours || '|' || cost from _hdm, _fx where staff_id = 'f0f0f0f0-0000-0000-0000-000000000a08' and month = cur)
                      = '3.00|' || (3 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000a08', (select cur from _fx)))
                  and (select hours || '|' || cost from _hdm, _fx where staff_id = 'f0f0f0f0-0000-0000-0000-000000000b08' and month = cur)
                      = '6.00|' || (6 * staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b08', (select cur from _fx)))
                  and (select sum(hours) || '|' || sum(cost) from _hdm where staff_id = 'f0f0f0f0-0000-0000-0000-000000000a08')
                      = (select hours || '|' || cost from _sd where staff_id = 'f0f0f0f0-0000-0000-0000-000000000a08')
    then '1. HOURS BY MONTH 3 rows (excluded + internal rows absent, no deal-less row), cents per day rate, sums to staff_hours_deal: PASS'
    else '1. HOURS BY MONTH: FAIL — ' || (select coalesce(string_agg(staff_id::text || ' ' || month || ' ' || hours || 'h ' || cost || 'c', '; ' order by month, staff_id), 'no rows') from _hdm) end
  union all
  select 2, case when (select count(*) from _pdm) = 3
                  and (select planned from _pdm, _fx where staff_id = 'f0f0f0f0-0000-0000-0000-000000000a08' and month = m0) = 10
                  and (select planned from _pdm, _fx where staff_id = 'f0f0f0f0-0000-0000-0000-000000000a08' and month = cur) = 8
                  and (select planned from _pdm, _fx where staff_id = 'f0f0f0f0-0000-0000-0000-000000000b08' and month = cur) = 5
                  and (select sum(planned) from _pdm where staff_id = 'f0f0f0f0-0000-0000-0000-000000000a08')
                      = (select (e ->> 'planned_hours')::numeric from _hp, jsonb_array_elements(j -> 'staff_deal_planned') e
                         where e ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-000000000a08' and e ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-000000000d08')
    then '2. PLAN BY MONTH 3 rows (next month outside the range absent), 10 / 8 / 5, sums to staff_deal_planned: PASS'
    else '2. PLAN BY MONTH: FAIL — ' || (select coalesce(string_agg(staff_id::text || ' ' || month || ' ' || planned, '; ' order by month, staff_id), 'no rows') from _pdm) end
  union all
  select 3, case when (select count(*) from _df) = 1
                  and (select billable from _df, _fx where month = cur) = 300000
                  and (select billable from _df, _fx where month = cur)
                      = (select sum(billable)::bigint from v_deal_month_forecast, _fx where deal_id = 'f0f0f0f0-0000-0000-0000-000000000d08' and month = cur)
                  and (select (j ->> 'measured_before')::date from _hp) = (select cur from _fx)
    then '3. FORECAST this month only, 300,000c = v_deal_month_forecast, last month absent; measured_before = this month: PASS'
    else '3. FORECAST: FAIL — ' || (select coalesce(string_agg(month || ' ' || billable, '; ' order by month), 'no rows') from _df) || ' measured_before ' || (select coalesce(j ->> 'measured_before', 'null') from _hp) end
  union all
  select 4, case when (select count(*) from _rm) = 2
                  and (select count(*) from _rm, _fx where month = cur) = 2
                  and (select rate from _rm, _fx where staff_id = 'f0f0f0f0-0000-0000-0000-000000000a08' and month = cur) = staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000a08', (select cur from _fx))
                  and (select rate from _rm, _fx where staff_id = 'f0f0f0f0-0000-0000-0000-000000000b08' and month = cur) = staff_hourly_cost('f0f0f0f0-0000-0000-0000-000000000b08', (select cur from _fx))
    then '4. RATES both people priced for this month only, at staff_hourly_cost(person, month): PASS'
    else '4. RATES: FAIL — ' || (select coalesce(string_agg(staff_id::text || ' ' || month || ' ' || rate, '; ' order by month, staff_id), 'no rows') from _rm) end
  union all
  select 5, case when (select (e ->> 'hours')::numeric from _hp, jsonb_array_elements(j -> 'deal_labor') e where e ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-000000000d08') = 13
                  and (select (e ->> 'planned_hours')::numeric from _hp, jsonb_array_elements(j -> 'staff_planned') e where e ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-000000000a08') = 18
                  and (select (e ->> 'planned_hours')::numeric from _hp, jsonb_array_elements(j -> 'deal_planned') e where e ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-000000000d08') = 23
                  and (select sum((e ->> 'hours')::numeric) from _hp, jsonb_array_elements(j -> 'staff_hours_month') e where e ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-000000000a08') = 8
    then '5. OLD KEYS deal_labor 13h, staff_planned A 18h, deal_planned 23h, A''s staff_hours_month 8h (internal counted, excluded not): PASS'
    else '5. OLD KEYS: FAIL — deal_labor ' || (select coalesce((select e ->> 'hours' from jsonb_array_elements(j -> 'deal_labor') e where e ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-000000000d08'), 'null') from _hp)
      || ' staff_planned ' || (select coalesce((select e ->> 'planned_hours' from jsonb_array_elements(j -> 'staff_planned') e where e ->> 'staff_id' = 'f0f0f0f0-0000-0000-0000-000000000a08'), 'null') from _hp) end
)
select result from r order by n;
rollback;
