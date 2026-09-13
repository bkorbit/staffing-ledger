-- Fixture test for 098 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-098 applied, and
-- re-run db/078_fixture_test.sql afterwards: it must still PASS unchanged.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
--   1. MAP      — hs_line_item_map reads the catalog: 'Media: Paid Search
--                 Media' → {search, budget}; an inactive product maps to null
--   2. EXCLUDED — an alias marked excluded is dropped silently: a deal with
--                 paid search media + fee + 'Travel reimbursement' flights ONE
--                 search line at 10%, reason null
--   3. UNMAPPED — a name nobody mapped still blocks (078's rule)
--   4. ALL EXCLUDED — only excluded items → no lines, a reason that says so
--   5. CUSTOM   — a new catalog product + alias maps without touching SQL
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * hs_flight_lines: drop the 098 exclusion filter        -> row 2 (blocks as unmapped)
--   * hs_line_item_map: ignore `not a.excluded`             -> row 2 (travel maps to nothing sensible / row 5)
--   * hs_line_item_map: ignore p.active                     -> row 1

begin;
insert into product_aliases (source, external_name, excluded, set_by) values ('hubspot', 'Travel reimbursement', true, 'fx098');
insert into products (name, kind, role, department, set_by) values ('Landing pages', 'hourly', 'flat', 'Creative', 'fx098');
insert into product_aliases (source, external_name, product_id, set_by)
select 'hubspot', 'Web: Landing Page Build', id, 'fx098' from products where name = 'Landing pages';
update products set active = false where name = 'Planning';

create temp table _f1 as select hs_flight_lines(
  '[{"name":"Media: Paid Search Media","amount":"60000"},{"name":"Fees: Paid Search Fee","amount":"6000"},{"name":"Other: Travel reimbursement","amount":"500"}]'::jsonb,
  '2026-10-01', '2026-12-01') as f;
create temp table _f2 as select hs_flight_lines(
  '[{"name":"Media: Paid Search Media","amount":"60000"},{"name":"Mystery Product","amount":"1"}]'::jsonb,
  '2026-10-01', '2026-12-01') as f;
create temp table _f3 as select hs_flight_lines(
  '[{"name":"Other: Travel reimbursement","amount":"500"}]'::jsonb, '2026-10-01', '2026-12-01') as f;

with r(n, result) as (
  select 1, case when hs_line_item_map('Media: Paid Search Media') = array['search', 'budget']
                  and hs_line_item_map('programmatic buying fee') = array['programmatic', 'fee']
                  and hs_line_item_map('Planning') is null
                  and hs_line_item_map('Nothing like this') is null
    then '1. MAP catalog answers as 078 did; inactive product → null: PASS'
    else '1. MAP: FAIL — ' || coalesce(hs_line_item_map('Media: Paid Search Media')::text, 'null') || ' / planning ' || coalesce(hs_line_item_map('Planning')::text, 'null') end
  union all
  select 2, case when jsonb_array_length((select f from _f1) -> 'lines') = 1
                  and (select f from _f1) -> 'lines' -> 0 ->> 'kind' = 'search'
                  and ((select f from _f1) -> 'lines' -> 0 ->> 'fee_pct')::numeric = 10
                  and (select f from _f1) ->> 'reason' is null
    then '2. EXCLUDED travel item dropped silently; one search line at 10%: PASS'
    else '2. EXCLUDED: FAIL — ' || (select f::text from _f1) end
  union all
  select 3, case when jsonb_array_length((select f from _f2) -> 'lines') = 0
                  and (select f from _f2) ->> 'reason' = 'unmapped line item: Mystery Product'
    then '3. UNMAPPED still blocks with the item named: PASS'
    else '3. UNMAPPED: FAIL — ' || (select f::text from _f2) end
  union all
  select 4, case when jsonb_array_length((select f from _f3) -> 'lines') = 0
                  and (select f from _f3) ->> 'reason' like 'every line item is excluded%'
    then '4. ALL EXCLUDED → no lines, says why: PASS'
    else '4. ALL EXCLUDED: FAIL — ' || (select f::text from _f3) end
  union all
  select 5, case when hs_line_item_map('Web: Landing Page Build') = array['hourly', 'flat']
    then '5. CUSTOM product added in the catalog maps: PASS'
    else '5. CUSTOM: FAIL — ' || coalesce(hs_line_item_map('Web: Landing Page Build')::text, 'null') end
)
select result from r order by n;
rollback;
