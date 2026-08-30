-- ============================================================================
--  072 — health_insurance_forecast_month's cutover (071) was purely
--  date-based: on/after 11/1/2026 it switches to summing tier rates,
--  regardless of whether health_insurance_tiers actually has real (non-$0)
--  rates yet or anyone's been assigned a tier. Seen live: the flat-average
--  bump correctly shows through October, then falls to $0 in November
--  because setup isn't finished — the date arrived before the data did.
--
--  Fix: only take the tier-based branch once there's real tier data (at
--  least one tier with monthly_cost > 0) AND at least one person actually
--  assigned to a tier. Otherwise keep using the flat average past the
--  cutover date too, so the forecast never silently drops to zero just
--  because the tier rates/assignments haven't been entered yet.
-- ============================================================================

create or replace function health_insurance_forecast_month(p_month date)
returns bigint as $$
  select case
    when p_month >= coalesce(
      (select (value #>> '{}')::date from settings where key = 'health_insurance_flat_rate_cutover'),
      '2026-11-01'::date
    )
    and exists (select 1 from health_insurance_tiers where monthly_cost > 0)
    and exists (select 1 from staff where health_insurance_tier is not null)
    then coalesce((
      select sum(t.monthly_cost)
      from staff s
      join health_insurance_tiers t on t.tier_key = s.health_insurance_tier
      where s.enrolled_health_insurance
    ), 0)
    else coalesce(round(
      (select sum(amount) from v_cost_lines_classified
       where class = 'payroll' and account_name ilike '%health insurance%'
         and issued_on >= date_trunc('month', current_date) - interval '6 months'
         and issued_on <  date_trunc('month', current_date)
      )::numeric / 6
    )::bigint, 0)
  end;
$$ language sql stable;

comment on function health_insurance_forecast_month is
  'Health insurance cost for one future month: the flat trailing-6-month GL '
  'average, UNLESS the month is on/after the cutover setting AND real tier '
  'data actually exists (a non-zero rate and at least one assigned person) '
  '— only then does it switch to summing each enrolled person''s tier rate '
  '(072, guarding the date-only cutover 071 shipped with, which could fall '
  'to $0 if the date arrived before setup was finished).';
