-- ============================================================================
--  052 — PEO admin fee counts toward labor cost, but never toward hourly rate.
--
--  050 folded the PEO fee straight into staff_annual_burdened_cost(), which
--  is exactly what staff_hourly_cost() divides by annual hours to get a
--  per-hour rate — so it was quietly inflating every hourly cost figure
--  (Team Hours, Home, per-deal profit attribution) with a flat per-head fee
--  that has nothing to do with the hour actually being worked. Boris's call:
--  the fee is real labor cost for P&L/Total-Cost purposes, but it's
--  operational overhead relative to what an hour of someone's time costs to
--  deliver — it shouldn't move the number used to price a deal or attribute
--  profit per hour.
--
--  Split into two functions instead of one:
--    - staff_annual_burdened_cost — back to its 048 shape (base pay + FICA/
--      FUTA/workers-comp/SUTA + 401k + health insurance + SDI). This is the
--      HOURLY-RATE basis; staff_hourly_cost divides it same as always, so
--      reverting this one function is the whole fix for the rate side.
--    - staff_annual_labor_cost (new) — that total + the PEO fee. This is
--      the P&L-facing "what does this person actually cost the company"
--      figure; only v_staff_total_cost (Team's Total Cost column) reads it.
--      Nothing else should call this one for a rate calculation.
-- ============================================================================

create or replace function staff_annual_burdened_cost(p_staff_id uuid, p_on date)
returns bigint as $$
  with cp as (
    select cp.employment_type, cp.kind, cp.hourly_cost, cp.annual_cost, cp.weekly_capacity
    from comp_periods cp
    where cp.staff_id = p_staff_id
      and cp.starts_on <= p_on
      and (cp.ends_on is null or cp.ends_on >= p_on)
    order by cp.starts_on desc
    limit 1
  ),
  base as (
    select employment_type,
      case kind
        when 'hourly' then hourly_cost * weekly_capacity * 52
        when 'salary' then annual_cost
      end as annualized_comp
    from cp
  ),
  person as (
    select start_date, enrolled_401k, enrolled_health_insurance, work_state
    from staff where id = p_staff_id
  ),
  rates as (
    select
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_ss_rate'), 6.2) / 100 as ss_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_medicare_rate'), 1.45) / 100 as medicare_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_ss_wage_base'), 176100) * 100 as ss_wage_base_c,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'futa_rate'), 0.6) / 100 as futa_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'futa_wage_base'), 7000) * 100 as futa_wage_base_c,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'k401_match_rate'), 0) / 100 as k401_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'health_insurance_monthly_cost'), 0) * 100 as hi_monthly_c,
      coalesce((select (value #>> '{}')::date from settings where key = 'health_insurance_start_date'), '2099-01-01'::date) as hi_start,
      coalesce(
        (select wcr.rate from workers_comp_rates wcr, person where wcr.state = person.work_state),
        coalesce((select (value #>> '{}')::numeric from settings where key = 'workers_comp_rate'), 0)
      ) / 100 as wc_rate,
      coalesce(
        (select sr.rate from suta_rates sr, person where sr.state = person.work_state),
        coalesce((select (value #>> '{}')::numeric from settings where key = 'suta_rate'), 0)
      ) / 100 as suta_rate,
      coalesce(
        (select sr.wage_base from suta_rates sr, person where sr.state = person.work_state),
        coalesce((select (value #>> '{}')::numeric from settings where key = 'suta_wage_base'), 7000)
      ) * 100 as suta_wage_base_c,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'hi_disability_monthly_cost'), 0) * 100 as hi_sdi_monthly_c,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'ny_disability_monthly_cost'), 0) * 100 as ny_sdi_monthly_c
  )
  select case
    when base.annualized_comp is null then null
    when base.employment_type = 'contractor' then base.annualized_comp
    else (
      base.annualized_comp
      + round(
          least(base.annualized_comp, rates.ss_wage_base_c) * rates.ss_rate
          + base.annualized_comp * rates.medicare_rate
          + least(base.annualized_comp, rates.futa_wage_base_c) * rates.futa_rate
          + base.annualized_comp * rates.wc_rate
          + least(base.annualized_comp, rates.suta_wage_base_c) * rates.suta_rate
        )
      + case when person.enrolled_401k
                  and staff_401k_eligibility_date(person.start_date) is not null
                  and p_on >= staff_401k_eligibility_date(person.start_date)
             then round(base.annualized_comp * rates.k401_rate) else 0 end
      + case when person.enrolled_health_insurance and p_on >= rates.hi_start
             then rates.hi_monthly_c * 12 else 0 end
      + case person.work_state
             when 'HI' then rates.hi_sdi_monthly_c * 12
             when 'NY' then rates.ny_sdi_monthly_c * 12
             else 0 end
    )::bigint
  end
  from base, rates, person
$$ language sql stable;

comment on function staff_annual_burdened_cost is
  'HOURLY-RATE basis (cents/yr) for whichever comp_periods row covers p_on: '
  'base annualized pay + employer FICA/FUTA (040), workers'' comp (042), '
  'SUTA (046) + 401k match and health insurance premium (041) + state '
  'disability insurance (048, HI/NY only). Deliberately excludes the PEO '
  'admin fee (052) — that''s a flat per-head operational charge, not '
  'something that should move the price of an hour of someone''s time. '
  'staff_hourly_cost divides THIS number by annual hours; Team''s Total '
  'Cost column does not read this directly — see staff_annual_labor_cost.';

create or replace function staff_annual_labor_cost(p_staff_id uuid, p_on date)
returns bigint as $$
  with base as (
    select staff_annual_burdened_cost(p_staff_id, p_on) as burdened
  ),
  cp as (
    select employment_type from comp_periods
    where staff_id = p_staff_id and starts_on <= p_on and (ends_on is null or ends_on >= p_on)
    order by starts_on desc limit 1
  ),
  peo as (
    select coalesce((select (value #>> '{}')::numeric from settings where key = 'peo_admin_fee_monthly'), 0) * 100 as monthly_c
  )
  select case
    when base.burdened is null then null
    when cp.employment_type = 'contractor' then base.burdened
    else base.burdened + (peo.monthly_c * 12)::bigint
  end
  from base, cp, peo
$$ language sql stable;

comment on function staff_annual_labor_cost is
  'The P&L-facing "what does this person actually cost" figure (cents/yr): '
  'staff_annual_burdened_cost PLUS the flat PEO admin fee (052, W-2 only). '
  'This is what Team''s Total Cost column reads — never use this one as the '
  'basis for an hourly rate or per-hour profit attribution; use '
  'staff_annual_burdened_cost / staff_hourly_cost for that instead.';

-- Team's Total Cost column now includes the PEO fee via the new function;
-- staff_hourly_cost (unchanged, still divides staff_annual_burdened_cost)
-- is untouched by this migration and so is every hourly-rate-based number
-- downstream of it (Team Hours, Home, per-deal profit).
create or replace view v_staff_total_cost as
select s.id as staff_id, staff_annual_labor_cost(s.id, current_date) as total_annual_cost
from staff s;

comment on view v_staff_total_cost is
  'Team''s Total Cost column, one query for every staff member: fully '
  'loaded annual cost including the PEO fee (staff_annual_labor_cost, 052) '
  'as of today.';
