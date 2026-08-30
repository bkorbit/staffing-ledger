-- Read-only diagnostic: why does "Digital Tools, Subscriptions, Etc" show $0
-- in the How-costs-are-counted panel for Jan-Apr 2026 despite real dollars in
-- QuickBooks? Paste the output back to Claude, no need to interpret it.

-- 1. Find the account itself. If more than one row comes back, that's a real
--    duplicate-name issue in the chart of accounts (006's own documented
--    hazard: "Paid Search"/"Paid Social" both existed twice).
select id, name, fully_qualified_name, account_type, active, derived_class, override_class
from qbo_accounts
where name ilike '%digital tools%' or fully_qualified_name ilike '%digital tools%';

-- 2. Every raw bill_lines row for Jan-Apr 2026 that QuickBooks would consider
--    part of this account — matched by name text, NOT account_id, so this
--    catches lines the id-join might be silently missing.
select bl.id, b.kind, b.vendor_name, b.issued_on, bl.account_id, bl.account_name,
       bl.item_name, bl.amount, bl.qbo_project_id
from bill_lines bl
join bills b on b.id = bl.bill_id
where b.issued_on >= '2026-01-01' and b.issued_on < '2026-05-01'
  and (bl.account_name ilike '%digital tools%' or bl.item_name ilike '%digital tools%')
order by b.issued_on;

-- 3. Same window, but through the classified view, to see what class/name
--    each of those lines actually lands under (empty name = the item-based
--    bug theory; look for account_name = '' rows here with meaningful
--    amounts and cross-check their vendor against #2).
select v.month, v.class, v.account_name, v.account_id, v.unjoined,
       count(*) as line_count, sum(v.amount) as total_cents
from v_cost_lines_classified v
where v.month between '2026-01-01' and '2026-04-01'
group by v.month, v.class, v.account_name, v.account_id, v.unjoined
having v.account_name = '' or v.account_name ilike '%digital tools%' or v.unjoined
order by v.month;

-- 4. Sanity total: does the $ amount missing from "Digital Tools" show up
--    hiding under the blank-name bucket for the same window, company-wide?
select month, sum(amount) as blank_account_total_cents, count(*) as line_count
from v_cost_lines_classified
where account_name = '' and month between '2026-01-01' and '2026-04-01'
group by month
order by month;
