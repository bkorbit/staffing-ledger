-- ============================================================================
--  048 — state disability insurance, ONLY where it's a real employer cost.
--
--  Most state disability programs (California, New Jersey, Rhode Island) are
--  funded entirely by an EMPLOYEE payroll deduction — the employer pays
--  nothing, so modeling them here would overstate real cost, not improve
--  it. Two states are genuinely different: the employee's own contribution
--  is capped by statute, and the EMPLOYER is on the hook for whatever the
--  real insurance premium costs above that cap (usually a small private
--  TDI/DBL policy, self-insured or carrier-written):
--    - Hawaii (TDI)
--    - New York (DBL)
--  Every other state either has no program at all or funds it entirely from
--  the employee side, so nothing is added for them.
--
--  Unlike workers' comp/SUTA, this isn't a published, ratable % of payroll
--  — real cost is whatever EMG's own private policy actually bills, a
--  number no public source can supply. Both settings below seed at $0
--  (contributes nothing) rather than a guessed figure, until you have a
--  real quote/policy cost to enter — same "shape is here, no fake number"
--  approach used for the original workers_comp_rate/health_insurance
--  defaults. A flat $/month per covered person, same shape as health
--  insurance (not a % of comp — real TDI/DBL premiums don't scale with
--  salary) — and mandatory once someone works in that state, no per-person
--  enrollment checkbox: unlike 401k/health insurance, this isn't optional.
-- ============================================================================

insert into settings (key, value, set_by) values
  ('hi_disability_monthly_cost', '0', 'migration-048'),
  ('ny_disability_monthly_cost', '0', 'migration-048')
on conflict (key) do nothing;

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
  'Fully loaded annual cost (cents) for whichever comp_periods row covers '
  'p_on: base annualized pay + employer FICA/FUTA (040), workers'' comp '
  '(042), SUTA (046) + 401k match and health insurance premium (041) + '
  'state disability insurance (048, HI/NY only — the only states where it''s '
  'a real employer cost, flat $/month per covered person, automatic by '
  'work_state, no opt-in checkbox since it isn''t optional). Contractors '
  'excluded from all of the above; each benefit also gated by its own '
  'eligibility/plan-start date even when the staff-level checkbox is on. '
  'Single source of truth — staff_hourly_cost divides this back to an '
  'hourly rate rather than re-deriving it, and Team''s Total Cost column '
  'reads it directly.';
