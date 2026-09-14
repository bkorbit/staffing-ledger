-- Fixture test for 105 — NOT a migration, do not ship this file.
-- Run with 001-105 applied, then re-run 097, 101, 103 and 104's fixtures:
-- every one must still PASS to the cent (they price the same scopes through
-- the rewritten functions).
--   1. paste this whole file (it opens its own transaction)
--   2. read the SINGLE result set — every line must say PASS
--   3. it ends in ROLLBACK
--
--   1. RATES   — staff_rates_months equals staff_hourly_cost / staff_band per
--                person-month; an inactive person and a person not yet employed
--                that month are absent
--   2. LADDER  — a placeholder in a band priced by scope_labor equals
--                band_rate(dept, band, month); uncovered demand equals
--                band_rate(dept, null, month); the company fallback holds for a
--                department with nobody
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * staff_rates_months: drop the employment-date filter                -> row 1
--   * scope_labor: price placeholders from dept_all instead of dept_band  -> row 2

begin;
create temp table _fx as select date_trunc('month', current_date)::date as cur, (date_trunc('month', current_date) + interval '1 month')::date as n1;
insert into settings (key, value, set_by) values
  ('scope_comp_bands', '[{"name":"Band 1","upto_c":4500},{"name":"Band 2","upto_c":7500},{"name":"Band 3","upto_c":11500},{"name":"Band 4","upto_c":null}]'::jsonb, 'fx105')
on conflict (key) do update set value = excluded.value;
insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000105', '_fx105 Client', true);
insert into staff (id, name, department, active, tracks_capacity, start_date) values
  ('f0f0f0f0-0000-0000-0000-000000000b05', '_fx105 P', 'Paid Media', true, true, null),
  ('f0f0f0f0-0000-0000-0000-000000000c05', '_fx105 Q', 'Paid Media', true, true, null),
  ('f0f0f0f0-0000-0000-0000-000000000d05', '_fx105 R inactive', 'Paid Media', false, true, null),
  ('f0f0f0f0-0000-0000-0000-000000000e05', '_fx105 S later', 'Paid Media', true, true, (select n1 from _fx));
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-000000000b05'::uuid, (cur - 400)::date, 'hourly'::comp_kind, 5000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000c05'::uuid, (cur - 400)::date, 'hourly'::comp_kind, 8000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000d05'::uuid, (cur - 400)::date, 'hourly'::comp_kind, 9000, 40 from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000e05'::uuid, (cur - 400)::date, 'hourly'::comp_kind, 3000, 40 from _fx;
create temp table _rt as select * from staff_rates_months((select cur from _fx), (select n1 from _fx)) where staff_id in
  ('f0f0f0f0-0000-0000-0000-000000000b05','f0f0f0f0-0000-0000-0000-000000000c05','f0f0f0f0-0000-0000-0000-000000000d05','f0f0f0f0-0000-0000-0000-000000000e05');
create temp table _s as select ((save_scope(jsonb_build_object('name', '_fx105', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000105',
  'deals', jsonb_build_array(jsonb_build_object('name', 'd', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', (select cur from _fx), 'flight_end', (select (n1 + 27)::date from _fx), 'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 100)))),
  'dept_months', jsonb_build_array(
    jsonb_build_object('department', 'Paid Media', 'month', (select cur from _fx), 'hours', 30),
    jsonb_build_object('department', 'Nobody', 'month', (select cur from _fx), 'hours', 10)),
  'staff_months', jsonb_build_array(
    jsonb_build_object('staff_id', null, 'department', 'Paid Media', 'band', staff_band('f0f0f0f0-0000-0000-0000-000000000b05', (select cur from _fx)), 'month', (select cur from _fx), 'hours', 10))
), 'fx105', null)) ->> 'scope_id')::uuid as id;
create temp table _lab as select * from scope_labor((select id from _s));
-- expected: placeholder 10h at P's band rate; unassigned Paid Media 20h at the dept average; Nobody 10h at the company average
create temp table _want as
select (10 * band_rate('Paid Media', staff_band('f0f0f0f0-0000-0000-0000-000000000b05', cur), cur)
      + 20 * band_rate('Paid Media', null, cur)
      + 10 * band_rate('Nobody', null, cur))::bigint as cost from _fx;

with r(n, result) as (
  select 1, case when (select count(*) from _rt) = 5   -- P, Q in both months; S only next month; R never
                  and not exists (select 1 from _rt where staff_id = 'f0f0f0f0-0000-0000-0000-000000000d05')
                  and (select count(*) from _rt where staff_id = 'f0f0f0f0-0000-0000-0000-000000000e05') = 1
                  and (select bool_and(rate = staff_hourly_cost(staff_id, month) and band = staff_band(staff_id, month)) from _rt)
    then '1. RATES table = staff_hourly_cost / staff_band per person-month; inactive absent, later hire only from their start: PASS'
    else '1. RATES: FAIL — ' || coalesce((select string_agg(staff_id::text || ' ' || month || ' ' || coalesce(rate::text, 'null') || ' ' || coalesce(band, 'null'), '; ') from _rt), 'none') end
  union all
  select 2, case when (select cost from _lab where month = (select cur from _fx)) = (select cost from _want)
                  and (select hours from _lab where month = (select cur from _fx)) = 40
    then '2. LADDER placeholder at the band rate, uncovered at the department average, empty department at the company average = band_rate(): PASS'
    else '2. LADDER: FAIL — got ' || coalesce((select cost::text from _lab where month = (select cur from _fx)), 'null') || ' want ' || (select cost from _want)::text end
)
select result from r order by n;
rollback;
