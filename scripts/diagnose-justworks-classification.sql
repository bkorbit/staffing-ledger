-- Diagnostic only — no writes. Run in the Supabase SQL editor to see how
-- JustWorks (or any payroll/PEO vendor) bills are currently classified, and
-- how much money is riding on each account/class per month. If the account
-- name doesn't match /payroll|salaries|salary|wages|compensation/, it's
-- landing in 'overhead' instead of 'payroll' — this is the hypothesis to
-- confirm or rule out before changing anything.

select
  b.vendor_name,
  bl.account_name,
  coalesce(a.override_class, a.derived_class, 'other') as effective_class,
  a.derived_class,
  a.override_class,
  date_trunc('month', b.issued_on)::date as month,
  count(*) as line_count,
  sum(bl.amount)::numeric / 100 as total_dollars
from bill_lines bl
join bills b on b.id = bl.bill_id
left join qbo_accounts a on a.id = bl.account_id
where b.vendor_name ilike '%justworks%'
   or bl.account_name ilike '%justworks%'
   or bl.account_name ilike '%payroll%'
   or bl.account_name ilike '%peo%'
group by b.vendor_name, bl.account_name, effective_class, a.derived_class, a.override_class, month
order by month desc, total_dollars desc;
