-- ============================================================================
--  057 — staff_annual_burdened_cost: batch the settings/rate lookups instead
--  of one subquery per key.
--
--  hours_page()'s labor CTE calls staff_hourly_cost() once per time_entries
--  row in the requested range (041: staff_hourly_cost divides
--  staff_annual_burdened_cost by annual hours). staff_annual_burdened_cost
--  itself ran ~16 separate scalar subqueries per call: ten individual
--  `select ... from settings where key = 'x'` lookups (one per FICA/FUTA/
--  401k/health/SUTA/SDI setting), plus workers_comp_rates and — twice —
--  suta_rates (once for rate, once for wage_base). EXPLAIN ANALYZE on
--  hours_page() for a single month showed 2.4s and 31,640 buffer hits
--  against rev_proj_page's 9ms/2,288 for the same range; with a few
--  thousand time_entries rows in a typical month, that's tens of thousands
--  of tiny subquery executions, which is the whole story.
--
--  This rewrite is deliberately NOT a change in what gets computed — every
--  COALESCE default, every fallback-on-no-match, and the final case
--  expression are byte-for-byte the same as 052. Only how many round trips
--  it takes to gather the inputs changes:
--    - the ten settings keys collapse into one aggregate read (settings_kv),
--      using FILTER per key — settings.key is a primary key, so at most one
--      row backs each column; a key with no row aggregates to NULL, exactly
--      like the old scalar subquery returning zero rows did.
--    - workers_comp_rates and suta_rates each move from a scalar subquery
--      (which returns NULL on no match, by definition — 0 rows) to a LEFT
--      JOIN against `person` (always exactly 1 row for a real staff_id),
--      which also yields NULL on no match — same fallback behavior, and
--      suta_rates is now read once for both rate and wage_base instead of
--      twice. Both tables are keyed by `state` primary key, so neither JOIN
--      can multiply rows.
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
  -- jsonb has no built-in MAX aggregate — extract to text (#>> '{}') before
  -- aggregating; settings.key being a primary key means at most one row
  -- backs each FILTER anyway, so this is just "the one value present, or
  -- NULL", never a real max over multiple candidates.
  settings_kv as (
    select
      max(value #>> '{}') filter (where key = 'fica_ss_rate')                  as fica_ss_rate,
      max(value #>> '{}') filter (where key = 'fica_medicare_rate')            as fica_medicare_rate,
      max(value #>> '{}') filter (where key = 'fica_ss_wage_base')             as fica_ss_wage_base,
      max(value #>> '{}') filter (where key = 'futa_rate')                     as futa_rate,
      max(value #>> '{}') filter (where key = 'futa_wage_base')                as futa_wage_base,
      max(value #>> '{}') filter (where key = 'k401_match_rate')               as k401_match_rate,
      max(value #>> '{}') filter (where key = 'health_insurance_monthly_cost') as health_insurance_monthly_cost,
      max(value #>> '{}') filter (where key = 'health_insurance_start_date')   as health_insurance_start_date,
      max(value #>> '{}') filter (where key = 'workers_comp_rate')             as workers_comp_rate,
      max(value #>> '{}') filter (where key = 'suta_rate')                     as suta_rate,
      max(value #>> '{}') filter (where key = 'suta_wage_base')                as suta_wage_base,
      max(value #>> '{}') filter (where key = 'hi_disability_monthly_cost')    as hi_disability_monthly_cost,
      max(value #>> '{}') filter (where key = 'ny_disability_monthly_cost')    as ny_disability_monthly_cost
    from settings
    where key in ('fica_ss_rate','fica_medicare_rate','fica_ss_wage_base','futa_rate','futa_wage_base',
                  'k401_match_rate','health_insurance_monthly_cost','health_insurance_start_date',
                  'workers_comp_rate','suta_rate','suta_wage_base',
                  'hi_disability_monthly_cost','ny_disability_monthly_cost')
  ),
  wc as (
    select wcr.rate
    from person left join workers_comp_rates wcr on wcr.state = person.work_state
  ),
  suta as (
    select sr.rate, sr.wage_base
    from person left join suta_rates sr on sr.state = person.work_state
  ),
  rates as (
    select
      coalesce(settings_kv.fica_ss_rate::numeric, 6.2) / 100 as ss_rate,
      coalesce(settings_kv.fica_medicare_rate::numeric, 1.45) / 100 as medicare_rate,
      coalesce(settings_kv.fica_ss_wage_base::numeric, 176100) * 100 as ss_wage_base_c,
      coalesce(settings_kv.futa_rate::numeric, 0.6) / 100 as futa_rate,
      coalesce(settings_kv.futa_wage_base::numeric, 7000) * 100 as futa_wage_base_c,
      coalesce(settings_kv.k401_match_rate::numeric, 0) / 100 as k401_rate,
      coalesce(settings_kv.health_insurance_monthly_cost::numeric, 0) * 100 as hi_monthly_c,
      coalesce(settings_kv.health_insurance_start_date::date, '2099-01-01'::date) as hi_start,
      coalesce(wc.rate, coalesce(settings_kv.workers_comp_rate::numeric, 0)) / 100 as wc_rate,
      coalesce(suta.rate, coalesce(settings_kv.suta_rate::numeric, 0)) / 100 as suta_rate,
      coalesce(suta.wage_base, coalesce(settings_kv.suta_wage_base::numeric, 7000)) * 100 as suta_wage_base_c,
      coalesce(settings_kv.hi_disability_monthly_cost::numeric, 0) * 100 as hi_sdi_monthly_c,
      coalesce(settings_kv.ny_disability_monthly_cost::numeric, 0) * 100 as ny_sdi_monthly_c
    from settings_kv, wc, suta
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
  'Cost column does not read this directly — see staff_annual_labor_cost. '
  'Settings/rate lookups batched into one read each (057) instead of one '
  'subquery per key — same formula, same fallbacks, far fewer round trips '
  'when called per time-entry row from hours_page().';
