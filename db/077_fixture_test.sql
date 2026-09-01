-- Fixture test for 077 — NOT a migration, do not ship this file.
-- Run in a transaction against a scratch db (or prod, rolled back) that
-- already has 001-076 applied. Two parts:
--   A. snapshot the pre-077 staff_annual_burdened_cost/staff_annual_labor_cost
--      bodies, apply 077, and prove the new thin wrappers are byte-identical
--      to the old ones across a real cross-section of staff + a synthetic
--      adversarial fixture set.
--   B. prove labor_forecast_breakdown's total_cents sums to exactly what
--      forecast_page's labor_forecast_month.total already reports, across
--      the same 4 ranges db/076_fixture_test.sql uses.
--
-- Results come back as an actual table of rows (not RAISE NOTICE — Supabase's
-- SQL editor doesn't reliably surface those), one row per check, with a
-- status column reading PASS or FAIL. Every FAIL row also shows the old vs.
-- new value that disagreed.
--
-- Usage:
--   1. begin;
--   2. paste this whole file
--   3. read the results table — every status column must say PASS
--   4. rollback;   -- always — restores everything to its pre-077 state,
--                  -- whether the test passed or failed

begin;

-- ---------------------------------------------------------------- setup --
-- snapshot the pre-077 formula under scratch names (bodies copied verbatim
-- from db/057_batch_burdened_cost_settings.sql and
-- db/052_peo_fee_excluded_from_hourly_rate.sql)
create or replace function _staff_annual_burdened_cost_057(p_staff_id uuid, p_on date)
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

create or replace function _staff_annual_labor_cost_052(p_staff_id uuid, p_on date)
returns bigint as $$
  with base as (
    select _staff_annual_burdened_cost_057(p_staff_id, p_on) as burdened
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

-- install 077 (inlined here, identical to db/077_labor_page.sql, so this
-- whole file runs standalone in the Supabase SQL editor)
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

create or replace function staff_annual_burdened_cost(p_staff_id uuid, p_on date)
returns bigint as $$
  select burdened_cents from staff_burdened_cost_breakdown(p_staff_id, p_on)
$$ language sql stable;

create or replace function staff_annual_labor_cost(p_staff_id uuid, p_on date)
returns bigint as $$
  select total_cents from staff_burdened_cost_breakdown(p_staff_id, p_on)
$$ language sql stable;

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

create or replace function labor_page(p_from date, p_to date)
returns jsonb as $$
  select jsonb_build_object(
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

-- ------------------------------------------------------- fixture staff --
-- literal ids so no PL/pgSQL variables are needed anywhere in this test.
-- salaried enrolled 401k+HI, hourly, contractor, someone already over the
-- SS wage base, HI and NY work_state (SDI).
insert into staff (id, name, department, active, start_date, enrolled_401k, enrolled_health_insurance, work_state) values
  ('a0000000-0000-4000-8000-000000000001', 'Fixture Salary',          'Test', true, '2020-01-01', true,  true,  'CA'),
  ('a0000000-0000-4000-8000-000000000002', 'Fixture Hourly',          'Test', true, '2023-06-01', false, false, 'TX'),
  ('a0000000-0000-4000-8000-000000000003', 'Fixture Contractor',      'Test', true, '2022-01-01', false, false, 'FL'),
  ('a0000000-0000-4000-8000-000000000004', 'Fixture Over Wage Base',  'Test', true, '2018-01-01', true,  false, 'NV'),
  ('a0000000-0000-4000-8000-000000000005', 'Fixture HI SDI',          'Test', true, '2021-03-01', false, false, 'HI'),
  ('a0000000-0000-4000-8000-000000000006', 'Fixture NY SDI',          'Test', true, '2021-03-01', false, false, 'NY');

insert into comp_periods (staff_id, starts_on, kind, annual_cost, hourly_cost, weekly_capacity, employment_type) values
  ('a0000000-0000-4000-8000-000000000001', '2020-01-01', 'salary', 9500000,  0,    40, 'full_time'),
  ('a0000000-0000-4000-8000-000000000002', '2023-06-01', 'hourly', 0,        4500, 30, 'part_time'),
  ('a0000000-0000-4000-8000-000000000003', '2022-01-01', 'salary', 12000000, 0,    40, 'contractor'),
  ('a0000000-0000-4000-8000-000000000004', '2018-01-01', 'salary', 30000000,0,    40, 'full_time'),
  ('a0000000-0000-4000-8000-000000000005', '2021-03-01', 'salary', 8000000, 0,    40, 'full_time'),
  ('a0000000-0000-4000-8000-000000000006', '2021-03-01', 'salary', 8500000, 0,    40, 'full_time');

-- ------------------------------------------------------------- results --
-- one row per check. every "status" cell must read PASS.
with fixture_ids(id, label) as (
  values
    ('a0000000-0000-4000-8000-000000000001'::uuid, 'Fixture Salary'),
    ('a0000000-0000-4000-8000-000000000002'::uuid, 'Fixture Hourly'),
    ('a0000000-0000-4000-8000-000000000003'::uuid, 'Fixture Contractor'),
    ('a0000000-0000-4000-8000-000000000004'::uuid, 'Fixture Over Wage Base'),
    ('a0000000-0000-4000-8000-000000000005'::uuid, 'Fixture HI SDI'),
    ('a0000000-0000-4000-8000-000000000006'::uuid, 'Fixture NY SDI')
),
part_a_fixtures as (
  select
    'A: fixture' as section,
    f.label,
    _staff_annual_burdened_cost_057(f.id, current_date)::text || ' / ' || _staff_annual_labor_cost_052(f.id, current_date)::text as old_value,
    staff_annual_burdened_cost(f.id, current_date)::text || ' / ' || staff_annual_labor_cost(f.id, current_date)::text as new_value,
    case when _staff_annual_burdened_cost_057(f.id, current_date) is not distinct from staff_annual_burdened_cost(f.id, current_date)
          and _staff_annual_labor_cost_052(f.id, current_date)   is not distinct from staff_annual_labor_cost(f.id, current_date)
         then 'PASS' else 'FAIL' end as status
  from fixture_ids f
),
part_a_real as (
  select count(*) as n
  from staff s
  cross join (values (current_date), (current_date - interval '6 months'), (current_date + interval '3 months')) d(p_on)
  where _staff_annual_burdened_cost_057(s.id, d.p_on::date) is distinct from staff_annual_burdened_cost(s.id, d.p_on::date)
     or _staff_annual_labor_cost_052(s.id, d.p_on::date)   is distinct from staff_annual_labor_cost(s.id, d.p_on::date)
),
ranges as (
  select * from (values
    (date_trunc('month', current_date - interval '6 months')::date, date_trunc('month', current_date + interval '6 months')::date),
    (date_trunc('month', current_date - interval '1 month')::date,  date_trunc('month', current_date + interval '1 month')::date),
    (date_trunc('month', current_date - interval '24 months')::date, date_trunc('month', current_date - interval '13 months')::date),
    (date_trunc('month', current_date + interval '1 month')::date,  date_trunc('month', current_date + interval '18 months')::date)
  ) as t(p_from, p_to)
),
fc as (
  select r.p_from, r.p_to, (fp.value->>'month')::date as month, (fp.value->>'total')::bigint as fp_total
  from ranges r
  cross join lateral jsonb_array_elements(forecast_page(r.p_from, r.p_to) -> 'labor_forecast_month') fp
),
lb as (
  select r.p_from, r.p_to, lfb.month, lfb.total_cents as lb_total
  from ranges r
  cross join lateral labor_forecast_breakdown(r.p_from, r.p_to) lfb
),
part_b as (
  select count(*) as n
  from fc full outer join lb using (p_from, p_to, month)
  where fc.fp_total is distinct from lb.lb_total
)
select section, label, old_value, new_value, status from part_a_fixtures
union all
select 'A: real data', 'all real staff x 3 dates (current, -6mo, +3mo)', null, null,
       case when n = 0 then 'PASS' else 'FAIL (' || n || ' mismatches)' end
from part_a_real
union all
select 'B: trend', 'forecast_page vs labor_forecast_breakdown, 4 ranges', null, null,
       case when n = 0 then 'PASS' else 'FAIL (' || n || ' months differ)' end
from part_b
order by section, label;

rollback;  -- always roll back: this only ever runs as a test
