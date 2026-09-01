-- ============================================================================
--  074 — payroll_loose_runrate matched every account nested under "Payroll
--  expenses", not just the genuine loose/unattributed one. account_name is
--  QuickBooks' fully-qualified path (e.g. "Labor Cost:Payroll expenses:
--  Salaries & wages"), so ilike '%payroll expenses%' swept in real salary
--  GL ($2.85M/6mo — already fully counted via staff_base_labor_forecast_month
--  from Team setup, the double-count that inflated August to ~$1.1M),
--  contract labor, historical bonuses, and severance. None of those belong
--  in a "loose transactions" placeholder.
--
--  Fix: exact match (case-insensitive, no wildcards) against the one real
--  bare "Payroll expenses" account with no sub-account of its own — the
--  ~$5.6k/month genuine catch-all this was always meant to be.
-- ============================================================================

create or replace function payroll_loose_runrate(months int default 6)
returns bigint as $$
  select coalesce(round(sum(amount)::numeric / greatest(months, 1))::bigint, 0)
  from v_cost_lines_classified
  where class = 'payroll'
    and account_name ilike 'Labor Cost:Payroll expenses'
    and issued_on >= date_trunc('month', current_date) - make_interval(months => months)
    and issued_on <  date_trunc('month', current_date);
$$ language sql stable;

comment on function payroll_loose_runrate is
  'Trailing average of the genuine "loose/unattributed payroll expenses" GL '
  'account only — an EXACT match (074) against account_name, not a '
  'substring, because account_name is QuickBooks'' fully-qualified path and '
  'a substring match against "payroll expenses" swept in real salary, '
  'contract labor, bonus, and severance sub-accounts nested under the same '
  'parent, none of which belong in this placeholder.';
