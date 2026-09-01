-- ============================================================================
--  077 — Labor page: a financial breakdown of burdened labor cost, sourced
--  entirely from Team setup (staff, comp_periods, staff_bonuses,
--  health_insurance_tiers) — deliberately NOT tied to logged/planned hours.
--
--  staff_annual_burdened_cost (057) and staff_annual_labor_cost (052) only
--  ever returned ONE summed bigint — no function anywhere broke "$X/yr for
--  this person" into base pay / FICA / Medicare / FUTA / workers' comp /
--  SUTA / 401k match / health insurance / SDI / PEO fee. Boris's call: make
--  that breakdown the one source of truth, and turn the two existing
--  summing functions into thin wrappers over it, rather than hand-writing a
--  second copy of the formula that has to be kept in sync forever.
--
--  staff_burdened_cost_breakdown is ported term-by-term from 057's body —
--  same CTEs, same settings/rate batching, same fallbacks. ONE deliberate,
--  documented wrinkle: 057 rounds the five wage-based terms (SS/Medicare/
--  FUTA/workers' comp/SUTA) together in a single round() call ("round5").
--  Splitting that into five real per-line numbers naively (rounding each
--  term on its own) could disagree with round5 by a cent or two per
--  person — not acceptable for a number Forecast/Cashflow/Team already
--  ship. So four of the five lines (fica_ss/fica_medicare/futa/
--  workers_comp) are rounded normally, and suta_cents is computed as the
--  PLUG: round5 minus the other four. That guarantees the five lines
--  always foot to exactly round5 — the same value 057's formula produces,
--  byte-for-byte — while every line still carries a real, individually
--  meaningful number. suta_cents is the plug arbitrarily (least
--  individually-scrutinized of the five); burdened_cents/total_cents are
--  built from the exact same expression 057/052 already used, so nothing
--  Forecast, Cashflow, or Team already shows moves at all. Verified exactly
--  (not approximately) in db/077_fixture_test.sql (not shipped).
--
--  staff_annual_burdened_cost and staff_annual_labor_cost become thin
--  wrappers (select .../burdened_cents/total_cents from the breakdown) —
--  every existing caller (staff_hourly_cost, v_staff_total_cost,
--  staff_base_labor_forecast_month, Team's Total Cost column, hours_page())
--  keeps working unchanged, now backed by the one shared formula.
--
--  staff_bonus_burdened_cost (070) is NOT touched and NOT unified here — it
--  independently re-derives its own comp_period/rate/wage-base lookup for
--  bonus-specific YTD wage-base-capping logic that regular pay doesn't
--  need. That's a pre-existing second copy of the statutory formula, not
--  something this migration introduces; unifying it would mean reshaping
--  already-shipped bonus math that wasn't part of what was asked, so it's
--  left alone and named here rather than silently left as an unnoticed gap.
--
--  staff_base_labor_forecast_month (075) is ALSO NOT touched, for the same
--  reason: its own per_person_hi subtraction is a closely-related but not
--  identical duplicate (it subtracts the health-insurance term for every
--  enrolled+active person unconditionally, without checking comp_period
--  coverage or contractor status the way the real per-person term does) —
--  routing it through staff_burdened_cost_breakdown instead would be a real
--  behavior change in edge cases (an enrolled person with no comp_period
--  covering the month, or a contractor incorrectly flagged enrolled), not
--  a verified-equivalent refactor. forecast_page and cashflow_forecast both
--  depend on this function live; changing what it computes wasn't asked
--  for and isn't proven safe, so it's flagged here rather than changed.
--
--  labor_forecast_breakdown is the Labor page's forward-trend source —
--  again zero duplicated formula, not a second copy: forecast_page's
--  labor_forecast_month (076) is a perf-motivated INLINE of three already-
--  standalone, already-shared functions — confirmed by db/076_fixture_test
--  .sql, which snapshots the pre-076 body calling them directly and proves
--  it byte-identical to 076's inlined version: staff_base_labor_forecast_
--  month (073/075), payroll_loose_runrate (074), and health_insurance_
--  forecast_month (072) — plus staff_bonus_burdened_cost (070), also
--  already standalone. cashflow_forecast (071) already calls these same
--  functions directly too. labor_forecast_breakdown just calls all four
--  canonical functions per month and returns each as its own column
--  instead of pre-summing — the formula for "what does labor cost in month
--  X" lives in exactly the same places it already lived; Forecast's Labour
--  bar, Cashflow's payroll cash-out, and this new trend chart all derive
--  from the identical source. NEITHER forecast_page NOR cashflow_forecast
--  is touched by this migration.
--
--  labor_page bundles a current-roster snapshot (staff_burdened_cost_
--  breakdown for every active staff member, as of today) and the forward
--  trend into one jsonb, one round trip — same shape as forecast_page.
-- ============================================================================

create or replace function staff_burdened_cost_breakdown(p_staff_id uuid, p_on date)
returns table (
  employment_type        text,
  base_cents             bigint,
  fica_ss_cents          bigint,
  fica_medicare_cents    bigint,
  futa_cents             bigint,
  workers_comp_cents     bigint,
  suta_cents             bigint,
  k401_match_cents       bigint,
  health_insurance_cents bigint,
  disability_cents       bigint,
  peo_fee_cents          bigint,
  burdened_cents         bigint,
  total_cents            bigint
) as $$
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
      max(value #>> '{}') filter (where key = 'ny_disability_monthly_cost')    as ny_disability_monthly_cost,
      max(value #>> '{}') filter (where key = 'peo_admin_fee_monthly')         as peo_admin_fee_monthly
    from settings
    where key in ('fica_ss_rate','fica_medicare_rate','fica_ss_wage_base','futa_rate','futa_wage_base',
                  'k401_match_rate','health_insurance_monthly_cost','health_insurance_start_date',
                  'workers_comp_rate','suta_rate','suta_wage_base',
                  'hi_disability_monthly_cost','ny_disability_monthly_cost','peo_admin_fee_monthly')
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
      coalesce(settings_kv.ny_disability_monthly_cost::numeric, 0) * 100 as ny_sdi_monthly_c,
      coalesce(settings_kv.peo_admin_fee_monthly::numeric, 0) * 100 as peo_monthly_c
    from settings_kv, wc, suta
  ),
  -- round5 mirrors 057's single combined round() over the five wage-based
  -- terms exactly, byte-for-byte — burdened_cents/total_cents are built
  -- from THIS, never from the sum of the individually-rounded lines below.
  terms as (
    select
      base.employment_type,
      base.annualized_comp as base_cents,
      least(base.annualized_comp, rates.ss_wage_base_c) * rates.ss_rate as ss_raw,
      base.annualized_comp * rates.medicare_rate as medicare_raw,
      least(base.annualized_comp, rates.futa_wage_base_c) * rates.futa_rate as futa_raw,
      base.annualized_comp * rates.wc_rate as wc_raw,
      round(
        least(base.annualized_comp, rates.ss_wage_base_c) * rates.ss_rate
        + base.annualized_comp * rates.medicare_rate
        + least(base.annualized_comp, rates.futa_wage_base_c) * rates.futa_rate
        + base.annualized_comp * rates.wc_rate
        + least(base.annualized_comp, rates.suta_wage_base_c) * rates.suta_rate
      )::bigint as round5,
      case when person.enrolled_401k
                and staff_401k_eligibility_date(person.start_date) is not null
                and p_on >= staff_401k_eligibility_date(person.start_date)
           then round(base.annualized_comp * rates.k401_rate)::bigint else 0 end as k401_raw,
      case when person.enrolled_health_insurance and p_on >= rates.hi_start
           then (rates.hi_monthly_c * 12)::bigint else 0 end as hi_raw,
      case person.work_state
           when 'HI' then (rates.hi_sdi_monthly_c * 12)::bigint
           when 'NY' then (rates.ny_sdi_monthly_c * 12)::bigint
           else 0 end as sdi_raw,
      (rates.peo_monthly_c * 12)::bigint as peo_raw
    from base, rates, person
  )
  select
    employment_type,
    base_cents,
    case when employment_type = 'contractor' then 0 else round(ss_raw)::bigint end,
    case when employment_type = 'contractor' then 0 else round(medicare_raw)::bigint end,
    case when employment_type = 'contractor' then 0 else round(futa_raw)::bigint end,
    case when employment_type = 'contractor' then 0 else round(wc_raw)::bigint end,
    -- suta_cents: the plug — round5 minus the other four rounded lines, so
    -- the five statutory lines always sum to exactly round5.
    case when employment_type = 'contractor' then 0
         else round5 - round(ss_raw)::bigint - round(medicare_raw)::bigint
                      - round(futa_raw)::bigint - round(wc_raw)::bigint end,
    case when employment_type = 'contractor' then 0 else k401_raw end,
    case when employment_type = 'contractor' then 0 else hi_raw end,
    case when employment_type = 'contractor' then 0 else sdi_raw end,
    case when employment_type = 'contractor' then 0 else peo_raw end,
    case when employment_type = 'contractor' then base_cents
         else (base_cents + round5 + k401_raw + hi_raw + sdi_raw)::bigint end,
    case when employment_type = 'contractor' then base_cents
         else (base_cents + round5 + k401_raw + hi_raw + sdi_raw + peo_raw)::bigint end
  from terms
$$ language sql stable;

comment on function staff_burdened_cost_breakdown is
  'Per-person burdened labor cost (cents/yr), broken into named lines, for '
  'whichever comp_periods row covers p_on (077). The ONE source of truth: '
  'staff_annual_burdened_cost/staff_annual_labor_cost are thin wrappers '
  'over burdened_cents/total_cents here. suta_cents is a rounding plug '
  '(round5 minus the other four statutory lines) so the five statutory '
  'lines always foot to exactly the same combined-rounded figure the '
  'pre-077 formula produced — burdened_cents/total_cents are byte-for-byte '
  'identical to the pre-077 functions, verified in db/077_fixture_test.sql. '
  'Contractor rows: every burden line is 0, burdened_cents = total_cents = '
  'base_cents. Zero rows returned if no comp_periods row covers p_on.';

create or replace function staff_annual_burdened_cost(p_staff_id uuid, p_on date)
returns bigint as $$
  select burdened_cents from staff_burdened_cost_breakdown(p_staff_id, p_on)
$$ language sql stable;

comment on function staff_annual_burdened_cost is
  'HOURLY-RATE basis (cents/yr) — thin wrapper (077) over '
  'staff_burdened_cost_breakdown.burdened_cents, which is the one source '
  'of truth for this formula. staff_hourly_cost divides THIS number by '
  'annual hours; Team''s Total Cost column does not read this directly — '
  'see staff_annual_labor_cost.';

create or replace function staff_annual_labor_cost(p_staff_id uuid, p_on date)
returns bigint as $$
  select total_cents from staff_burdened_cost_breakdown(p_staff_id, p_on)
$$ language sql stable;

comment on function staff_annual_labor_cost is
  'The P&L-facing "what does this person actually cost" figure (cents/yr) '
  '— thin wrapper (077) over staff_burdened_cost_breakdown.total_cents '
  '(burdened_cents plus the flat PEO admin fee). This is what Team''s '
  'Total Cost column reads — never use this one as the basis for an '
  'hourly rate or per-hour profit attribution; use '
  'staff_annual_burdened_cost / staff_hourly_cost for that instead.';

create or replace function labor_forecast_breakdown(p_from date, p_to date)
returns table (
  month                   date,
  base_statutory_cents    bigint,
  loose_payroll_cents     bigint,
  health_insurance_cents  bigint,
  bonus_cents             bigint,
  total_cents             bigint
) as $$
  with cur as (select date_trunc('month', current_date)::date as m),
  months as (
    select gm.month::date as month
    from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
  ),
  bonus_forecast as (
    select date_trunc('month', b.pay_date)::date as month,
           sum(staff_bonus_burdened_cost(b.id)) as total
    from staff_bonuses b
    where date_trunc('month', b.pay_date)::date between p_from and p_to
    group by date_trunc('month', b.pay_date)::date
  ),
  loose as (
    select payroll_loose_runrate() as total
  ),
  per_month as (
    select
      m.month,
      staff_base_labor_forecast_month(m.month) as base_statutory_cents,
      loose.total as loose_payroll_cents,
      health_insurance_forecast_month(m.month) as health_insurance_cents,
      coalesce(bf.total, 0) as bonus_cents
    from months m
    left join bonus_forecast bf on bf.month = m.month
    cross join loose
  )
  select month, base_statutory_cents, loose_payroll_cents, health_insurance_cents, bonus_cents,
         (base_statutory_cents + loose_payroll_cents + health_insurance_cents + bonus_cents) as total_cents
  from per_month
$$ language sql stable;

comment on function labor_forecast_breakdown is
  'Forward monthly labor-cost trend, broken into named components (077), '
  'for the Labor page''s trend chart. Zero duplicated formula: calls the '
  'same canonical, already-shared functions forecast_page''s '
  'labor_forecast_month (076) is a documented-equivalent perf inline of, '
  'and cashflow_forecast (071) already calls directly — '
  'staff_base_labor_forecast_month, payroll_loose_runrate, '
  'health_insurance_forecast_month, staff_bonus_burdened_cost. Neither '
  'forecast_page nor cashflow_forecast is touched by this migration.';

create or replace function labor_page(p_from date, p_to date)
returns jsonb as $$
  select jsonb_build_object(
    -- LEFT JOIN LATERAL, not CROSS: an active staff member with no
    -- comp_periods row covering today (a future-dated new hire, a data-
    -- entry gap) must still appear in the roster with null cost fields —
    -- same "show them, don't hide them" convention Team's Total Cost
    -- column already uses (v_staff_total_cost) — rather than silently
    -- vanishing from headcount/totals the way a CROSS JOIN LATERAL would.
    'roster', coalesce((select jsonb_agg(t) from (
        select s.id as staff_id, s.name, s.department, b.employment_type,
               b.base_cents, b.fica_ss_cents, b.fica_medicare_cents, b.futa_cents,
               b.workers_comp_cents, b.suta_cents, b.k401_match_cents,
               b.health_insurance_cents, b.disability_cents, b.peo_fee_cents,
               b.burdened_cents, b.total_cents
        from staff s
        left join lateral staff_burdened_cost_breakdown(s.id, current_date) b on true
        where s.active
      ) t), '[]'::jsonb),
    'trend', coalesce((select jsonb_agg(t) from labor_forecast_breakdown(p_from, p_to) t), '[]'::jsonb)
  );
$$ language sql stable;

comment on function labor_page is
  'The Labor page''s data, one jsonb, one round trip (077): roster = every '
  'active staff member''s current (as-of-today) burdened-cost breakdown '
  '(staff_burdened_cost_breakdown), LEFT JOINed so someone with no '
  'comp_periods row covering today still appears with null cost fields '
  'instead of silently vanishing — department/employment-type/cost- '
  'component/individual breakouts are all client-side pivots of this one '
  'array. trend = labor_forecast_breakdown(p_from, p_to), the forward '
  'monthly projection. Built entirely from Team-setup data — deliberately '
  'not tied to logged or planned hours.';
