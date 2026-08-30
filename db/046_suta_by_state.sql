-- ============================================================================
--  046 — SUTA (state unemployment insurance), calculated per person from
--  their own work_state, same shape as workers' comp (042).
--
--  Unlike workers' comp, SUTA needs TWO numbers per state, not one: a rate
--  AND a taxable wage base (much higher than FUTA's flat federal $7k — some
--  states run $70k+) — so suta_rates carries both columns. rate is nullable
--  on purpose: several states set their "new employer" rate by industry or
--  a graduated schedule rather than one clean number, and a real number here
--  should mean a real confirmed figure, not a guess dressed up as one — a
--  null rate falls back to settings.suta_rate exactly like a missing row
--  does, while the state's real wage_base is still used.
--
--  Reused straight from 042/045's own lessons:
--    - work_state (staff) drives the lookup, same column workers' comp uses.
--    - RLS enabled + a permissive policy right here, immediately — 042
--      forgot this the first time (fixed in 045) and broke the app's read
--      of the whole table silently. Not repeating that.
--    - Falls back to a flat settings rate/wage-base for any state without
--      a confirmed row, so partial data entry works from day one.
--
--  SUTA is an employer cost in every state (unlike state disability
--  insurance, which is a different, separate question — most states with
--  an SDI program have EMPLOYEES fund it via payroll deduction, not
--  employers; that's being scoped separately before anything gets built for
--  it, precisely so a program that isn't actually an employer cost doesn't
--  get modeled as one).
-- ============================================================================

create table if not exists suta_rates (
  state      text primary key,
  wage_base  numeric not null,   -- taxable wage base, whole dollars/yr
  rate       numeric,            -- percent per $100 of THAT wage base; null = not yet confirmed, use the flat fallback
  set_by     text,
  set_at     timestamptz not null default now()
);

alter table suta_rates enable row level security;

create policy suta_rates_auth_all on suta_rates
  for all to authenticated using (true) with check (true);

comment on table suta_rates is
  'Per-state SUTA wage base + rate, editable on Settings. rate is nullable — '
  'several states set new-employer rates by industry/graduated schedule '
  'rather than one number; null falls back to settings.suta_rate the same '
  'way a missing row does, while the state''s own (always-confirmed) '
  'wage_base still applies instead of the flat settings.suta_wage_base.';

insert into settings (key, value, set_by) values
  ('suta_rate',      '2.7',  'migration-046'),
  ('suta_wage_base', '7000', 'migration-046')
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
      -- Exact per-state workers' comp rate when configured; flat fallback otherwise.
      coalesce(
        (select wcr.rate from workers_comp_rates wcr, person where wcr.state = person.work_state),
        coalesce((select (value #>> '{}')::numeric from settings where key = 'workers_comp_rate'), 0)
      ) / 100 as wc_rate,
      -- Exact per-state SUTA rate + wage base when confirmed; flat fallback
      -- for either piece independently (a state can have a real wage_base
      -- but a still-null rate, per the table comment above).
      coalesce(
        (select sr.rate from suta_rates sr, person where sr.state = person.work_state),
        coalesce((select (value #>> '{}')::numeric from settings where key = 'suta_rate'), 0)
      ) / 100 as suta_rate,
      coalesce(
        (select sr.wage_base from suta_rates sr, person where sr.state = person.work_state),
        coalesce((select (value #>> '{}')::numeric from settings where key = 'suta_wage_base'), 7000)
      ) * 100 as suta_wage_base_c
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
    )::bigint
  end
  from base, rates, person
$$ language sql stable;

comment on function staff_annual_burdened_cost is
  'Fully loaded annual cost (cents) for whichever comp_periods row covers '
  'p_on: base annualized pay + employer FICA/FUTA (040), workers'' comp '
  '(042, exact per work_state or the flat fallback) + SUTA (046, exact per '
  'work_state''s wage base and rate, independently falling back per-field '
  'if either is unconfirmed) + 401k match and health insurance premium '
  '(041; contractors excluded from all of the above; each benefit also '
  'gated by its own eligibility/plan-start date even when the staff-level '
  'checkbox is on). Single source of truth — staff_hourly_cost divides '
  'this back to an hourly rate rather than re-deriving it, and Team''s '
  'Total Cost column reads it directly.';
