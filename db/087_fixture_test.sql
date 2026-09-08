-- Fixture test for 087 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-087 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the SEVEN rows of the single result set at the bottom
--   3. it ends in ROLLBACK — every fixture row is undone. Do not commit it.
--
-- Every assertion is one ROW of one final select, not its own statement. The
-- Supabase SQL editor returns only the last statement's result, so the first
-- cut of this file (eight separate selects) showed nothing but its own last
-- line — which was a hardcoded 'PASS' and proved precisely nothing. One
-- result set or the evidence does not arrive.
--
-- What is being proved:
--   1. EXACT CENTS, per line per month, for gp / billable / pass_through /
--      agency_media_out across four line kinds at once.
--   2. NOTHING ELSE MOVED — billable + pass_through is digit-for-digit 058's
--      old billable formula for every row in the whole view, fixture and real
--      data alike. This is the safety argument for the change: the only thing
--      that happened is that one component was given its own name.
--   3. SCOPE — client-funded search/social and programmatic are untouched:
--      their pass_through is 0 and their billable is what it always was.
--   4. FORECAST_PAGE — plan_month's revenue rises by fee-only for the agency
--      search line while GP is unchanged, i.e. the chart's revenue line sheds
--      exactly the media and nothing more.
--   5. CASH IS WHOLE — cashflow_forecast's contracted inflow still collects
--      the media rebill: the delta is the full invoiced amount including
--      pass_through, so 087 moved no cash.
--   6. AGENCY MEDIA LEAVES ONCE — out_agency_media picks up the media, and
--      out_contracted_cogs picks up ONLY the programmatic line's implied
--      cost. Under 086 it picked up both and the budget left twice.
--   7. COLUMN ORDER — pass_through is the LAST column of the view. `create or
--      replace view` can only append, so if a later migration ever slots it
--      in beside agency_media_out where it reads better, that migration will
--      not run. Asserted here so the constraint is remembered by a test and
--      not only by a comment.
--
-- The fixture is deliberately adversarial: one deal, four kinds, three
-- months, a mid-month flight at both ends, odd-cent amounts that force
-- rounding in every direction, an explicit per-month override on the
-- agency-funded line (a human number — never scaled), and a client-funded
-- social line sitting beside the agency-funded search line in the SAME deal,
-- which is the mixed-funding case 027 exists for. A single-kind fixture would
-- pass while getting the scope wrong.

begin;

-- ------------------------------------------------------------- the fixture --
-- Months are relative to today so the file keeps working whenever it is run.
-- m1..m3 are all future months, which is what puts them in cashflow's
-- contracted terms, and they sit inside cashflow_forecast(24)'s horizon with
-- room for the longest payment lag.
create temp table _fx_m as
select (date_trunc('month', current_date) + interval '1 month')::date as m1,
       (date_trunc('month', current_date) + interval '2 month')::date as m2,
       (date_trunc('month', current_date) + interval '3 month')::date as m3;

create temp table _fx_before as
select coalesce(sum(in_contracted_expected), 0) as in_contracted,
       coalesce(sum(out_agency_media), 0)       as agency_media,
       coalesce(sum(out_contracted_cogs), 0)    as contracted_cogs
from cashflow_forecast(24);

create temp table _fx_fp_before as
select (forecast_page((select m1 from _fx_m), (select m3 from _fx_m)) -> 'plan_month') as pm;

insert into clients (id, name, active)
values ('f0f0f0f0-0000-0000-0000-000000000087', '_fx087 Rebill Test Client', true);

insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-000000000d87',
       'f0f0f0f0-0000-0000-0000-000000000087',
       '_fx087 mixed-funding deal', 'active', 'manual',
       (m1 + 9)::date,          -- starts mid-month
       (m3 + 14)::date          -- ends mid-month
from _fx_m;

-- kind, budget/amount, fee, margin, funding — one of each case that matters
insert into deal_lines (id, deal_id, kind, budget, amount, fee_pct, margin_pct,
                        media_funding, billing_day)
values
  -- EMG pays & rebills: the line 087 is about
  ('f0f0f0f0-0000-0000-0000-0000000000a1', 'f0f0f0f0-0000-0000-0000-000000000d87',
   'search', 20000033, 0, 12.345, null, 'agency', 'last'),
  -- client pays direct: must be completely unaffected
  ('f0f0f0f0-0000-0000-0000-0000000000a2', 'f0f0f0f0-0000-0000-0000-000000000d87',
   'social', 10000019, 0, 15.000, null, 'client', 'last'),
  -- programmatic: bills its media through as revenue, by decision, and is the
  -- ONLY thing out_contracted_cogs may now pick up. Explicit margin so the
  -- test does not depend on the programmatic_margin_default setting.
  ('f0f0f0f0-0000-0000-0000-0000000000a3', 'f0f0f0f0-0000-0000-0000-000000000d87',
   'programmatic', 5000021, 0, 10.000, 30.000, 'client', 'last'),
  -- a flat kind, to prove the non-media path is untouched
  ('f0f0f0f0-0000-0000-0000-0000000000a4', 'f0f0f0f0-0000-0000-0000-000000000d87',
   'retainer', 0, 1234567, 0, null, 'client', 'first');

-- explicit override on the agency line's middle month: a human number, taken
-- exactly as typed
insert into deal_line_months (deal_line_id, month, budget)
select 'f0f0f0f0-0000-0000-0000-0000000000a1', m2, 30000077 from _fx_m;

-- ------------------------------------------------------ expected, by hand ---
-- Hard-coded so the test is not a restatement of the view's own arithmetic:
--   search m1/m3  fee = round(20000033 * 12.345 / 100) = round(2469004.07385)
--                     = 2469004         pass = 20000033
--   search m2     fee = round(30000077 * 12.345 / 100) = round(3703509.50565)
--                     = 3703510         pass = 30000077
--   social        fee = round(10000019 * 15 / 100)     = round(1500002.85)
--                     = 1500003         pass = 0
--   programmatic  gp  = round(5000021*30/100 + 5000021*10/100)
--                     = round(2000008.4) = 2000008
--                 bill= 5000021 + round(500002.1) = 5000021 + 500002 = 5500023
--   retainer      gp  = bill = 1234567
create temp table _fx_want (kind text, month date, gp bigint, billable bigint,
                            pass_through bigint, agency_media_out bigint);
insert into _fx_want
select 'search', m1, 2469004, 2469004, 20000033, 20000033 from _fx_m union all
select 'search', m2, 3703510, 3703510, 30000077, 30000077 from _fx_m union all
select 'search', m3, 2469004, 2469004, 20000033, 20000033 from _fx_m union all
select 'social', m1, 1500003, 1500003, 0, 0 from _fx_m union all
select 'social', m2, 1500003, 1500003, 0, 0 from _fx_m union all
select 'social', m3, 1500003, 1500003, 0, 0 from _fx_m union all
select 'programmatic', m1, 2000008, 5500023, 0, 0 from _fx_m union all
select 'programmatic', m2, 2000008, 5500023, 0, 0 from _fx_m union all
select 'programmatic', m3, 2000008, 5500023, 0, 0 from _fx_m union all
select 'retainer', m1, 1234567, 1234567, 0, 0 from _fx_m union all
select 'retainer', m2, 1234567, 1234567, 0, 0 from _fx_m union all
select 'retainer', m3, 1234567, 1234567, 0, 0 from _fx_m;

create temp table _fx_got as
select f.kind::text as kind, f.month, f.gp, f.billable, f.pass_through, f.agency_media_out
from v_deal_month_forecast f
where f.deal_id = 'f0f0f0f0-0000-0000-0000-000000000d87';

-- rows where the view and the hand-computed expectation disagree
create temp table _fx_bad as
select coalesce(g.kind, w.kind) as kind, coalesce(g.month, w.month) as month,
       g.gp as g_gp, g.billable as g_bill, g.pass_through as g_pass,
       g.agency_media_out as g_out,
       w.gp as w_gp, w.billable as w_bill, w.pass_through as w_pass,
       w.agency_media_out as w_out
from _fx_want w full join _fx_got g on g.kind = w.kind and g.month = w.month
where g.kind is null or w.kind is null
   or g.gp is distinct from w.gp
   or g.billable is distinct from w.billable
   or g.pass_through is distinct from w.pass_through
   or g.agency_media_out is distinct from w.agency_media_out;

create temp table _fx_fp_after as
select (forecast_page((select m1 from _fx_m), (select m3 from _fx_m)) -> 'plan_month') as pm;

create temp table _fx_after as
select coalesce(sum(in_contracted_expected), 0) as in_contracted,
       coalesce(sum(out_agency_media), 0)       as agency_media,
       coalesce(sum(out_contracted_cogs), 0)    as contracted_cogs
from cashflow_forecast(24);

-- what forecast_page's plan_month gained per month, against what it should have
create temp table _fx_fp_delta as
select m.month,
  coalesce((select (e ->> 'gp')::bigint from jsonb_array_elements(a.pm) e
            where (e ->> 'month')::date = m.month), 0)
  - coalesce((select (e ->> 'gp')::bigint from jsonb_array_elements(b.pm) e
            where (e ->> 'month')::date = m.month), 0) as d_gp,
  coalesce((select (e ->> 'billable')::bigint from jsonb_array_elements(a.pm) e
            where (e ->> 'month')::date = m.month), 0)
  - coalesce((select (e ->> 'billable')::bigint from jsonb_array_elements(b.pm) e
            where (e ->> 'month')::date = m.month), 0) as d_bill
from _fx_fp_after a cross join _fx_fp_before b
cross join (select m1 as month from _fx_m union all select m2 from _fx_m
            union all select m3 from _fx_m) m;

-- ============================ THE RESULT: seven rows, read them all ========
-- Expected cash deltas over the 24-half-month horizon:
--   contracted in    = everything invoiced, pass_through included
--                    = 22469037 + 33703587 + 22469037   (search fee + media)
--                    + 1500003*3 + 5500023*3 + 1234567*3
--                    = 78641661 + 4500009 + 16500069 + 3703701 = 103345440
--   agency media out = 20000033 + 30000077 + 20000033 = 70000143
--   contracted COGS  = programmatic only: (5500023 - 2000008) * 3 = 10500045
-- Under 086 the last one would have been 10500045 + 70000143 — the budget
-- leaving a second time. That is row 6b.
with r(n, result) as (

  select 1, case
    when (select count(*) from _fx_got) = 12 and not exists (select 1 from _fx_bad)
    then '1. EXACT CENTS, 12 LINE-MONTHS, 4 KINDS: PASS'
    else '1. EXACT CENTS: FAIL — rows=' || (select count(*) from _fx_got)::text
         || ' · ' || coalesce((select string_agg(format(
              '%s %s got(gp=%s bill=%s pass=%s out=%s) want(gp=%s bill=%s pass=%s out=%s)',
              kind, month, g_gp, g_bill, g_pass, g_out, w_gp, w_bill, w_pass, w_out), '; ')
            from _fx_bad), 'no row-level mismatch, so the count is the problem')
    end

  union all
  -- every row in the whole view, real deals included: 058's formula restated
  -- from the shipped file is the definition of "nothing moved"
  select 2, case when not exists (
      select 1
      from v_deal_month_forecast f
      join deal_lines dl on dl.id = f.deal_line_id
      left join deal_line_months dlm on dlm.deal_line_id = dl.id and dlm.month = f.month
      where f.billable + f.pass_through is distinct from (
        case f.kind
          when 'retainer'     then coalesce(dlm.amount, dl.amount)
          when 'custom'       then coalesce(dlm.amount, dl.amount)
          when 'creative'     then case when f.label like 'creative:hourly%'
               then round(dl.rate * coalesce(dlm.hours, dl.hours_per_month))::bigint
               else coalesce(dlm.amount, dl.amount) end
          when 'hourly'       then round(dl.rate * coalesce(dlm.hours, dl.hours_per_month))::bigint
          when 'search'       then round(coalesce(dlm.budget, dl.budget) * dl.fee_pct / 100)::bigint
               + case when f.media_funding = 'agency' then coalesce(dlm.budget, dl.budget) else 0 end
          when 'social'       then round(coalesce(dlm.budget, dl.budget) * dl.fee_pct / 100)::bigint
               + case when f.media_funding = 'agency' then coalesce(dlm.budget, dl.budget) else 0 end
          when 'programmatic' then coalesce(dlm.budget, dl.budget)
               + round(coalesce(dlm.budget, dl.budget) * dl.fee_pct / 100)::bigint
        end)
    ) then '2. BILLABLE + PASS_THROUGH == 058 BILLABLE, ALL '
           || (select count(*)::text from v_deal_month_forecast) || ' VIEW ROWS: PASS'
    else '2. BILLABLE + PASS_THROUGH == 058 BILLABLE: FAIL — '
         || (select count(*)::text from (
              select 1 from v_deal_month_forecast f
              join deal_lines dl on dl.id = f.deal_line_id
              left join deal_line_months dlm on dlm.deal_line_id = dl.id and dlm.month = f.month
              where f.billable + f.pass_through is distinct from (
                case f.kind
                  when 'retainer'     then coalesce(dlm.amount, dl.amount)
                  when 'custom'       then coalesce(dlm.amount, dl.amount)
                  when 'creative'     then case when f.label like 'creative:hourly%'
                       then round(dl.rate * coalesce(dlm.hours, dl.hours_per_month))::bigint
                       else coalesce(dlm.amount, dl.amount) end
                  when 'hourly'       then round(dl.rate * coalesce(dlm.hours, dl.hours_per_month))::bigint
                  when 'search'       then round(coalesce(dlm.budget, dl.budget) * dl.fee_pct / 100)::bigint
                       + case when f.media_funding = 'agency' then coalesce(dlm.budget, dl.budget) else 0 end
                  when 'social'       then round(coalesce(dlm.budget, dl.budget) * dl.fee_pct / 100)::bigint
                       + case when f.media_funding = 'agency' then coalesce(dlm.budget, dl.budget) else 0 end
                  when 'programmatic' then coalesce(dlm.budget, dl.budget)
                       + round(coalesce(dlm.budget, dl.budget) * dl.fee_pct / 100)::bigint
                end)) x) || ' rows disagree' end

  union all
  -- pass_through is nonzero ONLY for agency-funded search/social, whole view.
  -- Programmatic in particular must not have acquired one.
  select 3, case when not exists (
           select 1 from v_deal_month_forecast
           where pass_through <> 0
             and not (kind in ('search','social') and media_funding = 'agency'))
    then '3. PASS_THROUGH SCOPED TO AGENCY SEARCH/SOCIAL: PASS'
    else '3. PASS_THROUGH SCOPED: FAIL — leaked onto '
         || coalesce((select string_agg(distinct kind::text || '/' || media_funding::text, ', ')
             from v_deal_month_forecast where pass_through <> 0
               and not (kind in ('search','social') and media_funding = 'agency')), '?')
    end

  union all
  -- the chart's forward revenue sheds exactly the media and nothing else
  select 4, case when not exists (
      select 1 from _fx_fp_delta d
      join (select month, sum(gp) as gp, sum(billable) as bill from _fx_want group by month) w
        on w.month = d.month
      where d.d_gp <> w.gp or d.d_bill <> w.bill)
    then '4. FORECAST_PAGE PLAN_MONTH REVENUE IS FEE-ONLY: PASS'
    else '4. FORECAST_PAGE PLAN_MONTH: FAIL — ' || coalesce((
      select string_agg(format('%s d_gp=%s want=%s d_bill=%s want=%s',
               d.month, d.d_gp, w.gp, d.d_bill, w.bill), '; ')
      from _fx_fp_delta d
      join (select month, sum(gp) as gp, sum(billable) as bill from _fx_want group by month) w
        on w.month = d.month
      where d.d_gp <> w.gp or d.d_bill <> w.bill), '?') end

  union all
  select 5, case when (a.in_contracted - b.in_contracted) = 103345440
    then '5. CONTRACTED INFLOW STILL COLLECTS THE REBILL: PASS'
    else '5. CONTRACTED INFLOW: FAIL — delta '
         || (a.in_contracted - b.in_contracted)::text || ', want 103345440'
         || case when (a.in_contracted - b.in_contracted) = 103345440 - 70000143
                 then ' — short by exactly the media: pass_through is not being invoiced'
                 else ' (a small miss means a payment lag pushed cash past the horizon)' end
    end
  from _fx_after a cross join _fx_before b

  union all
  select 6, case when (a.agency_media - b.agency_media) = 70000143
    then '6a. AGENCY MEDIA LEAVES ONCE (out_agency_media): PASS'
    else '6a. AGENCY MEDIA OUT: FAIL — delta '
         || (a.agency_media - b.agency_media)::text || ', want 70000143' end
  from _fx_after a cross join _fx_before b

  union all
  select 7, case when (a.contracted_cogs - b.contracted_cogs) = 10500045
    then '6b. CONTRACTED COGS IS PROGRAMMATIC ONLY: PASS'
    else '6b. CONTRACTED COGS: FAIL — delta '
         || (a.contracted_cogs - b.contracted_cogs)::text || ', want 10500045'
         || case when (a.contracted_cogs - b.contracted_cogs) = 10500045 + 70000143
                 then ' — that is exactly the old double count, the kind filter did not take'
                 else '' end end
  from _fx_after a cross join _fx_before b

  union all
  -- pass_through must be the view's LAST column: create-or-replace can only
  -- append, so a future migration that moves it will simply not run
  select 8, case when (
      select attname from pg_attribute
      where attrelid = 'v_deal_month_forecast'::regclass and attnum > 0 and not attisdropped
      order by attnum desc limit 1) = 'pass_through'
    then '7. PASS_THROUGH IS THE LAST VIEW COLUMN: PASS'
    else '7. COLUMN ORDER: FAIL — last column is '
         || coalesce((select attname from pg_attribute
             where attrelid = 'v_deal_month_forecast'::regclass and attnum > 0 and not attisdropped
             order by attnum desc limit 1), '?')
         || ', so create-or-replace will reject the next edit' end
)
select result from r order by n;

rollback;
