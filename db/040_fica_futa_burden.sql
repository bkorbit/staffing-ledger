-- ============================================================================
--  040 — employer payroll burden (FICA + FUTA) layered onto staff_hourly_cost().
--
--  Every bottom-up cost number (Team Hours, Home's per-person/department
--  rollup, per-deal profit attribution) has always been base pay only —
--  comp_periods.annual_cost/hourly_cost, exactly what a human typed on Team.
--  Real employer cost is higher: the employer half of FICA (Social Security +
--  Medicare) and FUTA ride on top of every W-2 dollar paid. Left out, every
--  per-person profit number in the app has been systematically too generous
--  by that amount — a bug of omission, not a wrong number that was ever
--  previously correct.
--
--  This does NOT touch v_deal_month_forecast / v_cost_lines_classified — the
--  top-down plan nets real payroll bills/journal entries from QBO, which
--  already carry the true burdened amount the company actually paid. This is
--  bottom-up only: hours x a person's own resolved rate, same separation of
--  concerns the 031 header already documents.
--
--  Contractors carry none of this — 1099 pay has no employer FICA/FUTA — so
--  employment_type = 'contractor' (comp_periods, 039) passes through
--  unburdened. full_time and part_time (both W-2) get it.
--
--  The wage-base caps (Social Security stops accruing once a person's ANNUAL
--  pay crosses it; FUTA stops after the first $7k) make this NOT a flat
--  percentage — a $250k earner's true burden rate is meaningfully lower than
--  a $50k earner's once their pay clears the SS cap. Rather than track real
--  cumulative pay-to-date within the calendar year (which would need an
--  actual payroll ledger this app doesn't have), each comp period's own
--  ANNUALIZED rate (already computed for the hourly-equivalent conversion)
--  is used to derive one effective annual burden %, applied evenly to every
--  hour that period covers. Exactly right on an annual total; smooths the
--  real mid-year "crosses the cap" step into a flat rate across the year
--  instead — the tradeoff for not needing a YTD ledger.
--
--  All five figures live in settings (same knob pattern as
--  programmatic_cogs_due_days, 017) since two of them are NOT fixed forever:
--  the Social Security wage base is reindexed by the SSA every year, and the
--  net FUTA rate assumes the standard 5.4% state credit — it runs higher in
--  a handful of "credit reduction" states with an unpaid federal UI loan
--  balance. Rates are stored as plain percentages (6.2, not 0.062), matching
--  programmatic_margin_default's own convention; wage bases are stored as
--  whole dollars. fica_ss_wage_base below is seeded from a recent published
--  figure — CONFIRM against the SSA's current-year announcement (and check
--  for a FUTA credit-reduction state) on Settings before relying on this.
-- ============================================================================

insert into settings (key, value, set_by) values
  ('fica_ss_rate',        '6.2',    'migration-040'),
  ('fica_medicare_rate',  '1.45',   'migration-040'),
  ('fica_ss_wage_base',   '176100', 'migration-040'),
  ('futa_rate',           '0.6',    'migration-040'),
  ('futa_wage_base',      '7000',  'migration-040')
on conflict (key) do nothing;

create or replace function staff_hourly_cost(p_staff_id uuid, p_on date)
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
        when 'hourly' then hourly_cost
        when 'salary' then round(annual_cost / (52 * nullif(weekly_capacity, 0)))::bigint
      end as base_rate,
      -- Same annualization either direction: hourly's own 52-week/full-capacity
      -- equivalent, or salary as entered — the basis the wage-base caps below
      -- compare against, never the actual hours a person happens to log.
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
      coalesce((select (value #>> '{}')::numeric from settings where key = 'futa_wage_base'), 7000) * 100 as futa_wage_base_c
  )
  select case
    when base.base_rate is null then null
    when base.employment_type = 'contractor' then base.base_rate
    when base.annualized_comp is null or base.annualized_comp <= 0 then base.base_rate
    else round(base.base_rate * (1 + (
        least(base.annualized_comp, rates.ss_wage_base_c) * rates.ss_rate
        + base.annualized_comp * rates.medicare_rate
        + least(base.annualized_comp, rates.futa_wage_base_c) * rates.futa_rate
      ) / base.annualized_comp
    ))::bigint
  end
  from base, rates
$$ language sql stable;

comment on function staff_hourly_cost is
  'Cents/hour for a staff member on a given date, resolved from whichever '
  'comp_periods row covers it. Base pay converts the same way as always '
  '(salary / (52 * that period''s own weekly_capacity); hourly used as-is), '
  'then W-2 periods (full_time/part_time) get employer FICA + FUTA (040) '
  'layered on top via one effective annual rate derived from the period''s '
  'own annualized comp against the wage-base caps in settings — exactly '
  'right on an annual total, smoothed evenly across the period''s hours '
  'rather than stepping down the month a person actually crosses a cap. '
  'Contractors pass through unburdened. Null — no rate — when no period '
  'covers the date, same as before 040.';
