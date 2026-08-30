-- ============================================================================
--  042 — workers' comp by state, calculated exactly per person.
--
--  041 shipped workers' comp as one flat rate for the whole company. Real
--  workers' comp is priced per state (each state runs its own rating bureau/
--  rates) — with staff across multiple states, one flat rate is wrong for
--  every state whose real rate differs from it. work_state (on staff, same
--  as enrolled_401k/enrolled_health_insurance — a current attribute, not
--  something that needs dated history) plus a real workers_comp_rates table
--  (one row per state actually configured) replaces the single guess with an
--  exact per-state, per-person calculation.
--
--  Deliberately NOT also split by job classification code — EMG's roster is
--  one job class (desk work) per the working assumption confirmed with
--  Boris; if that changes (a mixed office/field-staff roster), a class_code
--  column could extend workers_comp_rates the same way state just did,
--  without another rework of staff_annual_burdened_cost's shape.
--
--  A state with no row in workers_comp_rates (not yet confirmed from the
--  policy, or nobody's assigned to it yet) falls back to the existing flat
--  settings.workers_comp_rate (041) — so partial data entry works from day
--  one: add the states you actually have people in as you confirm their
--  real rates, everyone else keeps using the single flat guess until then.
-- ============================================================================

alter table staff add column if not exists work_state text;

comment on column staff.work_state is
  'Two-letter USPS state code (or DC) this person actually works in — human-'
  'set on Team, drives which workers_comp_rates row (042) prices their '
  'workers'' comp. Null falls back to the flat settings.workers_comp_rate '
  '(041), same as a state with no configured row.';

create table if not exists workers_comp_rates (
  state  text primary key check (state in (
    'AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN',
    'IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH',
    'NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT',
    'VT','VA','WA','WV','WI','WY'
  )),
  rate   numeric not null,  -- percent per $100 of payroll, e.g. 0.35 means $0.35/$100
  set_by text,
  set_at timestamptz not null default now()
);

comment on table workers_comp_rates is
  'Per-state workers'' comp rate (percent per $100 of payroll), editable on '
  'Settings. Only states actually confirmed from the policy need a row — '
  'staff_annual_burdened_cost (rewritten below) falls back to the flat '
  'settings.workers_comp_rate (041) for any state without one, including a '
  'staff member with no work_state set at all.';

alter table staff add constraint staff_work_state_check check (work_state is null or work_state in (
  'AL','AK','AZ','AR','CA','CO','CT','DE','DC','FL','GA','HI','ID','IL','IN',
  'IA','KS','KY','LA','ME','MD','MA','MI','MN','MS','MO','MT','NE','NV','NH',
  'NJ','NM','NY','NC','ND','OH','OK','OR','PA','RI','SC','SD','TN','TX','UT',
  'VT','VA','WA','WV','WI','WY'
));

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
      -- Exact per-state rate when this person's work_state has a configured
      -- row; the flat company-wide guess (041) otherwise — a null
      -- work_state or an unconfigured state both take that same fallback.
      coalesce(
        (select wcr.rate from workers_comp_rates wcr, person where wcr.state = person.work_state),
        coalesce((select (value #>> '{}')::numeric from settings where key = 'workers_comp_rate'), 0)
      ) / 100 as wc_rate
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
  'p_on: base annualized pay + employer FICA/FUTA (040) + workers'' comp, '
  'exact per this person''s own work_state when configured in '
  'workers_comp_rates, else the flat settings.workers_comp_rate fallback '
  '(042) + 401k match and health insurance premium (041; contractors '
  'excluded from all of the above; each benefit also gated by its own '
  'eligibility/plan-start date even when the staff-level checkbox is on). '
  'Single source of truth — staff_hourly_cost divides this back to an '
  'hourly rate rather than re-deriving it, and Team''s Total Cost column '
  'reads it directly.';
