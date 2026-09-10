-- Fixture test for 092 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-092 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every line
--      must say PASS
--   3. it ends in ROLLBACK — the fixture rows are undone. Never swap that
--      rollback for a commit.
--
-- What is being proved (all dates are relative to the real current month, so
-- this file is true whenever it is run, not only in September 2026):
--   1. CLOSED  — for a range ending in the current month, rev_proj carries a
--                project's closed-month revenue (invoice minus its contra
--                line) and NOTHING from the current month: not the retainer
--                invoice issued on the 1st, not a second invoice later in the
--                month, not the current-month contra line.
--   2. COGS    — cogs_proj likewise carries the closed month's bill only.
--   3. CURRENT — for a range that is ONLY the current month, the project has
--                no rev_proj and no cogs_proj row at all.
--   4. REV_MONTH UNCHANGED — the company-wide rev_month still moves by the
--                fixture's current-month sum exactly (the chart reads it only
--                for measured months; 092 must not have touched it).
--   5. LOCKSTEP — rev_proj_page is digit-for-digit forecast_page's rev_proj,
--                on the fixture range and on the whole year, as 051 requires.
--   6. CLOSED RANGE UNAFFECTED — a range of fully closed months returns the
--                same closed-month figure as before 092.
--
-- Adversarial on purpose: two current-month invoices (one issued on the 1st,
-- the billing day that produced the Disney double count, one on the 20th), a
-- current-month contra line and a current-month COGS bill on the SAME project
-- that also has closed-month revenue, contra and COGS. A fixture with only a
-- closed-month row would pass against 080 too and prove nothing.
--
-- Mutation check (done in the PGlite bed before shipping): put `<=` back on
-- any ONE of the three 092 lines and the file must FAIL — rev_proj → rows 1
-- and 5, cogs_proj → row 2, rev_proj_page → row 5.

begin;

-- ---------------------------------------------------------------- helpers --
create or replace function _norm(j jsonb) returns jsonb as $$
  select coalesce(jsonb_object_agg(k,
    case when jsonb_typeof(v) = 'array'
      then (select coalesce(jsonb_agg(e order by e::text), '[]'::jsonb)
            from jsonb_array_elements(v) e)
      else v end), '{}'::jsonb)
  from jsonb_each(j) as t(k, v);
$$ language sql immutable;

create temp table _fx_m as
select date_trunc('month', current_date)::date                       as cur,
       (date_trunc('month', current_date) - interval '1 month')::date as m1,
       (date_trunc('month', current_date) - interval '2 month')::date as m2;

-- rev_month for the current month BEFORE the fixture — test 4 asserts the
-- delta, so real current-month data on the database does not matter.
create temp table _pre as
select coalesce((select (e->>'total')::bigint
                 from jsonb_array_elements(forecast_page((select cur from _fx_m), (select cur from _fx_m)) -> 'rev_month') e
                 where (e->>'month')::date = (select cur from _fx_m)), 0) as rev_cur;

-- ------------------------------------------------------------- the fixture --
insert into qbo_projects (id, name, hidden) values ('fx092-proj', '_fx092 Client:Retention', false);

insert into qbo_accounts (id, name, fully_qualified_name, account_type, derived_class) values
  ('fx092-cogs', '_fx092 Media Cost',      '_fx092 Media Cost',      'Cost of Goods Sold', 'cogs'),
  ('fx092-inc',  '_fx092 Creative Income', '_fx092 Creative Income', 'Income',             'income');

-- invoices: one in the closed month m1; two in the CURRENT month (the 1st,
-- like a retainer, and the 20th)
insert into invoices (id, qbo_project_id, doc_number, issued_on, total, balance)
select 'fx092-i1', 'fx092-proj', '_FX092A', m1 + 10, 5000000, 0 from _fx_m;
insert into invoices (id, qbo_project_id, doc_number, issued_on, total, balance)
select 'fx092-i2', 'fx092-proj', '_FX092B', cur,     7000000, 7000000 from _fx_m;
insert into invoices (id, qbo_project_id, doc_number, issued_on, total, balance)
select 'fx092-i3', 'fx092-proj', '_FX092C', cur + 19, 1055000, 1055000 from _fx_m;

-- bills: contra (income-class debit) in m1 and in the current month; COGS in
-- m1 and in the current month
insert into bills (id, kind, vendor_name, issued_on, total)
select 'fx092-b1', 'journal'::cost_kind, '_fx092 Contra', m1 + 27,  200000 from _fx_m;
insert into bills (id, kind, vendor_name, issued_on, total)
select 'fx092-b2', 'journal'::cost_kind, '_fx092 Contra', cur + 3,  300000 from _fx_m;
insert into bills (id, kind, vendor_name, issued_on, total)
select 'fx092-b3', 'bill'::cost_kind,    '_fx092 Vendor', m1 + 3,  1200000 from _fx_m;
insert into bills (id, kind, vendor_name, issued_on, total)
select 'fx092-b4', 'bill'::cost_kind,    '_fx092 Vendor', cur + 5,  900000 from _fx_m;

insert into bill_lines (id, bill_id, line_no, account_name, amount, qbo_project_id, account_id) values
  ('fx092-bl1', 'fx092-b1', 1, '_fx092 Creative Income', 200000,  'fx092-proj', 'fx092-inc'),
  ('fx092-bl2', 'fx092-b2', 1, '_fx092 Creative Income', 300000,  'fx092-proj', 'fx092-inc'),
  ('fx092-bl3', 'fx092-b3', 1, '_fx092 Media Cost',      1200000, 'fx092-proj', 'fx092-cogs'),
  ('fx092-bl4', 'fx092-b4', 1, '_fx092 Media Cost',      900000,  'fx092-proj', 'fx092-cogs');

-- ------------------------------------------------------ expected, by hand ---
--   rev_proj  (m1..cur)  = 5,000,000 - 200,000                    = 4,800,000
--   cogs_proj (m1..cur)  = 1,200,000
--   rev_proj / cogs_proj (cur..cur) = no row
--   rev_month(cur) delta = 7,000,000 + 1,055,000 - 300,000        = 7,755,000
--   before 092, rev_proj (m1..cur) would have been 4,800,000 + 7,755,000
--   = 12,555,000 and cogs_proj 2,100,000 — the Disney shape.

create temp table _got as
with fp as (select forecast_page((select m1 from _fx_m), (select cur from _fx_m)) as j),
     fc as (select forecast_page((select cur from _fx_m), (select cur from _fx_m)) as j),
     fz as (select forecast_page((select m2 from _fx_m), (select m1 from _fx_m)) as j)
select
  (select (e->>'total')::bigint from fp, jsonb_array_elements(fp.j -> 'rev_proj') e
    where e->>'qbo_project_id' = 'fx092-proj')                          as rev_range,
  (select (e->>'total')::bigint from fp, jsonb_array_elements(fp.j -> 'cogs_proj') e
    where e->>'qbo_project_id' = 'fx092-proj')                          as cogs_range,
  (select count(*) from fc, jsonb_array_elements(fc.j -> 'rev_proj') e
    where e->>'qbo_project_id' = 'fx092-proj')                          as rev_cur_rows,
  (select count(*) from fc, jsonb_array_elements(fc.j -> 'cogs_proj') e
    where e->>'qbo_project_id' = 'fx092-proj')                          as cogs_cur_rows,
  (select (e->>'total')::bigint from fc, jsonb_array_elements(fc.j -> 'rev_month') e
    where (e->>'month')::date = (select cur from _fx_m))
    - (select rev_cur from _pre)                                        as rev_month_delta,
  (select (e->>'total')::bigint from fz, jsonb_array_elements(fz.j -> 'rev_proj') e
    where e->>'qbo_project_id' = 'fx092-proj')                          as rev_closed_range,
  (_norm(jsonb_build_object('r', forecast_page((select m1 from _fx_m), (select cur from _fx_m)) -> 'rev_proj'))
     = _norm(jsonb_build_object('r', rev_proj_page((select m1 from _fx_m), (select cur from _fx_m))))
   and _norm(jsonb_build_object('r', forecast_page('2026-01-01', '2026-12-01') -> 'rev_proj'))
     = _norm(jsonb_build_object('r', rev_proj_page('2026-01-01', '2026-12-01'))))
                                                                        as lockstep;

-- ========================= THE RESULT: read every row =======================
with r(n, result) as (
  select 1, case when (select rev_range from _got) = 4800000
    then '1. CLOSED MONTHS ONLY IN REV_PROJ: PASS (4,800,000)'
    else '1. CLOSED MONTHS ONLY IN REV_PROJ: FAIL — got ' || coalesce((select rev_range from _got)::text, 'no row')
         || case when (select rev_range from _got) > 4800000
                 then ' — the current month is still being counted as actual (the Disney double count)'
                 else '' end end
  union all
  select 2, case when (select cogs_range from _got) = 1200000
    then '2. CLOSED MONTHS ONLY IN COGS_PROJ: PASS (1,200,000)'
    else '2. CLOSED MONTHS ONLY IN COGS_PROJ: FAIL — got ' || coalesce((select cogs_range from _got)::text, 'no row') end
  union all
  select 3, case when (select rev_cur_rows from _got) = 0 and (select cogs_cur_rows from _got) = 0
    then '3. CURRENT-MONTH-ONLY RANGE HAS NO ACTUALS: PASS'
    else '3. CURRENT-MONTH-ONLY RANGE HAS NO ACTUALS: FAIL — rev rows '
         || (select rev_cur_rows from _got) || ', cogs rows ' || (select cogs_cur_rows from _got) end
  union all
  select 4, case when (select rev_month_delta from _got) = 7755000
    then '4. REV_MONTH STILL CARRIES THE CURRENT MONTH: PASS (+7,755,000)'
    else '4. REV_MONTH STILL CARRIES THE CURRENT MONTH: FAIL — delta '
         || coalesce((select rev_month_delta from _got)::text, 'null') || ' (092 must not touch rev_month)' end
  union all
  select 5, case when (select lockstep from _got)
    then '5. REV_PROJ_PAGE LOCKSTEP WITH FORECAST_PAGE: PASS'
    else '5. REV_PROJ_PAGE LOCKSTEP: FAIL — 051''s hand-kept copy has drifted from forecast_page' end
  union all
  select 6, case when (select rev_closed_range from _got) = 4800000
    then '6. FULLY CLOSED RANGE UNAFFECTED: PASS (4,800,000)'
    else '6. FULLY CLOSED RANGE UNAFFECTED: FAIL — got ' || coalesce((select rev_closed_range from _got)::text, 'no row') end
  union all
  select 7, '   context: months m1=' || (select m1 from _fx_m) || ' cur=' || (select cur from _fx_m)
         || '; rev_range=' || coalesce((select rev_range from _got)::text, 'null')
         || ' cogs_range=' || coalesce((select cogs_range from _got)::text, 'null')
         || ' rev_month_delta=' || coalesce((select rev_month_delta from _got)::text, 'null')
)
select result from r order by n;

rollback;
