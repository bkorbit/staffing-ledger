-- ============================================================================
--  041 — 401k match + health insurance layered into staff cost, and a shared
--  "fully loaded annual cost" function so Team's new Total Cost column and
--  staff_hourly_cost() (Team Hours / Home) can never quietly disagree.
--
--  enrolled_401k / enrolled_health_insurance live on staff (not comp_periods)
--  — unlike pay/hours/employment_type, benefit enrollment isn't something
--  that needs a dated history of past changes; it's a current toggle, set on
--  Team same as department or active. A workers_comp_rate settings knob is
--  seeded at 0 (contributes nothing) so Total Cost is ready for it the
--  moment a real number lands, without a second migration (same shape-now
--  approach hours_page's own assignments table took, 031).
--
--  Both new benefits are gated by their own "doesn't count yet" condition
--  even when the checkbox is on:
--
--  - 401k: real 401k plans commonly don't vest eligibility on day one — a
--    standard formula is "after 6 months of service, entry on the 1st of
--    the month coinciding with or following." staff_401k_eligibility_date()
--    computes that from start_date: hired Jan 15 -> 6 months out is Jul 15,
--    not itself a 1st, so eligibility waits for the NEXT 1st -> Aug 1.
--    Hired on an actual 1st -> the 6-month mark IS already a 1st, so no
--    extra month is added.
--
--  - Health insurance: doesn't exist as a real cost before EMG's own plan
--    start date (health_insurance_start_date, seeded far in the future —
--    2099-01-01 — until set for real, so nothing is silently charged for a
--    benefit that doesn't exist yet).
--
--  Both exclude contractors outright (comp_periods.employment_type), same
--  as FICA/FUTA (040) — 1099 pay carries no W-2 benefit plan.
--
--  staff_hourly_cost() now derives from staff_annual_burdened_cost() instead
--  of computing its own base-rate-then-multiply — one rounding point
--  (annual total -> hourly) instead of two (base rate rounded, THEN the
--  burden ratio applied to that already-rounded number). Re-verified against
--  every 040 fixture: identical results, since 040's numbers never actually
--  hit the boundary where the two rounding orders diverge (values are
--  usually exact multiples of a cent at the annual level) — this is a
--  cleanup, not a behavior change, confirmed by testing rather than assumed.
-- ============================================================================

alter table staff add column if not exists enrolled_401k boolean not null default false;
alter table staff add column if not exists enrolled_health_insurance boolean not null default false;

comment on column staff.enrolled_401k is
  'Human-set on Team — whether this person''s employer 401k match counts '
  'toward their cost. Even when true, the match itself only starts '
  'accruing per staff_401k_eligibility_date(start_date) (041) — 6 months '
  'after hire, entry on the 1st of the month coinciding with or following.';
comment on column staff.enrolled_health_insurance is
  'Human-set on Team — whether this person''s health insurance premium '
  'counts toward their cost. Even when true, only accrues from '
  'settings.health_insurance_start_date onward (041) — the benefit does '
  'not exist before EMG''s own plan start date.';

insert into settings (key, value, set_by) values
  ('k401_match_rate',               '3',            'migration-041'),
  ('health_insurance_monthly_cost', '0',            'migration-041'),
  ('health_insurance_start_date',   '"2099-01-01"', 'migration-041'),
  ('workers_comp_rate',             '0',            'migration-041')
on conflict (key) do nothing;

-- First day of the month coinciding with or following 6 months of service.
-- Hired on a 1st -> the 6-month mark lands on a 1st too -> that date exactly.
-- Any other hire date -> the 6-month mark is mid-month -> wait for the 1st
-- of the NEXT month. Null hire date -> null (never eligible; nothing to
-- compute from).
create or replace function staff_401k_eligibility_date(p_hire_date date)
returns date as $$
  select case
    when p_hire_date is null then null
    when extract(day from p_hire_date) = 1
      then (date_trunc('month', p_hire_date) + interval '6 months')::date
    else (date_trunc('month', p_hire_date) + interval '7 months')::date
  end
$$ language sql immutable;

comment on function staff_401k_eligibility_date is
  'Standard 401k entry-date formula: 6 months of service, entry on the 1st '
  'of the month coinciding with or following. Jan 15 hire -> Jul 15 is the '
  '6-month mark, not itself a 1st -> Aug 1. Jan 1 hire -> Jul 1 already is '
  'a 1st -> Jul 1 exactly.';

-- Fully loaded annual cost (cents) for whichever comp_periods row covers
-- p_on: base annualized pay + employer FICA/FUTA/workers-comp (contractors
-- excluded) + 401k match and health insurance (contractors excluded, each
-- also gated by its own real-world start condition above). The one place
-- this math is written — staff_hourly_cost divides it back down to an
-- hourly rate rather than re-deriving any of it.
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
  rates as (
    select
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_ss_rate'), 6.2) / 100 as ss_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_medicare_rate'), 1.45) / 100 as medicare_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_ss_wage_base'), 176100) * 100 as ss_wage_base_c,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'futa_rate'), 0.6) / 100 as futa_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'futa_wage_base'), 7000) * 100 as futa_wage_base_c,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'workers_comp_rate'), 0) / 100 as wc_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'k401_match_rate'), 0) / 100 as k401_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'health_insurance_monthly_cost'), 0) * 100 as hi_monthly_c,
      coalesce((select (value #>> '{}')::date from settings where key = 'health_insurance_start_date'), '2099-01-01'::date) as hi_start
  ),
  person as (
    select start_date, enrolled_401k, enrolled_health_insurance from staff where id = p_staff_id
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
  'p_on: base annualized pay + employer FICA/FUTA/workers-comp (040/041; '
  'contractors excluded) + 401k match and health insurance premium '
  '(contractors excluded; each also gated by its own eligibility/plan-start '
  'date even when the staff-level checkbox is on). Single source of truth — '
  'staff_hourly_cost divides this back to an hourly rate rather than '
  're-deriving it, and Team''s Total Cost column reads it directly.';

create or replace function staff_hourly_cost(p_staff_id uuid, p_on date)
returns bigint as $$
  with cp as (
    select cp.kind, cp.hourly_cost, cp.annual_cost, cp.weekly_capacity
    from comp_periods cp
    where cp.staff_id = p_staff_id
      and cp.starts_on <= p_on
      and (cp.ends_on is null or cp.ends_on >= p_on)
    order by cp.starts_on desc
    limit 1
  ),
  base as (
    select
      case kind
        when 'hourly' then hourly_cost
        when 'salary' then round(annual_cost / (52 * nullif(weekly_capacity, 0)))::bigint
      end as base_rate,
      weekly_capacity
    from cp
  )
  select case
    when base.base_rate is null then null
    when base.weekly_capacity is null or base.weekly_capacity <= 0 then base.base_rate
    else round(staff_annual_burdened_cost(p_staff_id, p_on) / (52 * base.weekly_capacity))::bigint
  end
  from base
$$ language sql stable;

comment on function staff_hourly_cost is
  'Cents/hour for a staff member on a given date, resolved from whichever '
  'comp_periods row covers it. Derives from staff_annual_burdened_cost '
  '(041) divided by that period''s own annual hours (52 * weekly_capacity) '
  '— one shared calculation with Team''s Total Cost column, one rounding '
  'point. Null — no rate — when no period covers the date, unchanged from '
  'before 040/041.';

-- One round trip for Team's roster table: every staff member's current
-- fully loaded annual cost, evaluated as of today. Deliberately a live
-- CURRENT_DATE snapshot, not a date-range report — Team Setup shows what a
-- person costs right now, the same way it shows their CURRENT comp period,
-- not history.
create or replace view v_staff_total_cost as
select s.id as staff_id, staff_annual_burdened_cost(s.id, current_date) as total_annual_cost
from staff s;

comment on view v_staff_total_cost is
  'Team''s Total Cost column, one query for every staff member: fully '
  'loaded annual cost (staff_annual_burdened_cost, 041) as of today.';
