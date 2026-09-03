-- Fixture test for 078 — NOT a migration, do not ship this file.
-- Run in a transaction against a db that already has 001-078 applied.
--
--   1. begin;
--   2. paste this whole file
--   3. every row of the result must read PASS
--   4. rollback;   -- always. It inserts a client, two QBO projects, five
--                  -- fake HubSpot deals and promotes some of them.
--
-- What it proves, in order:
--   A. the flighting math (hs_flight_lines) is cent-exact on adversarial
--      shapes — indivisible budgets, mid-month flight ends, fee-without-media,
--      multi-kind deals, folder-prefixed product names. These are the same
--      cases the deleted JS flightFromItems() was unit-tested on, and the
--      numbers below were taken from a run of BOTH implementations against
--      each other before the JS was removed.
--   B. promote_approval() writes a complete, correct deal — the approval's
--      client and project, HubSpot's EXACT campaign dates (not truncated),
--      the real approver in set_by/promoted_by, the whole mirror row as the
--      as-sold payload, and a spread whose months sum to the as-sold budget.
--   C. the once-only guard holds: promoting twice creates nothing the second
--      time and reports the deal that already exists.
--   D. bad data at write time holds the approval back INSTEAD of forcing a
--      deal through, and leaves the approval queued for the nightly retry.
--   E. an unmapped line item still promotes the deal, as a skeleton, with a
--      reason — a half-invented plan is worse than an empty one.
begin;

create temporary table t078 (ord int, section text, label text, status text) on commit drop;

-- ------------------------------------------------------------------ A ------
-- Flighting math, in isolation. No fixtures needed — it is a pure function.
insert into t078
select 1, 'A: flighting', label,
       case when got is not distinct from want then 'PASS'
            else 'FAIL — got ' || coalesce(got::text,'null') || ', want ' || coalesce(want::text,'null') end
from (
  -- $180,000 search media + $21,600 fee, Sep 14 -> Dec 20: one search line,
  -- 12% fee, four covered months, not a cent lost
  select 'search media+fee: one line, kind=search' as label,
         (f->'lines'->0->>'kind')::text as got, 'search'::text as want
  from (select hs_flight_lines('[{"name":"Paid Search Media","amount":"180000"},{"name":"Paid Search Fee","amount":"21600"}]'::jsonb,
        '2026-09-01','2026-12-01') as f) x
  union all
  select 'search media+fee: fee_pct derived from the pair',
         (f->'lines'->0->>'fee_pct'), '12.00'
  from (select hs_flight_lines('[{"name":"Paid Search Media","amount":"180000"},{"name":"Paid Search Fee","amount":"21600"}]'::jsonb,
        '2026-09-01','2026-12-01') as f) x
  union all
  select 'search media+fee: spread sums to the as-sold total (¢)',
         (select sum((value #>> '{}')::bigint)::text from jsonb_each(f->'lines'->0->'months')), '18000000'
  from (select hs_flight_lines('[{"name":"Paid Search Media","amount":"180000"},{"name":"Paid Search Fee","amount":"21600"}]'::jsonb,
        '2026-09-01','2026-12-01') as f) x
  union all
  select 'search media+fee: 4 covered months',
         (select count(*)::text from jsonb_each(f->'lines'->0->'months')), '4'
  from (select hs_flight_lines('[{"name":"Paid Search Media","amount":"180000"},{"name":"Paid Search Fee","amount":"21600"}]'::jsonb,
        '2026-09-01','2026-12-01') as f) x
  union all
  -- an indivisible budget: the remainder lands on the LAST month, total intact
  select 'indivisible budget: remainder on the last month, total intact (¢)',
         (select sum((value #>> '{}')::bigint)::text from jsonb_each(f->'lines'->0->'months')), '10000001'
  from (select hs_flight_lines('[{"name":"Programmatic Media","amount":"100000.01"}]'::jsonb,
        '2026-01-01','2026-03-01') as f) x
  union all
  select 'indivisible budget: last month carries the odd cent (¢)',
         (f->'lines'->0->'months'->>'2026-03-01'), '3333335'
  from (select hs_flight_lines('[{"name":"Programmatic Media","amount":"100000.01"}]'::jsonb,
        '2026-01-01','2026-03-01') as f) x
  union all
  -- retainer-ish items collapse into ONE flat monthly amount, no overrides
  select 'creative retainer: $90,000 / 6 months = $15,000/mo (¢)',
         (f->'lines'->0->>'amount'), '1500000'
  from (select hs_flight_lines('[{"name":"Creative Retainer","amount":"90000"}]'::jsonb,
        '2026-01-01','2026-06-01') as f) x
  union all
  select 'creative retainer: a flat line writes no month overrides',
         jsonb_typeof(f->'lines'->0->'months'), 'null'
  from (select hs_flight_lines('[{"name":"Creative Retainer","amount":"90000"}]'::jsonb,
        '2026-01-01','2026-06-01') as f) x
  union all
  select 'three retainer sources collapse into one line',
         jsonb_array_length(f->'lines')::text, '1'
  from (select hs_flight_lines('[{"name":"Creative Services","amount":"30000"},{"name":"Dashboard","amount":"6000"},{"name":"Paid Search Hourly","amount":"9000"}]'::jsonb,
        '2026-01-01','2026-04-01') as f) x
  union all
  -- a fee with nothing to be a percentage OF becomes a flat monthly retainer
  select 'fee without media -> flat monthly retainer',
         (f->'lines'->0->>'kind') || ' ' || (f->'lines'->0->>'amount'), 'retainer 9583333'
  from (select hs_flight_lines('[{"name":"Programmatic Buying Fee","amount":"575000"}]'::jsonb,
        '2026-06-01','2026-11-01') as f) x
  union all
  -- HubSpot prefixes product names with their folder; only the last segment matters
  select 'folder-prefixed, mixed-case names still map',
         (f->'lines'->0->>'kind') || ' ' || (f->'lines'->0->>'fee_pct'), 'social 15.00'
  from (select hs_flight_lines('[{"name":"Media: Paid Social Media","amount":"100000"},{"name":"  MEDIA : Paid Social Fee ","amount":"15000"}]'::jsonb,
        '2026-03-01','2026-05-01') as f) x
  union all
  -- a six-item, three-kind deal: line order follows first appearance
  select 'multi-kind deal: 4 lines in first-appearance order',
         jsonb_array_length(f->'lines') || ' ' ||
         (select string_agg(l->>'kind', ',' order by o) from jsonb_array_elements(f->'lines') with ordinality t(l,o)),
         '4 search,social,retainer,programmatic'
  from (select hs_flight_lines('[{"name":"Paid Search Media","amount":"60000"},{"name":"Paid Search Fee","amount":"9000"},
        {"name":"Paid Social Media","amount":"40000"},{"name":"Planning","amount":"12000"},
        {"name":"Programmatic Media","amount":"250000"},{"name":"Programmatic Buying Fee","amount":"50000"}]'::jsonb,
        '2026-02-01','2026-07-01') as f) x
  union all
  -- the refusals: each says WHY, and flights nothing
  select 'one unmapped item -> no lines, names the item',
         jsonb_array_length(f->'lines') || ' ' || (f->>'reason'), '0 unmapped line item: Mystery'
  from (select hs_flight_lines('[{"name":"Programmatic Media","amount":"500000"},{"name":"Mystery","amount":"5"}]'::jsonb,
        '2026-01-01','2026-02-01') as f) x
  union all
  select 'no items -> no lines, a reason', (f->>'reason'), 'no line items'
  from (select hs_flight_lines('[]'::jsonb, '2026-01-01','2026-03-01') as f) x
  union all
  select 'end before start -> no flight months', (f->>'reason'), 'no flight months'
  from (select hs_flight_lines('[{"name":"Creative Retainer","amount":"5000"}]'::jsonb,
        '2026-06-01','2026-01-01') as f) x
  union all
  select 'items summing to zero -> no lines, a reason', (f->>'reason'), 'items sum to nothing'
  from (select hs_flight_lines('[{"name":"Paid Search Media","amount":"0"},{"name":"Creative Retainer","amount":"0"}]'::jsonb,
        '2026-01-01','2026-03-01') as f) x
) a;

-- ------------------------------------------------------------ fixtures ------
-- Deliberately adversarial: a mid-month flight (Sep 14 -> Dec 20, so the
-- covered months are Sep..Dec and the exact dates must survive), a deal whose
-- dates went missing in HubSpot after a human approved it, and a deal with a
-- product nobody has mapped.
insert into clients (id, name, active)
values ('00000000-0000-0000-0000-0000000f078a', '__fixture 078 client', true);
insert into qbo_projects (id, name)
values ('__fx078_p1', '__fixture 078 project 1'), ('__fx078_p2', '__fixture 078 project 2');

insert into pipeline_deals (hubspot_deal_id, name, company, stage, probability, amount,
                            close_date, campaign_start, campaign_end, is_won, jobcode, line_items, url, pipeline)
values
  ('__fx078_D1', 'Fixture Akron World Cup', 'Fixture Co', 'Closed Won', 1.0, 12000000,
   '2026-08-01', '2026-09-14', '2026-12-20', true, '26akrn260101',
   '[{"name":"Paid Search Media","amount":"180000"},{"name":"Paid Search Fee","amount":"21600"}]',
   'http://example.invalid/D1', 'Sales Pipeline'),
  ('__fx078_D2', 'Fixture Dateless Deal', 'Fixture Co', 'Closed Won', 1.0, 9000000,
   '2026-08-15', null, null, true, null, '[]', 'http://example.invalid/D2', 'Sales Pipeline'),
  ('__fx078_D3', 'Fixture Unmapped Product', 'Fixture Co', 'Closed Won', 1.0, 100000,
   '2026-08-01', '2026-05-01', '2026-07-31', true, null,
   '[{"name":"Mystery Product","amount":"1000"}]', 'http://example.invalid/D3', 'Sales Pipeline');

insert into promotion_approvals (hubspot_deal_id, client_id, qbo_project_id, approved_by)
values ('__fx078_D1', '00000000-0000-0000-0000-0000000f078a', '__fx078_p1', 'fixture@078.test'),
       ('__fx078_D2', '00000000-0000-0000-0000-0000000f078a', '__fx078_p2', 'fixture@078.test'),
       ('__fx078_D3', '00000000-0000-0000-0000-0000000f078a', '__fx078_p2', 'fixture@078.test');

-- One statement per call, deliberately: '2nd' must run AFTER '1st' for the
-- once-only test to mean anything, and UNION ALL does not promise an
-- evaluation order.
create temporary table t078_ret (k text primary key, v jsonb) on commit drop;
insert into t078_ret values ('1st',      promote_approval('__fx078_D1'));
insert into t078_ret values ('2nd',      promote_approval('__fx078_D1'));  -- C: the once-only guard
insert into t078_ret values ('dateless', promote_approval('__fx078_D2'));
insert into t078_ret values ('unmapped', promote_approval('__fx078_D3'));
insert into t078_ret values ('unknown',  promote_approval('__fx078_never_existed'));

-- ------------------------------------------------------------------ B ------
insert into t078
select 2, 'B: the write', label,
       case when got is not distinct from want then 'PASS'
            else 'FAIL — got ' || coalesce(got,'null') || ', want ' || coalesce(want,'null') end
from (
  select 'deal takes the approval''s client and project' as label,
         d.client_id::text || ' ' || d.qbo_project_id as got,
         '00000000-0000-0000-0000-0000000f078a __fx078_p1' as want
  from deals d where d.hubspot_deal_id = '__fx078_D1'
  union all
  select 'flight keeps HubSpot''s EXACT dates, not month-truncated',
         d.flight_start::text || '..' || d.flight_end::text, '2026-09-14..2026-12-20'
  from deals d where d.hubspot_deal_id = '__fx078_D1'
  union all
  select 'status/origin/jobcode/promoted_at set at the door',
         d.status::text || ' ' || d.origin::text || ' ' || d.jobcode || ' ' || (d.promoted_at is not null)::text,
         'won hubspot 26akrn260101 true'
  from deals d where d.hubspot_deal_id = '__fx078_D1'
  union all
  select 'set_by is the real approver, never a sync literal', d.set_by, 'fixture@078.test'
  from deals d where d.hubspot_deal_id = '__fx078_D1'
  union all
  select 'promotion records the approver and the whole as-sold mirror row',
         p.promoted_by || ' ' || (p.source_payload->>'amount') || ' ' || (p.source_payload->>'company'),
         'fixture@078.test 12000000 Fixture Co'
  from promotions p where p.hubspot_deal_id = '__fx078_D1'
  union all
  select 'promotion points at the deal it created', (p.deal_id = d.id)::text, 'true'
  from promotions p join deals d on d.hubspot_deal_id = p.hubspot_deal_id
  where p.hubspot_deal_id = '__fx078_D1'
  union all
  select 'one search line, 12% fee, billed last, machine-marked',
         l.kind::text || ' ' || l.fee_pct::text || ' ' || l.billing_day::text || ' ' || l.set_by,
         'search 12.000 last promotion:line-items'
  from deal_lines l join deals d on d.id = l.deal_id where d.hubspot_deal_id = '__fx078_D1'
  union all
  select 'exactly one line — nothing invented',
         (select count(*)::text from deal_lines l join deals d on d.id = l.deal_id
          where d.hubspot_deal_id = '__fx078_D1'), '1'
  union all
  select 'the spread covers Sep..Dec, first-of-month',
         (select string_agg(lm.month::text, ',' order by lm.month)
          from deal_line_months lm join deal_lines l on l.id = lm.deal_line_id
          join deals d on d.id = l.deal_id where d.hubspot_deal_id = '__fx078_D1'),
         '2026-09-01,2026-10-01,2026-11-01,2026-12-01'
  union all
  select 'the spread sums to the as-sold $180,000 (¢)',
         (select sum(lm.budget)::text from deal_line_months lm join deal_lines l on l.id = lm.deal_line_id
          join deals d on d.id = l.deal_id where d.hubspot_deal_id = '__fx078_D1'), '18000000'
  union all
  select 'the approval is consumed on success',
         (select count(*)::text from promotion_approvals where hubspot_deal_id = '__fx078_D1'), '0'
  union all
  select 'the call reports what it did',
         (v->>'ok') || ' ' || (v->>'already') || ' ' || (v->>'flighted') || ' ' || (v->>'deal_name'),
         'true false true Fixture Akron World Cup'
  from t078_ret where k = '1st'
) b;

-- ------------------------------------------------------------------ C ------
insert into t078
select 3, 'C: once only', label,
       case when got is not distinct from want then 'PASS'
            else 'FAIL — got ' || coalesce(got,'null') || ', want ' || coalesce(want,'null') end
from (
  select 'a second promotion is refused and names the existing deal' as label,
         (r.v->>'ok') || ' ' || (r.v->>'already') || ' ' || (r.v->>'reason') || ' ' ||
         ((r.v->>'deal_id')::uuid = d.id)::text as got,
         'true true already promoted true' as want
  from t078_ret r, deals d where r.k = '2nd' and d.hubspot_deal_id = '__fx078_D1'
  union all
  select 'still exactly one deal, one promotion, one line',
         (select count(*)::text from deals where hubspot_deal_id = '__fx078_D1') || ' ' ||
         (select count(*)::text from promotions where hubspot_deal_id = '__fx078_D1') || ' ' ||
         (select count(*)::text from deal_lines l join deals d on d.id = l.deal_id
          where d.hubspot_deal_id = '__fx078_D1'),
         '1 1 1'
) c;

-- ------------------------------------------------------------------ D ------
insert into t078
select 4, 'D: held back', label,
       case when got is not distinct from want then 'PASS'
            else 'FAIL — got ' || coalesce(got,'null') || ', want ' || coalesce(want,'null') end
from (
  select 'dates that vanished after approval hold the deal back, with the reason' as label,
         (v->>'ok') || ' ' || (v->>'held_back') || ' ' || (v->>'reason') as got,
         'false true no campaign start date' as want
  from t078_ret where k = 'dateless'
  union all
  select 'a held-back deal is NOT created',
         (select count(*)::text from deals where hubspot_deal_id = '__fx078_D2'), '0'
  union all
  select 'its approval STAYS queued for the nightly retry',
         (select count(*)::text from promotion_approvals where hubspot_deal_id = '__fx078_D2'), '1'
  union all
  select 'an id with no approval is a clean no-op, not an error',
         (v->>'ok') || ' ' || (v->>'reason'), 'false no approval queued for this deal'
  from t078_ret where k = 'unknown'
) d;

-- ------------------------------------------------------------------ E ------
insert into t078
select 5, 'E: skeleton', label,
       case when got is not distinct from want then 'PASS'
            else 'FAIL — got ' || coalesce(got,'null') || ', want ' || coalesce(want,'null') end
from (
  select 'an unmapped product still promotes, unflighted, with the reason' as label,
         (v->>'ok') || ' ' || (v->>'flighted') || ' ' || (v->>'reason') as got,
         'true false unmapped line item: Mystery Product' as want
  from t078_ret where k = 'unmapped'
  union all
  select 'the deal exists; no lines were invented for it',
         (select count(*)::text from deals where hubspot_deal_id = '__fx078_D3') || ' ' ||
         (select count(*)::text from deal_lines l join deals d on d.id = l.deal_id
          where d.hubspot_deal_id = '__fx078_D3'),
         '1 0'
) e;

select section, label, status from t078 order by ord, label;

-- every row above must read PASS
select case when count(*) = 0 then '078 FIXTURE: PASS'
            else '078 FIXTURE: FAIL (' || count(*) || ' assertion(s))' end as verdict
from t078 where status <> 'PASS';

rollback;  -- always roll back: this only ever runs as a test
