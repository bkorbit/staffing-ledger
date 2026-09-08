-- Diagnostic, not a migration. Read-only, safe to run any time.
--
-- Answers: is August's prebill actually being kept out of revenue, and if not,
-- which of the four fail-open conditions is letting it through?
--
-- One result set (see 087_fixture_test.sql's header for why). The first block
-- is every August invoice line grouped by the account it posts to, with the
-- verdict 080 reaches for it. The last four rows are the reconciliation that
-- follows, to compare against QuickBooks' own Total Income for August.
--
-- 079 measured this by hand and found:
--    Managed Service:Media Deposit (2 lines)      -146,082.68
--    Customer Prepayment (1 line)                  -10,000.00
-- so those two accounts are what to look for in the first block. If either
-- says REVENUE rather than EXCLUDED, the reason is in the verdict column.

with aug as (select date '2026-08-01' as m),
lines as (
  select coalesce(nullif(l.account_name, ''), '(no account stamped on the line)') as account,
         (l.account_id is not null) as stamped,
         l.unjoined,
         l.class::text as class,
         sum(l.amount)   as amt,
         count(*)::bigint as n
  from v_invoice_lines_classified l cross join aug
  where l.month = aug.m
  group by 1, 2, 3, 4
),
gross as (
  select coalesce(sum(i.total), 0)::bigint as amt
  from invoices i cross join aug
  where date_trunc('month', i.issued_on::timestamp)::date = aug.m
),
contra as (
  select coalesce(sum(c.amount), 0)::bigint as amt
  from v_cost_lines_classified c cross join aug
  where c.month = aug.m and c.class = 'income'
),
-- exactly 080's nonrev: every condition is a reason to subtract, and anything
-- unresolved falls through and stays revenue
drop_bs as (
  select coalesce(sum(l.amount), 0)::bigint as amt
  from v_invoice_lines_classified l cross join aug
  where l.month = aug.m
    and l.account_id is not null
    and not l.unjoined
    and l.class is not null
    and l.class <> 'income'
)
select 1 as sort, account as item, round(amt / 100.0, 2) as dollars, n as lines,
  case when not stamped      then 'REVENUE — sync has not stamped account_id on these lines'
       when unjoined         then 'REVENUE — account_id does not resolve to a qbo_accounts row'
       when class is null    then 'REVENUE — account has no class; set one in Settings > Finance'
       when class = 'income' then 'revenue (income account)'
       else 'EXCLUDED from revenue — class ' || class end as counted_as
from lines
union all select 2, 'INVOICES GROSS', round((select amt from gross) / 100.0, 2),
  null::bigint, 'invoices.total by issue date'
union all select 3, 'less contra revenue (025)', round(-(select amt from contra) / 100.0, 2),
  null::bigint, 'income-class bill/purchase/journal lines'
union all select 4, 'less balance-sheet invoice lines (080)', round(-(select amt from drop_bs) / 100.0, 2),
  null::bigint, 'customer deposits and prepayments'
union all select 5, '= MEASURED REVENUE, AUGUST',
  round(((select amt from gross) - (select amt from contra) - (select amt from drop_bs)) / 100.0, 2),
  null::bigint, 'QuickBooks Total Income for August was 554,546.25'
order by sort, dollars desc nulls last;
