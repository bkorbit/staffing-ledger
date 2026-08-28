-- ============================================================================
--  006 — classify cost lines by account id, not name
--
--  The chart of accounts contains 'Paid Search' twice and 'Paid Social' twice, so
--  the name join in v_cost_lines_classified multiplied those lines, and any line
--  whose stored name did not match an account at all fell through to 'other'. The
--  result: 'other' was the largest category at $5.4M over six months and COGS showed
--  $722 a month, which for a media business is not a number, it is a symptom.
--
--  Lines now carry the QuickBooks account id. The name join survives only as a
--  fallback for item-based lines, which reference an item rather than an account.
-- ============================================================================

alter table bill_lines add column if not exists account_id text;

-- create or replace cannot reposition columns, so the old (multiplying) view must go
drop view if exists v_cost_lines_classified;
create view v_cost_lines_classified as
select
  bl.id, bl.bill_id, b.kind, b.vendor_name, b.issued_on,
  date_trunc('month', b.issued_on)::date as month,
  bl.account_id, bl.account_name, bl.amount, bl.qbo_project_id,
  coalesce(a.override_class, a.derived_class,
           an.override_class, an.derived_class,
           'other'::cost_class)                          as class,
  (a.id is null and an.id is null)                       as unjoined
from bill_lines bl
join bills b on b.id = bl.bill_id
left join qbo_accounts a  on a.id = bl.account_id
-- name fallback ONLY when there is no id, and only when the name is unambiguous
left join lateral (
  select q.* from qbo_accounts q
  where bl.account_id is null
    and (q.fully_qualified_name = bl.account_name or q.name = bl.account_name)
    and 1 = (select count(*) from qbo_accounts q2
             where q2.fully_qualified_name = bl.account_name or q2.name = bl.account_name)
  limit 1
) an on true;

comment on view v_cost_lines_classified is
  'Expense lines with an effective cost class, joined on account id. Name matching '
  'survives only as an unambiguous fallback. unjoined = true marks lines that matched '
  'nothing and are therefore classified other — that count should be near zero, and '
  'anything above it is a data problem to look at, not to average over.';
