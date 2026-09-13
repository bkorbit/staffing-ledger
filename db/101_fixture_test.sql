-- Fixture test for 101 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-101 applied, then
-- re-run 078 and 097's fixtures: both must still PASS.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
--   1. NEW       — an approved scope with a marginal-band search line (rebate
--                  2% of the fee), a programmatic line (rebate 2% of media) and
--                  an hourly line promotes as a manual deal: EVERY month row of
--                  v_deal_month_forecast (gp, billable, pass_through, fee,
--                  rebate) equals scope_months — the handoff identity; the deal
--                  is flight_locked and carries scope_id; the scope's reserved
--                  hours now carry the deal (hours_page.deal_planned = 80);
--                  the scope is promoted with a 'promote' version; a second
--                  promote is refused
--   2. HUBSPOT   — a HubSpot deal whose line_items would flight ONE retainer,
--                  with an approved 3-line scope on different dates: promote_
--                  scope → 3 lines set_by promotion:scope, the SCOPE's dates,
--                  flight_locked, a promotions row, the approval consumed,
--                  deals.scope_id set; promote_approval again → already
--   3. FALLBACK  — a HubSpot deal with no scope still flights from line_items
--                  (078's path, set_by promotion:line-items)
--   4. GUARDS    — a proposed (not approved) scope is refused; a stranger is
--                  refused
--   5. EXTEND    — a re-scope of a live retainer deal: closed months keep their
--                  frozen 1,000,000c; from this month the old line is 0 and the
--                  new 1,500,000c line runs; flight_end moved; flight_locked
--   6. ATOMIC    — a two-deal scope whose second deal cannot promote (HubSpot
--                  id not in the mirror) writes NOTHING: no deal, no
--                  promoted_deal_id, scope still approved
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * promote_approval: drop the scope lookup                       -> row 2 (1 line, HubSpot dates)
--   * promote_scope: skip relink_scope_assignments                   -> row 1 (deal_planned)
--   * promote_scope: extend without the zero rows for old lines       -> row 5 (2,500,000 this month)
--   * promote_scope: catch SCOPE_ABORT per deal instead of raising    -> row 6
--   * promote_scope_lines: drop rebate_basis                          -> row 1 (rebate rows)

begin;
create temp table _fx as
select date_trunc('month', current_date)::date                        as cur,
       (date_trunc('month', current_date) - interval '1 month')::date  as m1,
       (date_trunc('month', current_date) - interval '2 month')::date  as m2,
       (date_trunc('month', current_date) + interval '1 month')::date  as n1,
       (date_trunc('month', current_date) + interval '2 month')::date  as n2;
insert into settings (key, value, set_by) values
  ('scope_approver_emails', '["boss@fx101"]'::jsonb, 'fx101'),
  ('programmatic_margin_default', '35'::jsonb, 'fx101'),
  ('hubspot_promote_pipelines', '["sales"]'::jsonb, 'fx101')
on conflict (key) do update set value = excluded.value;

insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000101', '_fx101 Client', true);
insert into qbo_projects (id, name, hidden) values ('fx101-p1', '_fx101 P1', false), ('fx101-p2', '_fx101 P2', false), ('fx101-p3', '_fx101 P3', false);
insert into staff (id, name, department, active, tracks_capacity) values ('f0f0f0f0-0000-0000-0000-000000000b01', '_fx101 P', 'Paid Media', true, true);
insert into comp_periods (staff_id, starts_on, kind, hourly_cost, weekly_capacity)
select 'f0f0f0f0-0000-0000-0000-000000000b01'::uuid, (m2 - 60)::date, 'hourly'::comp_kind, 5000, 40 from _fx;

-- ---- 1. NEW
create temp table _s1 as select ((save_scope(jsonb_build_object(
  'name', '_fx101 S1', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000101',
  'deals', jsonb_build_array(jsonb_build_object('name', '_fx101 new deal', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', (select cur from _fx), 'flight_end', (select (n1 + 27)::date from _fx),
    'lines', jsonb_build_array(
      jsonb_build_object('kind', 'search', 'fee_pct', 0, 'media_funding', 'agency',
        'structure', jsonb_build_object('fee', jsonb_build_object('mode', 'marginal', 'bands', jsonb_build_array(
            jsonb_build_object('upto', 5000000, 'pct', 15), jsonb_build_object('upto', 15000000, 'pct', 12), jsonb_build_object('upto', null, 'pct', 10))),
          'fee_min', 500000, 'rebate', jsonb_build_object('pct', 2, 'basis', 'fee')),
        'months', jsonb_build_object((select cur::text from _fx), jsonb_build_object('budget', 12000000), (select n1::text from _fx), jsonb_build_object('budget', 2000000))),
      jsonb_build_object('kind', 'programmatic', 'fee_pct', 5, 'margin_pct', 30, 'budget', 10000000,
        'structure', jsonb_build_object('prog', jsonb_build_object('model', 'fee_margin'), 'rebate', jsonb_build_object('pct', 2, 'basis', 'media'))),
      jsonb_build_object('kind', 'hourly', 'label', 'SEO', 'rate', 20000, 'hours_per_month', 40)))),
  'dept_months', jsonb_build_array(jsonb_build_object('department', 'Paid Media', 'month', (select cur from _fx), 'hours', 40, 'source', 'manual')),
  'staff_months', jsonb_build_array(
    jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-000000000b01', 'department', 'Paid Media', 'month', (select cur from _fx), 'hours', 40),
    jsonb_build_object('staff_id', 'f0f0f0f0-0000-0000-0000-000000000b01', 'department', 'Paid Media', 'month', (select n1 from _fx), 'hours', 40))
), 'seller@fx101', 'v1')) ->> 'scope_id')::uuid as id;
select set_scope_status((select id from _s1), 'proposed', 'seller@fx101');
select approve_scope((select id from _s1), 'boss@fx101');
create temp table _sm1 as select * from scope_months((select id from _s1));
create temp table _p1 as select promote_scope((select id from _s1), 'boss@fx101', '{}'::jsonb) as r;
create temp table _d1 as select * from deals where scope_id = (select id from _s1);
create temp table _v1 as select * from v_deal_month_forecast where deal_id = (select id from _d1);
create temp table _p1b as select promote_scope((select id from _s1), 'boss@fx101', '{}'::jsonb) as r;
create temp table _hp1 as
select (x ->> 'planned_hours')::numeric as h from hours_page((select cur from _fx), (select n1 from _fx)) hp,
       jsonb_array_elements(hp -> 'deal_planned') x where x ->> 'deal_id' = (select id::text from _d1);

-- ---- 2. HUBSPOT with an approved scope
insert into pipeline_deals (hubspot_deal_id, name, company, campaign_start, campaign_end, is_won, pipeline, line_items, amount)
select '__fx101_HS1', '_fx101 HS deal', '_fx101 Client', (cur + 5)::date, (n1 + 20)::date, true, 'sales',
       '[{"name":"Media: Paid Search Media","amount":"60000"}]'::jsonb, 60000 from _fx;
create temp table _s2 as select ((create_scope('hubspot', '__fx101_HS1', null, 'seller@fx101', null)) ->> 'scope_id')::uuid as id;
-- reshape it: three lines, the scope's own dates
create temp table _sd2 as select id from scope_deals where scope_id = (select id from _s2);
select save_scope(jsonb_build_object(
  'id', (select id from _s2), 'name', '_fx101 S2', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000101',
  'deals', jsonb_build_array(jsonb_build_object('id', (select id from _sd2), 'name', '_fx101 HS deal', 'origin_kind', 'hubspot', 'promote_mode', 'hubspot',
    'hubspot_deal_id', '__fx101_HS1', 'flight_start', (select (cur + 1)::date from _fx), 'flight_end', (select (n1 + 27)::date from _fx),
    'lines', jsonb_build_array(
      jsonb_build_object('kind', 'retainer', 'amount', 400000),
      jsonb_build_object('kind', 'search', 'fee_pct', 10, 'budget', 6000000),
      jsonb_build_object('kind', 'hourly', 'label', 'CRO', 'rate', 15000, 'hours_per_month', 10))))
), 'seller@fx101', 'reshaped');
select set_scope_status((select id from _s2), 'proposed', 'seller@fx101');
select approve_scope((select id from _s2), 'boss@fx101');
create temp table _p2 as select promote_scope((select id from _s2), 'boss@fx101', jsonb_build_object((select id::text from _sd2), 'fx101-p1')) as r;
create temp table _d2 as select * from deals where hubspot_deal_id = '__fx101_HS1';
create temp table _pa2 as select promote_approval('__fx101_HS1') as r;

-- ---- 3. HUBSPOT without a scope
insert into pipeline_deals (hubspot_deal_id, name, company, campaign_start, campaign_end, is_won, pipeline, line_items, amount)
select '__fx101_HS2', '_fx101 HS plain', '_fx101 Client', cur, (n1 + 20)::date, true, 'sales',
       '[{"name":"Media: Paid Search Media","amount":"60000"},{"name":"Fees: Paid Search Fee","amount":"6000"}]'::jsonb, 66000 from _fx;
insert into promotion_approvals (hubspot_deal_id, client_id, qbo_project_id, approved_by)
values ('__fx101_HS2', 'f0f0f0f0-0000-0000-0000-000000000101', 'fx101-p2', 'boss@fx101');
create temp table _pa3 as select promote_approval('__fx101_HS2') as r;
create temp table _d3 as select * from deals where hubspot_deal_id = '__fx101_HS2';

-- ---- 4. GUARDS
create temp table _s3 as select ((save_scope(jsonb_build_object('name', '_fx101 S3', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000101',
  'deals', jsonb_build_array(jsonb_build_object('name', 'x', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', (select cur from _fx), 'flight_end', (select n1 from _fx), 'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 100))))),
  'seller@fx101', null)) ->> 'scope_id')::uuid as id;
select set_scope_status((select id from _s3), 'proposed', 'seller@fx101');
create temp table _p3 as select promote_scope((select id from _s3), 'boss@fx101', '{}'::jsonb) as r;
create temp table _p3b as select promote_scope((select id from _s1), 'stranger@fx101', '{}'::jsonb) as r;

-- ---- 5. EXTEND a live retainer deal
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, qbo_project_id)
select 'f0f0f0f0-0000-0000-0000-000000000d01'::uuid, 'f0f0f0f0-0000-0000-0000-000000000101'::uuid, '_fx101 D0', 'active'::deal_status, 'manual'::deal_origin, m2, (cur + 27)::date, 'fx101-p3' from _fx;
insert into deal_lines (id, deal_id, kind, amount, billing_day) values ('f0f0f0f0-0000-0000-0000-000000000e01', 'f0f0f0f0-0000-0000-0000-000000000d01', 'retainer', 1000000, 'first');
insert into deal_line_months (deal_line_id, month, amount, set_by)
select 'f0f0f0f0-0000-0000-0000-000000000e01'::uuid, m2, 1000000, 'freeze-on-close' from _fx union all
select 'f0f0f0f0-0000-0000-0000-000000000e01'::uuid, m1, 1000000, 'freeze-on-close' from _fx;
create temp table _s4 as select ((save_scope(jsonb_build_object('name', '_fx101 S4', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000101',
  'deals', jsonb_build_array(jsonb_build_object('name', '_fx101 D0 renewal', 'origin_kind', 'deal', 'promote_mode', 'extend',
    'source_deal_id', 'f0f0f0f0-0000-0000-0000-000000000d01',
    'flight_start', (select m2 from _fx), 'flight_end', (select (n2 + 27)::date from _fx),
    'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 1500000))))),
  'seller@fx101', null)) ->> 'scope_id')::uuid as id;
select set_scope_status((select id from _s4), 'proposed', 'seller@fx101');
select approve_scope((select id from _s4), 'boss@fx101');
create temp table _p4 as select promote_scope((select id from _s4), 'boss@fx101', '{}'::jsonb) as r;
create temp table _v4 as select month, sum(gp) as gp from v_deal_month_forecast where deal_id = 'f0f0f0f0-0000-0000-0000-000000000d01' group by month;
create temp table _d4 as select * from deals where id = 'f0f0f0f0-0000-0000-0000-000000000d01';

-- ---- 6. ATOMIC: second deal's HubSpot id is not in the mirror
create temp table _s5 as select ((save_scope(jsonb_build_object('name', '_fx101 S5', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000101',
  'deals', jsonb_build_array(
    jsonb_build_object('ord', 0, 'name', '_fx101 S5 first', 'origin_kind', 'new', 'promote_mode', 'new',
      'flight_start', (select cur from _fx), 'flight_end', (select n1 from _fx), 'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 100))),
    jsonb_build_object('ord', 1, 'name', '_fx101 S5 second', 'origin_kind', 'hubspot', 'promote_mode', 'hubspot', 'hubspot_deal_id', '__fx101_MISSING',
      'flight_start', (select cur from _fx), 'flight_end', (select n1 from _fx), 'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 100))))),
  'seller@fx101', null)) ->> 'scope_id')::uuid as id;
select set_scope_status((select id from _s5), 'proposed', 'seller@fx101');
select approve_scope((select id from _s5), 'boss@fx101');
create temp table _p5 as select promote_scope((select id from _s5), 'boss@fx101', jsonb_build_object((select id::text from scope_deals where scope_id = (select id from _s5) and ord = 1), 'fx101-p3')) as r;

with r(n, result) as (
  select 1, case when (select r ->> 'ok' from _p1) = 'true'
                  and (select count(*) from _d1) = 1
                  and (select flight_locked and status = 'won' and origin = 'manual' from _d1)
                  and (select count(*) from _v1) = 6
                  and not exists (select 1 from _sm1 s join _v1 v on v.kind = s.kind and v.month = s.month
                                  where s.gp is distinct from v.gp or s.billable is distinct from v.billable or s.pass_through is distinct from v.pass_through
                                     or s.fee is distinct from v.fee or s.rebate is distinct from v.rebate)
                  and (select sum(rebate) from _v1) = (select sum(rebate) from _sm1) and (select sum(rebate) from _v1) > 0
                  and (select count(*) from assignments where scope_id = (select id from _s1) and deal_id = (select id from _d1)) = 2
                  and (select h from _hp1) = 80
                  and (select status from scopes where id = (select id from _s1)) = 'promoted'
                  and exists (select 1 from scope_versions where scope_id = (select id from _s1) and reason = 'promote')
                  and (select r ->> 'ok' from _p1b) = 'false'
    then '1. NEW deal: every view row equals scope_months (gp, billable, pass_through, fee, rebate), flight_locked, 80h relinked, scope promoted, second promote refused: PASS'
    else '1. NEW: FAIL — ' || coalesce((select r::text from _p1), 'null') || ' deals ' || (select count(*) from _d1)::text
         || ' rows ' || (select count(*) from _v1)::text || ' mismatches ' ||
         coalesce((select string_agg(s.kind || ' ' || s.month || ' gp ' || s.gp || '→' || v.gp || ' reb ' || s.rebate || '→' || v.rebate, '; ')
                   from _sm1 s join _v1 v on v.kind = s.kind and v.month = s.month
                   where s.gp is distinct from v.gp or s.rebate is distinct from v.rebate or s.fee is distinct from v.fee), 'none')
         || ' planned ' || coalesce((select h::text from _hp1), 'null') || ' status ' || (select status from scopes where id = (select id from _s1)) end
  union all
  select 2, case when (select r ->> 'ok' from _p2) = 'true'
                  and (select count(*) from _d2) = 1
                  and (select count(*) from deal_lines where deal_id = (select id from _d2) and set_by = 'promotion:scope') = 3
                  and (select flight_start = (select (cur + 1)::date from _fx) and flight_end = (select (n1 + 27)::date from _fx) and flight_locked from _d2)
                  and (select scope_id from _d2) = (select id from _s2)
                  and exists (select 1 from promotions where hubspot_deal_id = '__fx101_HS1')
                  and not exists (select 1 from promotion_approvals where hubspot_deal_id = '__fx101_HS1')
                  and (select r ->> 'already' from _pa2) = 'true'
                  and (select status from scopes where id = (select id from _s2)) = 'promoted'
    then '2. HUBSPOT with approved scope: 3 scope lines, the scope''s dates, flight_locked, promotions row, approval consumed, promote_approval again → already: PASS'
    else '2. HUBSPOT: FAIL — ' || coalesce((select r::text from _p2), 'null') || ' lines ' || (select count(*) from deal_lines where deal_id = (select id from _d2))::text
         || ' deal ' || coalesce((select flight_start::text || '→' || flight_end::text || ' locked ' || flight_locked::text from _d2), 'none')
         || ' again ' || coalesce((select r::text from _pa2), 'null') end
  union all
  select 3, case when (select r ->> 'ok' from _pa3) = 'true' and (select r ->> 'flighted' from _pa3) = 'true'
                  and (select count(*) from deal_lines where deal_id = (select id from _d3) and set_by = 'promotion:line-items') = 1
                  and (select r ->> 'scope_id' from _pa3) is null
                  and (select not flight_locked from _d3)
    then '3. FALLBACK no scope → line_items flight one search line (078 path), not locked: PASS'
    else '3. FALLBACK: FAIL — ' || coalesce((select r::text from _pa3), 'null') end
  union all
  select 4, case when (select r ->> 'ok' from _p3) = 'false' and (select r ->> 'reason' from _p3) like '%approved%'
                  and (select r ->> 'ok' from _p3b) = 'false' and (select r ->> 'reason' from _p3b) like 'only an approver%'
                  and not exists (select 1 from deals where scope_id = (select id from _s3))
    then '4. GUARDS proposed scope refused, stranger refused, nothing written: PASS'
    else '4. GUARDS: FAIL — ' || coalesce((select r::text from _p3), 'null') || ' / ' || coalesce((select r::text from _p3b), 'null') end
  union all
  select 5, case when (select r ->> 'ok' from _p4) = 'true'
                  and (select gp from _v4 where month = (select m2 from _fx)) = 1000000
                  and (select gp from _v4 where month = (select m1 from _fx)) = 1000000
                  and (select gp from _v4 where month = (select cur from _fx)) = 1500000
                  and (select gp from _v4 where month = (select n2 from _fx)) = 1500000
                  and (select flight_end = (select (n2 + 27)::date from _fx) and flight_locked and scope_id = (select id from _s4) from _d4)
                  and (select count(*) from deal_lines where deal_id = 'f0f0f0f0-0000-0000-0000-000000000d01') = 2
    then '5. EXTEND closed months keep 1,000,000c, this month on 1,500,000c (old line ended, new line pinned to 0 in the past), flight_end moved, locked: PASS'
    else '5. EXTEND: FAIL — ' || coalesce((select r::text from _p4), 'null') || ' months: ' || coalesce((select string_agg(month || ' ' || gp, '; ' order by month) from _v4), 'none') end
  union all
  select 6, case when (select r ->> 'ok' from _p5) = 'false'
                  and (select r ->> 'reason' from _p5) like '%mirror%'
                  and not exists (select 1 from deals where scope_id = (select id from _s5))
                  and not exists (select 1 from scope_deals where scope_id = (select id from _s5) and promoted_deal_id is not null)
                  and (select status from scopes where id = (select id from _s5)) = 'approved'
    then '6. ATOMIC second deal fails → nothing written, scope still approved: PASS'
    else '6. ATOMIC: FAIL — ' || coalesce((select r::text from _p5), 'null') || ' deals ' || (select count(*) from deals where scope_id = (select id from _s5))::text end
)
select result from r order by n;
rollback;
