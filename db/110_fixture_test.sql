-- Fixture test for 110 — NOT a migration, do not ship this file.
-- Run with 001-110 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the SINGLE result set — every line must say PASS
--   3. it ends in ROLLBACK
--
--   1. WEEKS      — deal_week_hours buckets by ISO week exactly as Home's
--                   weekStart() does (Monday), sums per deal, keeps rows with
--                   no deal out, and — deliberately, because Home's own fetch
--                   did — keeps EXCLUDED rows in. Hours logged on a Sunday and
--                   the Monday after it land in different weeks.
--   2. OLD KEYS   — every 108/109 key is byte-identical to what hours_page
--                   returned before 110, and the whole payload now has 15 keys.
--   3. PARTS      — deal_week_hours can be asked for alone, and is absent when
--                   it is not asked for.
--   4. LEDGER     — v_deal_month_gp is v_deal_month_forecast summed by month,
--                   to the cent, for both gp and billable.
--
-- Mutation check — each was applied in the PGlite bed and made its row FAIL:
--   * deal_week_hours: date_trunc('day') instead of ('week')          -> row 1
--   * deal_week_hours: drop `and deal_id is not null`                 -> row 1
--   * deal_week_hours: add 090's attribution filter (the change this
--     migration deliberately does NOT make)                           -> row 1
--   * v_deal_month_gp: sum(billable) as gp                            -> row 4
--     (which is why the fixture carries a programmatic line: it is the only
--     kind whose gp and billable differ)

begin;
create temp table _fx as select date_trunc('month', current_date)::date as cur,
  (date_trunc('month', current_date) - interval '1 month')::date as m0;
insert into clients (id, name, active) values ('c0c0c0c0-0000-0000-0000-000000000110', '_fx110 Client', true);
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'c0c0c0c0-0000-0000-0000-00000000d110'::uuid, 'c0c0c0c0-0000-0000-0000-000000000110'::uuid, '_fx110 A',
       'active'::deal_status, 'manual'::deal_origin, m0, (cur + 27)::date from _fx
union all
select 'c0c0c0c0-0000-0000-0000-00000000e110'::uuid, 'c0c0c0c0-0000-0000-0000-000000000110'::uuid, '_fx110 B',
       'active'::deal_status, 'manual'::deal_origin, m0, (cur + 27)::date from _fx;
insert into deal_lines (deal_id, kind, amount, budget, fee_pct, margin_pct, rate, hours_per_month, media_funding, billing_day) values
  ('c0c0c0c0-0000-0000-0000-00000000d110', 'retainer', 400000, 0, 0, null, 0, 0, 'client', 'first'),
  ('c0c0c0c0-0000-0000-0000-00000000e110', 'search',   0, 3000000, 10, null, 0, 0, 'agency', 'first'),
  -- programmatic, so gp and billable are DIFFERENT numbers somewhere in this
  -- ledger: its media bills through as revenue (billable = budget + fee) while
  -- only the margin is profit (087). Without it, row 4 cannot tell the two
  -- columns apart and the mutation that swaps them passes.
  ('c0c0c0c0-0000-0000-0000-00000000e110', 'programmatic', 0, 5000000, 5, 30, 0, 0, 'client', 'first');
insert into staff (id, name, department, active, tracks_capacity, start_date)
select 'c0c0c0c0-0000-0000-0000-00000000a110'::uuid, '_fx110 A', 'Paid Media', true, true, (m0 - 400)::date from _fx;
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'c0c0c0c0-0000-0000-0000-00000000a110'::uuid, (m0 - 400)::date, 'hourly'::comp_kind, 6000, 40 from _fx;

-- a Sunday and the Monday after it, deliberately: JavaScript's weekStart() and
-- date_trunc('week') must agree that they are DIFFERENT weeks
create temp table _wk as
  select (date_trunc('week', (select m0 from _fx) + 20))::date as mon;
insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, attribution)
select 'fx110-1', 'c0c0c0c0-0000-0000-0000-00000000a110'::uuid, 'c0c0c0c0-0000-0000-0000-00000000d110'::uuid,
       'c0c0c0c0-0000-0000-0000-000000000110'::uuid, (mon - 1)::date, 3.00, 'deal' from _wk   -- the Sunday before
union all
select 'fx110-2', 'c0c0c0c0-0000-0000-0000-00000000a110'::uuid, 'c0c0c0c0-0000-0000-0000-00000000d110'::uuid,
       'c0c0c0c0-0000-0000-0000-000000000110'::uuid, mon, 4.00, 'deal' from _wk               -- the Monday
union all
select 'fx110-3', 'c0c0c0c0-0000-0000-0000-00000000a110'::uuid, 'c0c0c0c0-0000-0000-0000-00000000d110'::uuid,
       'c0c0c0c0-0000-0000-0000-000000000110'::uuid, (mon + 3)::date, 1.50, 'deal' from _wk   -- same week as the Monday
union all
select 'fx110-4', 'c0c0c0c0-0000-0000-0000-00000000a110'::uuid, 'c0c0c0c0-0000-0000-0000-00000000e110'::uuid,
       'c0c0c0c0-0000-0000-0000-000000000110'::uuid, (mon + 3)::date, 2.00, 'deal' from _wk   -- same week, other deal
union all
select 'fx110-5', 'c0c0c0c0-0000-0000-0000-00000000a110'::uuid, 'c0c0c0c0-0000-0000-0000-00000000d110'::uuid,
       'c0c0c0c0-0000-0000-0000-000000000110'::uuid, (mon + 4)::date, 5.00, 'excluded' from _wk -- counted HERE, nowhere else
union all
select 'fx110-6', 'c0c0c0c0-0000-0000-0000-00000000a110'::uuid, null, null, (mon + 4)::date, 9.00, 'deal' from _wk; -- no deal: never

-- the pre-110 shape of every older key, from the 109 definition
create temp table _before as select hours_page_parts((select m0 from _fx), ((select cur from _fx) + 27)::date,
  array['staff','comp_current','staff_hours_month','staff_hours_deal','staff_planned','staff_deal_planned',
        'deal_labor','deal_planned','time_off','measured_before','staff_hours_deal_month',
        'staff_deal_planned_month','deal_forecast','staff_rate_month']) as j;
create temp table _full as select hours_page((select m0 from _fx), ((select cur from _fx) + 27)::date) as j;
create temp table _only as select hours_page_parts((select m0 from _fx), ((select cur from _fx) + 27)::date,
  array['deal_week_hours']) as j;
create temp table _wo as select hours_page_parts((select m0 from _fx), ((select cur from _fx) + 27)::date,
  array['deal_labor']) as j;
create temp table _weeks as select (e ->> 'week')::date as week, (e ->> 'deal_id')::uuid as deal_id, (e ->> 'hours')::numeric as hours
  from _full, jsonb_array_elements(j -> 'deal_week_hours') e;

with r(n, result) as (
  select 1, case when (select count(*) from _weeks) = 3
                  and (select hours from _weeks, _wk where week = (mon - 7)::date and deal_id = 'c0c0c0c0-0000-0000-0000-00000000d110') = 3.00
                  and (select hours from _weeks, _wk where week = mon and deal_id = 'c0c0c0c0-0000-0000-0000-00000000d110') = 10.50
                  and (select hours from _weeks, _wk where week = mon and deal_id = 'c0c0c0c0-0000-0000-0000-00000000e110') = 2.00
                  and (select sum(hours) from _weeks) = 15.50
    then '1. WEEKS Monday-based ISO weeks, the Sunday in its own week (3h), the Monday week 4+1.5+5 = 10.5h on deal A and 2h on deal B, the deal-less row absent, the excluded row present exactly as Home''s own fetch counted it: PASS'
    else '1. WEEKS: FAIL — ' || coalesce((select string_agg(week || ' ' || substr(deal_id::text, 1, 8) || ' ' || hours, '; ' order by week, deal_id) from _weeks), 'no rows') end
  union all
  select 2, case when not exists (select 1 from _before b, _full f, jsonb_object_keys(b.j) k where b.j -> k is distinct from f.j -> k)
                  and (select count(*) from _full, jsonb_object_keys(j) k) = 15
                  and (select count(*) from _before, jsonb_object_keys(j) k) = 14
    then '2. OLD KEYS all fourteen 108/109 keys byte-identical inside the 110 payload; the whole payload is fifteen: PASS'
    else '2. OLD KEYS: FAIL — differing: ' || coalesce((select string_agg(k, ',') from _before b, _full f, jsonb_object_keys(b.j) k where b.j -> k is distinct from f.j -> k), 'none')
      || ' keys ' || (select count(*)::text from _full, jsonb_object_keys(j) k) end
  union all
  select 3, case when (select array_agg(k) from _only, jsonb_object_keys(j) k) = array['deal_week_hours']
                  and (select j -> 'deal_week_hours' from _only) = (select j -> 'deal_week_hours' from _full)
                  and (select array_agg(k) from _wo, jsonb_object_keys(j) k) = array['deal_labor']
    then '3. PARTS deal_week_hours can be asked for alone and equals the whole payload''s; a page that does not ask does not get it: PASS'
    else '3. PARTS: FAIL — only: ' || (select array_agg(k)::text from _only, jsonb_object_keys(j) k)
      || ' without: ' || (select array_agg(k)::text from _wo, jsonb_object_keys(j) k) end
  union all
  select 4, case when not exists (
                    select 1 from v_deal_month_gp g
                    full join (select month, sum(gp)::bigint gp, sum(billable)::bigint billable
                               from v_deal_month_forecast group by month) x on x.month = g.month
                    where g.month is distinct from x.month or g.gp is distinct from x.gp or g.billable is distinct from x.billable)
                  and (select count(*) from v_deal_month_gp) > 0
                  and (select count(*) from v_deal_month_gp) < (select count(*) from v_deal_month_forecast)
    then '4. LEDGER v_deal_month_gp is v_deal_month_forecast summed by month, gp and billable to the cent, and fewer rows than it sums: PASS'
    else '4. LEDGER: FAIL — ' || coalesce((select string_agg(coalesce(g.month::text, 'null') || ' ' || coalesce(g.gp::text, 'null'), '; ')
           from v_deal_month_gp g), 'no rows') end
)
select result from r order by n;

rollback;
