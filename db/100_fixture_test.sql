-- Fixture test for 100 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-100 applied, then
-- re-run 078, 087, 088, 092, 093, 094, 097 and 099's fixtures: all must PASS.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
--   1. IDENTITY  — every kind with structure {} and no rebate: gp, billable,
--                  agency_media_out and pass_through equal 087's view body
--                  (copied verbatim below as _vdmf_087) row for row — including
--                  half-cent cases (12345 c at 12.5 %; programmatic 30 % + 8 %
--                  where rounding once gives 4691 and twice gives 4692)
--   2. STRUCTURE — a marginal-band search line with a $5,000 minimum: month 1
--                  ($120,000) fee 1,590,000 c = gp = billable = fee; month 2
--                  ($20,000) floored to 500,000 c; rebate 2 % of the fee
--   3. REBATE    — programmatic with 2 % of media: rebate 200,000 c, gp and
--                  billable UNCHANGED (gp is pre-rebate); a retainer with 5 %
--                  of "the fee" rebates 5 % of its amount
--   4. PAGE      — forecast_page.plan_month.rebate for this month; plan_deal
--                  rebate_all counts both months, rebate_future this month only
--   5. DETAIL    — project_detail and client_detail carry rebate_plan
--   6. CASHFLOW  — cashflow_forecast still runs (it reads the view by name)
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * view: price search from budget * fee_pct / 100, ignoring structure  -> row 2
--   * view: subtract the rebate inside gp                                 -> row 3
--   * forecast_page: rebate_future without the >= cur filter              -> row 4
--   * view: round programmatic twice (round(margin) + round(fee))         -> row 1 (half-cent)

begin;
create temp table _fx as
select date_trunc('month', current_date)::date                        as cur,
       (date_trunc('month', current_date) - interval '1 month')::date  as m1,
       (date_trunc('month', current_date) + interval '1 month')::date  as n1;
insert into settings (key, value, set_by) values ('programmatic_margin_default', '35'::jsonb, 'fx100')
on conflict (key) do update set value = excluded.value;

-- 087's view body, verbatim, under a scratch name
create or replace view _vdmf_087 as
with months as (
  select d.id as deal_id, d.client_id, d.status, d.reviewed_at is not null as reviewed,
         dl.id as deal_line_id, dl.kind, dl.label, dl.billing_day, dl.media_funding,
         gs.month::date as month,
         coalesce(dlm.amount, dl.amount) as amount, coalesce(dlm.budget, dl.budget) as budget,
         coalesce(dlm.hours, dl.hours_per_month) as hours, dl.fee_pct,
         coalesce(dl.margin_pct, (select (value #>> '{}')::numeric from settings where key = 'programmatic_margin_default')) as margin_pct,
         dl.rate
  from deals d join deal_lines dl on dl.deal_id = d.id
  cross join lateral generate_series(date_trunc('month', d.flight_start), date_trunc('month', d.flight_end), interval '1 month') gs(month)
  left join deal_line_months dlm on dlm.deal_line_id = dl.id and dlm.month = gs.month::date
  where d.status in ('won', 'active') and not d.hidden
)
select deal_id, deal_line_id, kind, month,
  case kind when 'retainer' then amount when 'custom' then amount
    when 'creative' then case when label like 'creative:hourly%' then round(rate * hours)::bigint else amount end
    when 'hourly' then round(rate * hours)::bigint
    when 'search' then round(budget * fee_pct / 100)::bigint when 'social' then round(budget * fee_pct / 100)::bigint
    when 'programmatic' then round(budget * margin_pct / 100 + budget * fee_pct / 100)::bigint end as gp,
  case kind when 'retainer' then amount when 'custom' then amount
    when 'creative' then case when label like 'creative:hourly%' then round(rate * hours)::bigint else amount end
    when 'hourly' then round(rate * hours)::bigint
    when 'search' then round(budget * fee_pct / 100)::bigint when 'social' then round(budget * fee_pct / 100)::bigint
    when 'programmatic' then budget + round(budget * fee_pct / 100)::bigint end as billable,
  case when kind in ('search', 'social') and media_funding = 'agency' then budget else 0 end as agency_media_out,
  case when kind in ('search', 'social') and media_funding = 'agency' then budget else 0 end as pass_through
from months;

insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000100', '_fx100 Client', true);
insert into qbo_projects (id, name, hidden) values ('fx100-proj', '_fx100 Project', false);
-- D1: every kind, plain (structure {}), flight this month..next
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, qbo_project_id)
select 'f0f0f0f0-0000-0000-0000-0000000001a0'::uuid, 'f0f0f0f0-0000-0000-0000-000000000100'::uuid, '_fx100 plain', 'active'::deal_status, 'manual'::deal_origin, cur, (n1 + 27)::date, 'fx100-proj' from _fx;
insert into deal_lines (deal_id, kind, label, amount, budget, fee_pct, margin_pct, rate, hours_per_month, media_funding, billing_day) values
  ('f0f0f0f0-0000-0000-0000-0000000001a0', 'retainer', null, 100000, 0, 0, null, 0, 0, 'client', 'first'),
  ('f0f0f0f0-0000-0000-0000-0000000001a0', 'custom', null, 500, 0, 0, null, 0, 0, 'client', 'first'),
  ('f0f0f0f0-0000-0000-0000-0000000001a0', 'creative', 'creative:hourly', 0, 0, 0, null, 15000, 10.5, 'client', 'first'),
  ('f0f0f0f0-0000-0000-0000-0000000001a0', 'creative', 'creative:retainer', 250000, 0, 0, null, 0, 0, 'client', 'first'),
  ('f0f0f0f0-0000-0000-0000-0000000001a0', 'hourly', 'SEO', 0, 0, 0, null, 20000, 12.5, 'client', 'last'),
  ('f0f0f0f0-0000-0000-0000-0000000001a0', 'search', null, 0, 12345, 12.5, null, 0, 0, 'client', 'last'),
  ('f0f0f0f0-0000-0000-0000-0000000001a0', 'social', null, 0, 7777, 7.5, null, 0, 0, 'agency', 'last'),
  ('f0f0f0f0-0000-0000-0000-0000000001a0', 'programmatic', null, 0, 99999, 0, null, 0, 0, 'client', 'last');
insert into deal_lines (id, deal_id, kind, budget, fee_pct, margin_pct, media_funding, billing_day) values
  -- 3703.5 margin + 987.6 fee = 4691.1 → 4691 rounded once; 3704 + 988 = 4692 rounded twice
  ('f0f0f0f0-0000-0000-0000-0000000001d0', 'f0f0f0f0-0000-0000-0000-0000000001a0', 'programmatic', 12345, 8, 30, 'client', 'last');
-- D2: structured lines, flight LAST month..this month (rebate_all vs rebate_future)
insert into deals (id, client_id, name, status, origin, flight_start, flight_end)
select 'f0f0f0f0-0000-0000-0000-0000000001b0'::uuid, 'f0f0f0f0-0000-0000-0000-000000000100'::uuid, '_fx100 structured', 'active'::deal_status, 'manual'::deal_origin, m1, (cur + 27)::date from _fx;
insert into deal_lines (id, deal_id, kind, fee_pct, media_funding, billing_day, structure, rebate_pct, rebate_basis) values
  ('f0f0f0f0-0000-0000-0000-0000000001c0', 'f0f0f0f0-0000-0000-0000-0000000001b0', 'search', 0, 'client', 'last',
   '{"fee":{"mode":"marginal","bands":[{"upto":5000000,"pct":15},{"upto":15000000,"pct":12},{"upto":null,"pct":10}]},"fee_min":500000}', 2, 'fee');
insert into deal_line_months (deal_line_id, month, budget)
select 'f0f0f0f0-0000-0000-0000-0000000001c0'::uuid, m1, 12000000 from _fx union all
select 'f0f0f0f0-0000-0000-0000-0000000001c0'::uuid, cur, 2000000 from _fx;
insert into deal_lines (deal_id, kind, budget, fee_pct, margin_pct, billing_day, rebate_pct, rebate_basis) values
  ('f0f0f0f0-0000-0000-0000-0000000001b0', 'programmatic', 10000000, 5, 30, 'last', 2, 'media');
insert into deal_lines (deal_id, kind, amount, billing_day, rebate_pct, rebate_basis) values
  ('f0f0f0f0-0000-0000-0000-0000000001b0', 'retainer', 1000000, 'first', 5, 'fee');

create temp table _new as select * from v_deal_month_forecast where deal_id in ('f0f0f0f0-0000-0000-0000-0000000001a0', 'f0f0f0f0-0000-0000-0000-0000000001b0');
create temp table _old as select * from _vdmf_087 where deal_id = 'f0f0f0f0-0000-0000-0000-0000000001a0';
create temp table _fp as select forecast_page((select m1 from _fx), (select n1 from _fx)) as p;
create temp table _pd as select project_detail('f0f0f0f0-0000-0000-0000-0000000001b0') as p;
create temp table _cd as select client_detail('f0f0f0f0-0000-0000-0000-000000000100') as p;
create temp table _cf as select count(*) as n from cashflow_forecast(6);

with r(n, result) as (
  select 1, case when (select count(*) from _old) = 18
                  and (select count(*) from _old o join _new n using (deal_line_id, month)
                       where o.gp is distinct from n.gp or o.billable is distinct from n.billable
                          or o.agency_media_out is distinct from n.agency_media_out or o.pass_through is distinct from n.pass_through) = 0
                  and (select bool_and(rebate = 0) from _new where deal_id = 'f0f0f0f0-0000-0000-0000-0000000001a0')
                  and (select gp from _new where kind = 'search' and deal_id = 'f0f0f0f0-0000-0000-0000-0000000001a0' and month = (select cur from _fx)) = round(12345 * 12.5 / 100)
                  and (select gp from _new where deal_line_id = 'f0f0f0f0-0000-0000-0000-0000000001d0' and month = (select cur from _fx)) = 4691
    then '1. IDENTITY 18 plain rows equal 087''s view (half-cent search 1543, programmatic 4691 rounded ONCE included), rebate 0: PASS'
    else '1. IDENTITY: FAIL — old rows ' || (select count(*) from _old)::text || ', mismatches: ' ||
         coalesce((select string_agg(o.kind || ' ' || o.month || ' gp ' || o.gp || '→' || n.gp || ' bill ' || o.billable || '→' || n.billable, '; ')
                   from _old o join _new n using (deal_line_id, month)
                   where o.gp is distinct from n.gp or o.billable is distinct from n.billable), 'none') end
  union all
  select 2, case when (select gp || '|' || billable || '|' || fee || '|' || rebate from _new where deal_line_id = 'f0f0f0f0-0000-0000-0000-0000000001c0' and month = (select m1 from _fx)) = '1590000|1590000|1590000|31800'
                  and (select gp || '|' || rebate from _new where deal_line_id = 'f0f0f0f0-0000-0000-0000-0000000001c0' and month = (select cur from _fx)) = '500000|10000'
    then '2. STRUCTURE marginal bands 1,590,000c then the $5,000 floor; rebate 2% of the fee: PASS'
    else '2. STRUCTURE: FAIL — ' || coalesce((select string_agg(month || ' gp ' || gp || ' bill ' || billable || ' fee ' || fee || ' reb ' || rebate, '; ' order by month) from _new where deal_line_id = 'f0f0f0f0-0000-0000-0000-0000000001c0'), 'no rows') end
  union all
  select 3, case when (select gp || '|' || billable || '|' || rebate from _new where kind = 'programmatic' and deal_id = 'f0f0f0f0-0000-0000-0000-0000000001b0' and month = (select cur from _fx)) = '3500000|10500000|200000'
                  and (select gp || '|' || fee || '|' || rebate from _new where kind = 'retainer' and deal_id = 'f0f0f0f0-0000-0000-0000-0000000001b0' and month = (select cur from _fx)) = '1000000|1000000|50000'
    then '3. REBATE programmatic 2% of media = 200,000c with gp/billable unchanged; retainer 5% of the fee = 50,000c: PASS'
    else '3. REBATE: FAIL — ' || coalesce((select string_agg(kind || ' gp ' || gp || ' bill ' || billable || ' fee ' || fee || ' reb ' || rebate, '; ') from _new where deal_id = 'f0f0f0f0-0000-0000-0000-0000000001b0' and month = (select cur from _fx)), 'no rows') end
  union all
  select 4, case when (select (x ->> 'rebate')::bigint from _fp, jsonb_array_elements(p -> 'plan_month') x where (x ->> 'month')::date = (select cur from _fx)) = 260000
                  and (select (x ->> 'rebate_all')::bigint from _fp, jsonb_array_elements(p -> 'plan_deal') x where x ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-0000000001b0') = 31800 + 10000 + 400000 + 100000
                  and (select (x ->> 'rebate_future')::bigint from _fp, jsonb_array_elements(p -> 'plan_deal') x where x ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-0000000001b0') = 260000
                  and (select (x ->> 'gp')::bigint from _fp, jsonb_array_elements(p -> 'plan_month') x where (x ->> 'month')::date = (select cur from _fx))
                      = (select sum(gp) from _new where month = (select cur from _fx))
    then '4. PAGE plan_month.rebate this month 260,000c; plan_deal rebate_all 541,800c, rebate_future 260,000c; gp untouched: PASS'
    else '4. PAGE: FAIL — plan_month ' || coalesce((select string_agg(x::text, '; ') from _fp, jsonb_array_elements(p -> 'plan_month') x), 'none')
         || ' plan_deal ' || coalesce((select string_agg(x::text, '; ') from _fp, jsonb_array_elements(p -> 'plan_deal') x where x ->> 'deal_id' = 'f0f0f0f0-0000-0000-0000-0000000001b0'), 'none') end
  union all
  select 5, case when (select (x ->> 'rebate_plan')::bigint from _pd, jsonb_array_elements(p -> 'months') x where (x ->> 'month')::date = (select cur from _fx)) = 260000
                  and (select (x ->> 'rebate_plan')::bigint from _cd, jsonb_array_elements(p -> 'months') x where (x ->> 'month')::date = (select cur from _fx)) = 260000
                  and (select (x ->> 'gp_plan')::bigint from _pd, jsonb_array_elements(p -> 'months') x where (x ->> 'month')::date = (select cur from _fx)) = 5000000
    then '5. DETAIL project_detail and client_detail carry rebate_plan 260,000c this month, gp_plan pre-rebate: PASS'
    else '5. DETAIL: FAIL — pd ' || coalesce((select string_agg(x::text, '; ') from _pd, jsonb_array_elements(p -> 'months') x where (x ->> 'month')::date = (select cur from _fx)), 'none') end
  union all
  select 6, case when (select n from _cf) > 0 then '6. CASHFLOW cashflow_forecast(6) still returns periods: PASS' else '6. CASHFLOW: FAIL' end
)
select result from r order by n;
rollback;
