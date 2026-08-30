-- Read-only diagnostic: reconcile the app's forecast numbers against the real
-- QuickBooks P&L (Elite Media Group_Profit and Loss by Month.xlsx, Jan-Jul
-- 2026). Paste the output back to Claude, no need to interpret it.

-- 1. Contra-revenue ('income' class) lines by month + account — quantifies how
--    much Credit card rewards / Interest earned are currently netting into
--    measured revenue (they shouldn't be treated the same as the real
--    search/social pass-through accounts).
select month, coalesce(account_name, '(no account)') as account, class,
       count(*) as line_count, sum(amount) as total_cents
from v_cost_lines_classified
where class = 'income' and month between '2026-01-01' and '2026-07-01'
group by month, account_name, class
order by month, total_cents desc;

-- 2. Overhead-classified lines whose real QuickBooks account_type is
--    'Other Expense' (Amortization, Depreciation, T/N Retainer, Non Operating
--    Loss, etc.) — these ride the regular overhead run-rate today instead of
--    being kept separate from operating expenses.
select v.month, v.account_name, coalesce(a.override_class, a.derived_class) as effective_class,
       a.account_type, count(*) as line_count, sum(v.amount) as total_cents
from v_cost_lines_classified v
join qbo_accounts a on a.id = v.account_id
where a.account_type = 'Other Expense'
  and v.month between '2026-01-01' and '2026-07-01'
group by v.month, v.account_name, effective_class, a.account_type
order by v.month, total_cents desc;

-- 3. Payroll-adjacent accounts and their CURRENT effective class (derived or
--    overridden) — confirms which of Contract labor / Bonuses / Severance /
--    401k / Health insurance / Officers' life insurance are landing in
--    overhead vs payroll right now.
select a.name, a.fully_qualified_name, a.account_type, a.derived_class, a.override_class,
       coalesce(a.override_class, a.derived_class) as effective_class
from qbo_accounts a
where a.name ilike '%contract labor%' or a.name ilike '%bonus%' or a.name ilike '%severance%'
   or a.name ilike '%401k%' or a.name ilike '%health insurance%' or a.name ilike '%life insurance%'
   or a.name ilike '%workers%comp%'
order by a.name;

-- 4. The headline numbers, computed exactly the way forecast_page() computes
--    them today, for a direct side-by-side against the P&L file's Total
--    Income / Total COGS / Total Labor Cost / Net rows.
with inv as (
  select date_trunc('month', issued_on)::date as month, total
  from invoices where issued_on between '2026-01-01' and '2026-07-31'
),
cost as (
  select month, class, amount from v_cost_lines_classified
  where month between '2026-01-01' and '2026-07-01'
),
u as (
  select month, null::cost_class as class, total as amt, 'inv' as src from inv
  union all
  select month, class, amount as amt, 'cost' as src from cost
)
select month,
  sum(amt) filter (where src = 'inv') as invoice_total_cents,
  sum(amt) filter (where src = 'cost' and class = 'income') * -1 as contra_revenue_added_back_cents,
  sum(amt) filter (where src = 'cost' and class = 'cogs') as cogs_cents,
  sum(amt) filter (where src = 'cost' and class = 'payroll') as payroll_cents,
  sum(amt) filter (where src = 'cost' and class = 'overhead') as overhead_cents,
  sum(amt) filter (where src = 'cost' and class = 'other') as other_cents
from u
group by month
order by month;
