-- Fixture test for 089 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-089 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the SIX rows of the single result set at the bottom
--   3. it ends in ROLLBACK — every fixture row is undone. Do not commit it.
--
-- What is being proved:
--   1. SUM OF PARTS — client_detail's months equal project_detail's months
--      summed across the client's two deals, cent for cent, every column.
--   2. WEEKS SUM — the same for hours per (week, department).
--   3. REMAINDER OUT — an invoice on the client's QB parent that no deal
--      claims does NOT move the client's actual revenue (the table's client
--      total excludes it; the chart must match the row above it).
--   4. OTHER CLIENT OUT — a second client's deal, hours and invoices never
--      leak in.
--   5. SHARED PROJECT ONCE — two deals claiming the SAME QB project count its
--      invoice once, not twice.
--   6. ENGAGEMENT — min flight_start / max flight_end across the deals; the
--      month list spans it.
--
-- Adversarial on purpose: two deals with different flights, a shared QB
-- project between them, an unclaimed sibling project with money, a second
-- client with everything, and mid-month dates throughout.

begin;

create temp table _fx_m as
select (date_trunc('month', current_date) - interval '4 month')::date as m0,
       (date_trunc('month', current_date) - interval '3 month')::date as m1,
       (date_trunc('month', current_date) - interval '2 month')::date as m2,
       (date_trunc('month', current_date) - interval '1 month')::date as m3,
       date_trunc('month', current_date)::date                       as cur;

insert into qbo_projects (id, name, is_project, parent_id)
values ('fx089-parent', '_fx089 Client',              false, null),
       ('fx089-p1',     '_fx089 Client:Retainer',     true,  'fx089-parent'),
       ('fx089-p2',     '_fx089 Client:Programmatic', true,  'fx089-parent'),
       ('fx089-pu',     '_fx089 Client:Unclaimed',    true,  'fx089-parent'),
       ('fx089-px',     '_fx089 Other:Project',       true,  null);

insert into clients (id, name, active, qbo_customer_id)
values ('f0f0f0f0-0000-0000-0000-000000000089', '_fx089 Client', true, 'fx089-parent'),
       ('f0f0f0f0-0000-0000-0000-000000000f89', '_fx089 Other Client', true, null);

-- deal A: retainer, m0+14 → m3+10; deal B: programmatic, m1+3 → m3+20,
-- and a deal C on the SAME project as B (shared project); deal X other client
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, qbo_project_id)
select 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000089'::uuid,
       '_fx089 retainer', 'active'::deal_status, 'manual'::deal_origin, (m0 + 14)::date, (m3 + 10)::date, 'fx089-p1' from _fx_m
union all
select 'f0f0f0f0-0000-0000-0000-0000000000b9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000089'::uuid,
       '_fx089 programmatic', 'active'::deal_status, 'manual'::deal_origin, (m1 + 3)::date, (m3 + 20)::date, 'fx089-p2' from _fx_m
union all
select 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000089'::uuid,
       '_fx089 programmatic phase 2', 'active'::deal_status, 'manual'::deal_origin, (m2 + 1)::date, (m3 + 20)::date, 'fx089-p2' from _fx_m
union all
select 'f0f0f0f0-0000-0000-0000-0000000000d9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000f89'::uuid,
       '_fx089 other client deal', 'active'::deal_status, 'manual'::deal_origin, m1, m3, 'fx089-px' from _fx_m;

insert into deal_lines (id, deal_id, kind, budget, amount, fee_pct, margin_pct, media_funding, billing_day)
values ('f0f0f0f0-0000-0000-0000-0000000000e9', 'f0f0f0f0-0000-0000-0000-0000000000a9', 'retainer', 0, 1234567, 0, null, 'client', 'first'),
       ('f0f0f0f0-0000-0000-0000-0000000000f9', 'f0f0f0f0-0000-0000-0000-0000000000b9', 'programmatic', 5000021, 0, 10.000, 30.000, 'client', 'last'),
       ('f0f0f0f0-0000-0000-0000-000000000109', 'f0f0f0f0-0000-0000-0000-0000000000c9', 'programmatic', 1000000, 0, 10.000, 30.000, 'client', 'last'),
       ('f0f0f0f0-0000-0000-0000-000000000119', 'f0f0f0f0-0000-0000-0000-0000000000d9', 'retainer', 0, 9999999, 0, null, 'client', 'first');

insert into staff (id, name, department, active)
values ('f0f0f0f0-0000-0000-0000-000000000129', '_fx089 Media', 'Paid Media', true),
       ('f0f0f0f0-0000-0000-0000-000000000139', '_fx089 Creative', 'Creative', true);

insert into time_entries (id, staff_id, deal_id, client_id, worked_on, hours, department)
select 'fx089-t1', 'f0f0f0f0-0000-0000-0000-000000000129'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000a9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000089'::uuid, m1 + 8,  5.00, 'Paid Media' from _fx_m union all
select 'fx089-t2', 'f0f0f0f0-0000-0000-0000-000000000129'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000b9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000089'::uuid, m1 + 9,  2.50, 'Paid Media' from _fx_m union all
select 'fx089-t3', 'f0f0f0f0-0000-0000-0000-000000000139'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000b9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000089'::uuid, m2 + 15, 4.25, 'Creative' from _fx_m union all
select 'fx089-t4', 'f0f0f0f0-0000-0000-0000-000000000139'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000c9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000089'::uuid, m2 + 15, 1.75, 'Creative' from _fx_m union all
-- other client's hours: must not appear
select 'fx089-t5', 'f0f0f0f0-0000-0000-0000-000000000129'::uuid, 'f0f0f0f0-0000-0000-0000-0000000000d9'::uuid, 'f0f0f0f0-0000-0000-0000-000000000f89'::uuid, m1 + 8, 77.00, 'Paid Media' from _fx_m;

insert into qbo_accounts (id, name, fully_qualified_name, account_type, derived_class)
values ('fx089-cogs', '_fx089 Media Cost', '_fx089 Media Cost', 'Cost of Goods Sold', 'cogs');

insert into invoices (id, client_id, qbo_project_id, issued_on, total, balance)
select 'fx089-i1', 'f0f0f0f0-0000-0000-0000-000000000089'::uuid, 'fx089-p1', m1 + 2,  1234567, 0 from _fx_m union all
select 'fx089-i2', 'f0f0f0f0-0000-0000-0000-000000000089'::uuid, 'fx089-p2', m2 + 25, 5500023, 0 from _fx_m union all
select 'fx089-i3', 'f0f0f0f0-0000-0000-0000-000000000089'::uuid, 'fx089-p2', m3 + 5,  6600000, 0 from _fx_m union all
-- unclaimed sibling project: real money on the client's parent, no deal — OUT
select 'fx089-i4', 'f0f0f0f0-0000-0000-0000-000000000089'::uuid, 'fx089-pu', m2 + 10, 8888888, 0 from _fx_m union all
-- other client — OUT
select 'fx089-i5', 'f0f0f0f0-0000-0000-0000-000000000f89'::uuid, 'fx089-px', m2 + 10, 7777777, 0 from _fx_m;

insert into bills (id, kind, vendor_name, issued_on, total)
select 'fx089-b1', 'bill'::cost_kind, '_fx089 DSP', m2 + 26, 2100000 from _fx_m;
insert into bill_lines (id, bill_id, line_no, account_name, amount, qbo_project_id, account_id)
values ('fx089-bl1', 'fx089-b1', 1, '_fx089 Media Cost', 2100000, 'fx089-p2', 'fx089-cogs');

-- ------------------------------------------------------------- results ---
create temp table _fx_cd as select client_detail('f0f0f0f0-0000-0000-0000-000000000089') as j;

create temp table _fx_cd_m as
select month, rev_actual, cogs_actual, gp_actual, rev_plan, gp_plan
from _fx_cd, jsonb_to_recordset(j -> 'months')
  as x(month date, rev_actual bigint, cogs_actual bigint, gp_actual bigint, rev_plan bigint, gp_plan bigint);
create temp table _fx_cd_w as
select week, department, hours from _fx_cd, jsonb_to_recordset(j -> 'weeks') as x(week date, department text, hours numeric);

-- project_detail per deal, summed — the "sum of parts" reference. The shared
-- project p2 is claimed by deals B and C, so the per-deal actuals for p2 count
-- TWICE in this naive sum; the reference therefore takes actuals per DISTINCT
-- project and plan per deal, which is what "the client's figures" means.
create temp table _fx_pd as
select d.id as deal_id, d.qbo_project_id, project_detail(d.id) as j
from deals d where d.client_id = 'f0f0f0f0-0000-0000-0000-000000000089';
create temp table _fx_ref_plan as
select month, sum(rev_plan) as rev_plan, sum(gp_plan) as gp_plan
from _fx_pd, jsonb_to_recordset(j -> 'months') as x(month date, rev_plan bigint, gp_plan bigint)
group by month;
create temp table _fx_ref_act as
select month, sum(rev_actual) as rev_actual, sum(cogs_actual) as cogs_actual
from (select distinct on (qbo_project_id) qbo_project_id, j from _fx_pd where qbo_project_id is not null) p,
     jsonb_to_recordset(p.j -> 'months') as x(month date, rev_actual bigint, cogs_actual bigint)
where rev_actual is not null
group by month;
create temp table _fx_ref_w as
select week, department, sum(hours) as hours
from _fx_pd, jsonb_to_recordset(j -> 'weeks') as x(week date, department text, hours numeric)
group by week, department;

with r as (
  select 1 as n, case when not exists (
      select 1 from _fx_cd_m c
      full join _fx_ref_plan p on p.month = c.month
      full join _fx_ref_act  a on a.month = c.month
      where c.month is null
         or coalesce(c.rev_plan, 0) is distinct from coalesce(p.rev_plan, 0)
         or coalesce(c.gp_plan, 0)  is distinct from coalesce(p.gp_plan, 0)
         or c.rev_actual  is distinct from a.rev_actual
         or c.cogs_actual is distinct from a.cogs_actual)
    then '1. MONTHS = SUM OF THE DEALS'' project_detail (plan per deal, actual per distinct project): PASS'
    else '1. MONTHS SUM: FAIL — ' || coalesce((select string_agg(format('%s c(rev=%s cogs=%s rp=%s gp=%s) ref(rev=%s cogs=%s rp=%s gp=%s)',
           coalesce(c.month, p.month, a.month), c.rev_actual, c.cogs_actual, c.rev_plan, c.gp_plan, a.rev_actual, a.cogs_actual, p.rev_plan, p.gp_plan), '; ')
         from _fx_cd_m c full join _fx_ref_plan p on p.month = c.month full join _fx_ref_act a on a.month = c.month), '?')
    end as result
  union all
  select 2, case when not exists (
      select 1 from _fx_cd_w c full join _fx_ref_w r on r.week = c.week and r.department = c.department
      where c.week is null or r.week is null or c.hours is distinct from r.hours)
     and (select sum(hours) from _fx_cd_w) = 13.50
    then '2. WEEKS = SUM OF THE DEALS'' weeks (13.5h): PASS'
    else '2. WEEKS SUM: FAIL — total ' || coalesce((select sum(hours)::text from _fx_cd_w), 'null') end
  union all
  select 3, case when (select sum(rev_actual) from _fx_cd_m) = 1234567 + 5500023 + 6600000
    then '3. UNCLAIMED REMAINDER EXCLUDED (rev = 13,334,590 — the 8,888,888 on the parent is out): PASS'
    else '3. REMAINDER: FAIL — rev ' || coalesce((select sum(rev_actual)::text from _fx_cd_m), 'null')
         || case when (select sum(rev_actual) from _fx_cd_m) = 1234567 + 5500023 + 6600000 + 8888888 then ' — the unclaimed project leaked in' else '' end end
  union all
  select 4, case when not exists (select 1 from _fx_cd_w where hours = 77)
                  and (select sum(rev_actual) from _fx_cd_m) < 20000000
                  and not exists (select 1 from _fx_cd_m where rev_plan = 9999999)
    then '4. OTHER CLIENT EXCLUDED (hours, invoices, plan): PASS'
    else '4. OTHER CLIENT: FAIL' end
  union all
  select 5, case when (select rev_actual from _fx_cd_m where month = (select m2 from _fx_m)) = 5500023
    then '5. SHARED QB PROJECT COUNTED ONCE (m2 rev = 5,500,023, not 11,000,046): PASS'
    else '5. SHARED PROJECT: FAIL — m2 rev ' || coalesce((select rev_actual::text from _fx_cd_m where month = (select m2 from _fx_m)), 'null') end
  union all
  select 6, case when (select (j -> 'engagement' ->> 'flight_start')::date from _fx_cd) = (select (m0 + 14)::date from _fx_m)
                  and (select (j -> 'engagement' ->> 'flight_end')::date from _fx_cd) = (select (m3 + 20)::date from _fx_m)
                  and (select min(month) from _fx_cd_m) = (select m0 from _fx_m)
                  and (select max(month) from _fx_cd_m) = (select m3 from _fx_m)
                  and (select count(*) from _fx_cd_m) = 4
    then '6. ENGAGEMENT = MIN START / MAX END; MONTHS SPAN IT (4 rows): PASS'
    else '6. ENGAGEMENT: FAIL — ' || coalesce((select j ->> 'engagement' from _fx_cd), 'null') || ' · ' || (select count(*)::text from _fx_cd_m) || ' months' end
)
select result from r order by n;
rollback;
