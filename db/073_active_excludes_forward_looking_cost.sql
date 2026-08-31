-- ============================================================================
--  073 — "never count" a purged (active=false) staff member's cost, but only
--  in the places that are forward/current-looking. Deliberately NOT in
--  staff_annual_burdened_cost/staff_annual_labor_cost/staff_hourly_cost
--  themselves — those are called with HISTORICAL p_on values throughout
--  hours_page() (per-month/per-deal actual cost, Home's cost trend chart).
--  active is a dateless "right now" flag; gating the shared date-
--  parameterized functions on it would retroactively zero out real PAST
--  cost the moment someone is deactivated, quietly inflating historical
--  profit everywhere those functions feed — the opposite of what's wanted.
--  "Never count them" means stop projecting their FUTURE cost, not rewrite
--  what they actually cost while they were really employed.
--
--  So the filter goes only where money is being projected forward or read
--  as of today:
--    - v_staff_total_cost (Team's live Total Cost column, always evaluated
--      at current_date) — now excludes active=false entirely.
--    - staff_base_labor_forecast_month (071, the Forecast/Cashflow labor
--      projection, only ever asked about future months) — now excludes
--      active=false too, on top of the comp_periods-coverage zeroing it
--      already had. Belt and suspenders: an open-ended comp_period that
--      was never closed (exactly what caused the original bug) no longer
--      matters once active=false, regardless of what its dates say.
-- ============================================================================

create or replace view v_staff_total_cost as
select s.id as staff_id, staff_annual_labor_cost(s.id, current_date) as total_annual_cost
from staff s
where s.active;

comment on view v_staff_total_cost is
  'Team''s Total Cost column, one query for every staff member: fully '
  'loaded annual cost including the PEO fee (staff_annual_labor_cost, 052) '
  'as of today. Excludes active=false (073) — "never count" means exactly '
  'that here, since this is a current-state read, not a historical one.';

create or replace function staff_base_labor_forecast_month(p_month date)
returns bigint as $$
  select round(sum(coalesce(staff_annual_labor_cost(s.id, p_month), 0))::numeric / 12)::bigint
  from staff s
  where s.active
$$ language sql stable;

comment on function staff_base_labor_forecast_month is
  'Per-person base pay + statutory burden (staff_annual_labor_cost, 052) for '
  'every ACTIVE staff row, for one FUTURE month — factored out of '
  'forecast_page (068) so cashflow_forecast (071) can use the SAME number '
  'for its payroll cash-out. active=false is excluded outright (073) — '
  'belt and suspenders on top of the comp_periods-coverage zeroing this '
  'already had, since an open-ended comp_period that was never closed is '
  'exactly what caused the original bug. Safe to filter here specifically '
  'because this function is only ever asked about future months, unlike '
  'the shared staff_annual_burdened_cost/staff_hourly_cost, which stay '
  'active-blind on purpose — see this migration''s header.';
