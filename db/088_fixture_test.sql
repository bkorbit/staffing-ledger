-- Fixture test for 088 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-088 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the EIGHT rows of the single result set at the bottom
--   3. it ends in ROLLBACK — every fixture row is undone. Do not commit it.
--
-- One final select, one row per assertion — the Supabase SQL editor shows
-- only the last statement's result, so anything asserted earlier is invisible.
--
-- What is being proved:
--   1. WEEKS — exact hours per (Monday, department). A Sunday entry lands in
--      the week that STARTED the previous Monday, not the next one; a person
--      with no staff.department falls back to the entry's own department; an
--      hour logged before the flight opened still counts.
--   2. WEEKS SCOPE — another deal's hours never leak in (total is exact).
--   3. MONTHS — exactly the three closed flight months; the in-progress
--      month is NOT a row even though it has an invoice and a bill.
--   4. REV ACTUAL — exact cents: invoice total, minus a customer-deposit
--      line (080), minus a contra income-class bill line (025), per month.
--   5. GP ACTUAL — exact cents: revenue minus cogs-class lines only. An
--      overhead-class line on the same project must not move it.
--   6. PLAN — exact cents from v_deal_month_forecast, hand-computed
--      (programmatic + retainer, the pair whose gp ≠ billable).
--   7. AGREES WITH FORECAST_PAGE — sum of rev_actual / cogs_actual over the
--      three months equals forecast_page(m1,m3)'s rev_proj / cogs_proj for
--      the same project, digit for digit. This is the assertion that matters:
--      Project Hours and Forecast may never disagree about revenue.
--   8. MEASURED_THROUGH is last month and no actual is reported at or past
--      the current month.
--
-- Adversarial on purpose: mid-month flight at both ends, a Sunday time entry,
-- a null-department person, an off-flight entry, a second deal, a deposit
-- line, a contra line, an overhead line, and current-month money that must
-- be excluded. Single-row fixtures have passed while getting these wrong.

begin;

-- ------------------------------------------------------------- the fixture --
-- m1..m3 are the three most recent CLOSED months, so every actual falls on the
-- measured side of the line and forecast_page's `month <= cur` rev_proj covers
-- exactly the same months as project_detail's `month < cur`.
create temp table _fx_m as
select (date_trunc('month', current_date) - interval '3 month')::date as m1,
       (date_trunc('month', current_date) - interval '2 month')::date as m2,
       (date_trunc('month', current_date) - interval '1 month')::date as m3,
       date_trunc('month', current_date)::date                       as cur;

insert into clients (id, name, active)
values ('f0f0f0f0-0000-0000-0000-000000000088', '_fx088 Detail Test Client', true);

insert into qbo_projects (id, name, is_project)
values ('fx088-proj', '_fx088 Client:Detail Project', true),
       ('fx088-other', '_fx088 Client:Other Project', true);

insert into deals (id, client_id, name, status, origin, flight_start, flight_end, qbo_project_id)
select 'f0f0f0f0-0000-0000-0000-000000000d88', 'f0f0f0f0-0000-0000-0000-000000000088',
       '_fx088 programmatic + retainer', 'active', 'manual',
       (m1 + 9)::date, (m3 + 14)::date, 'fx088-proj'
from _fx_m;
-- a second deal on the same client: its hours and money must never appear
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, qbo_project_id)
select 'f0f0f0f0-0000-0000-0000-000000000e88', 'f0f0f0f0-0000-0000-0000-000000000088',
       '_fx088 other deal', 'active', 'manual', m1, m3, 'fx088-other'
from _fx_m;

-- same programmatic + retainer pair as 087's fixture, so the plan cents are
-- already known by hand:
--   programmatic gp = round(5000021*30/100 + 5000021*10/100) = 2000008
--                bill = 5000021 + round(500002.1)            = 5500023
--   retainer     gp = bill                                   = 1234567
insert into deal_lines (id, deal_id, kind, budget, amount, fee_pct, margin_pct, media_funding, billing_day)
values ('f0f0f0f0-0000-0000-0000-0000000000b1', 'f0f0f0f0-0000-0000-0000-000000000d88',
        'programmatic', 5000021, 0, 10.000, 30.000, 'client', 'last'),
       ('f0f0f0f0-0000-0000-0000-0000000000b2', 'f0f0f0f0-0000-0000-0000-000000000d88',
        'retainer', 0, 1234567, 0, null, 'client', 'first');

insert into staff (id, name, department, active)
values ('f0f0f0f0-0000-0000-0000-0000000000e1', '_fx088 Paid Media Person', 'Paid Media', true),
       ('f0f0f0f0-0000-0000-0000-0000000000e2', '_fx088 No Dept Person',    null,         true),
       ('f0f0f0f0-0000-0000-0000-0000000000e3', '_fx088 Analytics Person',  'Analytics',  true);

-- a Sunday inside m2: isodow 7. Its week began the Monday six days earlier.
create temp table _fx_days as
select (m1 + 2)::date  as before_flight,        -- logged before the flight opened
       (m1 + 10)::date as wk_a,                 -- inside the flight, two people same week
       (m2 + ((7 - extract(isodow from m2)::int) % 7))::date as sunday,
       (m2 + 3)::date  as wk_c
from _fx_m;

insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department)
select 'fx088-t1', 'f0f0f0f0-0000-0000-0000-0000000000e1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d88'::uuid,
       'f0f0f0f0-0000-0000-0000-000000000088'::uuid, before_flight, 3.00, 'Paid Media' from _fx_days
union all
select 'fx088-t2', 'f0f0f0f0-0000-0000-0000-0000000000e1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d88'::uuid,
       'f0f0f0f0-0000-0000-0000-000000000088'::uuid, wk_a, 7.50, 'Paid Media' from _fx_days
union all
-- staff.department is null -> the entry's own 'Creative' must be used
select 'fx088-t3', 'f0f0f0f0-0000-0000-0000-0000000000e2'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d88'::uuid,
       'f0f0f0f0-0000-0000-0000-000000000088'::uuid, wk_a, 4.00, 'Creative' from _fx_days
union all
-- staff.department wins over a stale entry department
select 'fx088-t4', 'f0f0f0f0-0000-0000-0000-0000000000e1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d88'::uuid,
       'f0f0f0f0-0000-0000-0000-000000000088'::uuid, sunday, 2.25, 'Old Dept Name' from _fx_days
union all
select 'fx088-t5', 'f0f0f0f0-0000-0000-0000-0000000000e3'::uuid, 'f0f0f0f0-0000-0000-0000-000000000d88'::uuid,
       'f0f0f0f0-0000-0000-0000-000000000088'::uuid, wk_c, 1.50, 'Analytics' from _fx_days
union all
-- the other deal: 99h that must not show
select 'fx088-t6', 'f0f0f0f0-0000-0000-0000-0000000000e1'::uuid, 'f0f0f0f0-0000-0000-0000-000000000e88'::uuid,
       'f0f0f0f0-0000-0000-0000-000000000088'::uuid, wk_a, 99.00, 'Paid Media' from _fx_days;

-- accounts: one of each class the actual side must treat differently
insert into qbo_accounts (id, name, fully_qualified_name, account_type, derived_class)
values ('fx088-cogs', '_fx088 Media Cost',        '_fx088 Media Cost',        'Cost of Goods Sold',      'cogs'),
       ('fx088-inc',  '_fx088 Programmatic Income','_fx088 Programmatic Income','Income',                 'income'),
       ('fx088-dep',  '_fx088 Customer Deposits', '_fx088 Customer Deposits', 'Other Current Liability', 'deposit'),
       ('fx088-oh',   '_fx088 Software',          '_fx088 Software',          'Expense',                 'overhead');

-- invoices: m1 plain; m2 carries a $15,000 deposit line (not revenue, 080);
-- m3 plain; and one in the CURRENT month that must be ignored
insert into invoices (id, client_id, qbo_project_id, issued_on, total, balance)
select 'fx088-i1', 'f0f0f0f0-0000-0000-0000-000000000088'::uuid, 'fx088-proj', m1 + 15, 7000000, 0 from _fx_m union all
select 'fx088-i2', 'f0f0f0f0-0000-0000-0000-000000000088'::uuid, 'fx088-proj', m2 + 5,  8000000, 0 from _fx_m union all
select 'fx088-i3', 'f0f0f0f0-0000-0000-0000-000000000088'::uuid, 'fx088-proj', m3 + 20, 9000000, 0 from _fx_m union all
select 'fx088-i4', 'f0f0f0f0-0000-0000-0000-000000000088'::uuid, 'fx088-proj', cur + 1, 5000000, 5000000 from _fx_m union all
-- the other project's invoice, same client
select 'fx088-i5', 'f0f0f0f0-0000-0000-0000-000000000088'::uuid, 'fx088-other', m2 + 6, 4444444, 0 from _fx_m;

insert into invoice_lines (id, invoice_id, line_no, amount, account_id, account_name)
values ('fx088-il1', 'fx088-i2', 1, 6500000, 'fx088-inc', '_fx088 Programmatic Income'),
       ('fx088-il2', 'fx088-i2', 2, 1500000, 'fx088-dep', '_fx088 Customer Deposits');

-- bills: cogs in m2 and m3; contra (income-class debit) in m3; overhead in m1
-- (must not touch GP); cogs in the current month (must be ignored)
insert into bills (id, kind, vendor_name, issued_on, total)
select 'fx088-b1', 'bill'::cost_kind, '_fx088 DSP',   m2 + 20, 2100000 from _fx_m union all
select 'fx088-b2', 'bill'::cost_kind, '_fx088 DSP',   m3 + 2,  300000  from _fx_m union all
select 'fx088-b3', 'journal'::cost_kind, '_fx088 Contra', m3 + 28, 400000 from _fx_m union all
select 'fx088-b4', 'purchase'::cost_kind, '_fx088 SaaS', m1 + 1, 555555 from _fx_m union all
select 'fx088-b5', 'bill'::cost_kind, '_fx088 DSP',   cur + 2, 1000000 from _fx_m;

insert into bill_lines (id, bill_id, line_no, account_name, amount, qbo_project_id, account_id)
values ('fx088-bl1', 'fx088-b1', 1, '_fx088 Media Cost',         2100000, 'fx088-proj', 'fx088-cogs'),
       ('fx088-bl2', 'fx088-b2', 1, '_fx088 Media Cost',         300000,  'fx088-proj', 'fx088-cogs'),
       ('fx088-bl3', 'fx088-b3', 1, '_fx088 Programmatic Income', 400000,  'fx088-proj', 'fx088-inc'),
       ('fx088-bl4', 'fx088-b4', 1, '_fx088 Software',           555555,  'fx088-proj', 'fx088-oh'),
       ('fx088-bl5', 'fx088-b5', 1, '_fx088 Media Cost',         1000000, 'fx088-proj', 'fx088-cogs');

-- ------------------------------------------------------ expected, by hand ---
--   rev m1 = 7,000,000
--   rev m2 = 8,000,000 - 1,500,000 (deposit line)      = 6,500,000
--   rev m3 = 9,000,000 -   400,000 (contra bill line)  = 8,600,000
--   cogs   m1 = 0 · m2 = 2,100,000 · m3 = 300,000  (overhead 555,555 ignored)
--   gp     m1 = 7,000,000 · m2 = 4,400,000 · m3 = 8,300,000
--   plan per month: rev = 5,500,023 + 1,234,567 = 6,734,590
--                   gp  = 2,000,008 + 1,234,567 = 3,234,575
create temp table _fx_want_m (month date, rev_actual bigint, gp_actual bigint, rev_plan bigint, gp_plan bigint);
insert into _fx_want_m
select m1, 7000000, 7000000, 6734590, 3234575 from _fx_m union all
select m2, 6500000, 4400000, 6734590, 3234575 from _fx_m union all
select m3, 8600000, 8300000, 6734590, 3234575 from _fx_m;

create temp table _fx_want_w (week date, department text, hours numeric);
insert into _fx_want_w
select date_trunc('week', before_flight)::date, 'Paid Media', 3.00 from _fx_days union all
select date_trunc('week', wk_a)::date,          'Paid Media', 7.50 from _fx_days union all
select date_trunc('week', wk_a)::date,          'Creative',   4.00 from _fx_days union all
select (sunday - 6)::date,                      'Paid Media', 2.25 from _fx_days union all
select date_trunc('week', wk_c)::date,          'Analytics',  1.50 from _fx_days;
-- the Sunday entry and the Analytics entry may share a week: merge same-key rows
create temp table _fx_want_w2 as
select week, department, sum(hours) as hours from _fx_want_w group by 1, 2;

create temp table _fx_pd as
select project_detail('f0f0f0f0-0000-0000-0000-000000000d88') as j;

create temp table _fx_got_w as
select week, department, hours
from _fx_pd, jsonb_to_recordset(j -> 'weeks') as x(week date, department text, hours numeric);

create temp table _fx_got_m as
select month, rev_actual, cogs_actual, gp_actual, rev_plan, gp_plan
from _fx_pd, jsonb_to_recordset(j -> 'months')
  as x(month date, rev_actual bigint, cogs_actual bigint, gp_actual bigint, rev_plan bigint, gp_plan bigint);

create temp table _fx_bad_w as
select coalesce(g.week, w.week) as week, coalesce(g.department, w.department) as department,
       g.hours as got, w.hours as want
from _fx_want_w2 w full join _fx_got_w g on g.week = w.week and g.department = w.department
where g.week is null or w.week is null or g.hours is distinct from w.hours;

create temp table _fx_bad_m as
select coalesce(g.month, w.month) as month,
       g.rev_actual as g_rev, w.rev_actual as w_rev,
       g.gp_actual  as g_gp,  w.gp_actual  as w_gp,
       g.rev_plan   as g_rp,  w.rev_plan   as w_rp,
       g.gp_plan    as g_gpp, w.gp_plan    as w_gpp
from _fx_want_m w full join _fx_got_m g on g.month = w.month
where g.month is null or w.month is null;

create temp table _fx_fp as
select forecast_page((select m1 from _fx_m), (select m3 from _fx_m)) as j;

-- ------------------------------------------------------------ assertions ---
with r as (
  select 1 as n, case when not exists (select 1 from _fx_bad_w)
    then '1. WEEKS EXACT (Sunday -> prior Monday, null dept falls back, off-flight counted): PASS'
    else '1. WEEKS: FAIL — ' || (select string_agg(format('%s %s got=%s want=%s', week, department, got, want), '; ') from _fx_bad_w)
    end as result
  union all
  select 2, case when (select sum(hours) from _fx_got_w) = 18.25
    then '2. WEEKS SCOPED TO THIS DEAL (total 18.25h): PASS'
    else '2. WEEKS SCOPE: FAIL — total ' || coalesce((select sum(hours)::text from _fx_got_w), 'null')
         || case when (select sum(hours) from _fx_got_w) = 117.25 then ' — the other deal''s 99h leaked in' else '' end
    end
  union all
  select 3, case when (select count(*) from _fx_got_m) = 3
                  and not exists (select 1 from _fx_got_m where month >= (select cur from _fx_m))
    then '3. MONTHS = THE THREE CLOSED FLIGHT MONTHS, CURRENT MONTH EXCLUDED: PASS'
    else '3. MONTHS: FAIL — ' || (select count(*)::text from _fx_got_m) || ' rows: '
         || coalesce((select string_agg(month::text, ', ' order by month) from _fx_got_m), '')
    end
  union all
  select 4, case when not exists (
      select 1 from _fx_got_m g join _fx_want_m w on w.month = g.month
      where g.rev_actual is distinct from w.rev_actual)
    then '4. REV ACTUAL EXACT (invoice - deposit line - contra): PASS'
    else '4. REV ACTUAL: FAIL — ' || (select string_agg(format('%s got=%s want=%s', g.month, g.rev_actual, w.rev_actual), '; ')
         from _fx_got_m g join _fx_want_m w on w.month = g.month where g.rev_actual is distinct from w.rev_actual)
    end
  union all
  select 5, case when not exists (
      select 1 from _fx_got_m g join _fx_want_m w on w.month = g.month
      where g.gp_actual is distinct from w.gp_actual)
    then '5. GP ACTUAL EXACT (cogs only; overhead line ignored): PASS'
    else '5. GP ACTUAL: FAIL — ' || (select string_agg(format('%s got=%s want=%s', g.month, g.gp_actual, w.gp_actual), '; ')
         from _fx_got_m g join _fx_want_m w on w.month = g.month where g.gp_actual is distinct from w.gp_actual)
    end
  union all
  select 6, case when not exists (
      select 1 from _fx_got_m g join _fx_want_m w on w.month = g.month
      where g.rev_plan is distinct from w.rev_plan or g.gp_plan is distinct from w.gp_plan)
    then '6. PLAN EXACT (v_deal_month_forecast billable / gp per month): PASS'
    else '6. PLAN: FAIL — ' || (select string_agg(format('%s rev got=%s want=%s gp got=%s want=%s', g.month, g.rev_plan, w.rev_plan, g.gp_plan, w.gp_plan), '; ')
         from _fx_got_m g join _fx_want_m w on w.month = g.month
         where g.rev_plan is distinct from w.rev_plan or g.gp_plan is distinct from w.gp_plan)
    end
  union all
  select 7, case when (select sum(rev_actual) from _fx_got_m) =
                      (select (x ->> 'total')::bigint from _fx_fp, jsonb_array_elements(j -> 'rev_proj') x
                       where x ->> 'qbo_project_id' = 'fx088-proj')
                 and (select sum(cogs_actual) from _fx_got_m) =
                      (select (x ->> 'total')::bigint from _fx_fp, jsonb_array_elements(j -> 'cogs_proj') x
                       where x ->> 'qbo_project_id' = 'fx088-proj')
    then '7. AGREES WITH FORECAST_PAGE rev_proj / cogs_proj TO THE CENT: PASS'
    else '7. FORECAST_PAGE AGREEMENT: FAIL — rev ' || coalesce((select sum(rev_actual)::text from _fx_got_m), 'null')
         || ' vs rev_proj ' || coalesce((select x ->> 'total' from _fx_fp, jsonb_array_elements(j -> 'rev_proj') x
                                         where x ->> 'qbo_project_id' = 'fx088-proj'), 'null')
         || ' · cogs ' || coalesce((select sum(cogs_actual)::text from _fx_got_m), 'null')
         || ' vs cogs_proj ' || coalesce((select x ->> 'total' from _fx_fp, jsonb_array_elements(j -> 'cogs_proj') x
                                          where x ->> 'qbo_project_id' = 'fx088-proj'), 'null')
    end
  union all
  select 8, case when (select (j ->> 'measured_through')::date from _fx_pd) = (select m3 from _fx_m)
                  and (select j -> 'deal' ->> 'qbo_project_id' from _fx_pd) = 'fx088-proj'
    then '8. MEASURED_THROUGH = LAST MONTH, DEAL CARRIES ITS QB PROJECT: PASS'
    else '8. MEASURED_THROUGH: FAIL — ' || coalesce((select j ->> 'measured_through' from _fx_pd), 'null')
    end
)
select result from r order by n;
rollback;
