-- ============================================================================
--  075 — fixing health_insurance_start_date (was stuck at 2099-01-01) means
--  staff_annual_burdened_cost's per-person health-insurance term will start
--  firing for real once the real date arrives — correct and wanted for
--  Team's Total Cost / Team Hours / per-deal profit, all current/historical
--  reads that should reflect real per-person cost now that the date's fixed.
--
--  But staff_base_labor_forecast_month (071) sums staff_annual_labor_cost,
--  which includes that same per-person term, and separately ADDS
--  health_insurance_forecast_month (071) on top — built specifically because
--  health insurance isn't cleanly per-person forecastable before the flat-
--  rate cutover. Once health_insurance_start_date is a real (now-set-to-
--  November) date, the two add together instead of one replacing the other.
--  Small today (Boris: only 1-2 people currently flagged enrolled), but real
--  once enrolled_health_insurance is cleaned up to reflect actual enrollment.
--
--  Fix: subtract the per-person term's contribution back out of the
--  forecast specifically, using the exact same settings/gating logic
--  staff_annual_burdened_cost uses for it, so the forecast keeps relying
--  solely on health_insurance_forecast_month — the shared function itself
--  is untouched, so Team's Total Cost etc. still get the real number.
-- ============================================================================

create or replace function staff_base_labor_forecast_month(p_month date)
returns bigint as $$
  with hi_rate as (
    select
      coalesce((select (value #>> '{}')::numeric from settings where key = 'health_insurance_monthly_cost'), 0) * 100 as hi_monthly_c,
      coalesce((select (value #>> '{}')::date from settings where key = 'health_insurance_start_date'), '2099-01-01'::date) as hi_start
  ),
  per_person_hi as (
    select coalesce(sum(
      case when s.enrolled_health_insurance and p_month >= hi_rate.hi_start
           then hi_rate.hi_monthly_c * 12 else 0 end
    ), 0) as annual_hi_cents
    from staff s, hi_rate
    where s.active
  )
  select round(sum(coalesce(staff_annual_labor_cost(s.id, p_month), 0))::numeric / 12)::bigint
       - round((select annual_hi_cents from per_person_hi)::numeric / 12)::bigint
  from staff s
  where s.active
$$ language sql stable;

comment on function staff_base_labor_forecast_month is
  'Per-person base pay + statutory burden (staff_annual_labor_cost, 052) for '
  'every ACTIVE staff row, for one FUTURE month — minus the per-person '
  'health-insurance term staff_annual_burdened_cost also computes (075), '
  'subtracted back out using the same settings/gating logic, so it never '
  'double-counts against health_insurance_forecast_month (071), which is '
  'the sole source of health insurance in the forecast. active=false is '
  'excluded outright (073) — belt and suspenders on top of the '
  'comp_periods-coverage zeroing this already had.';
