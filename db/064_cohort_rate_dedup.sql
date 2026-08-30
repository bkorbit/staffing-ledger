-- ============================================================================
--  064 — hours_page: resolve staff_hourly_cost() once per (staff, rate
--  cohort) instead of once per distinct (staff, day). 878ms -> real target
--  is sub-100ms; 062 got the per-day cost down to ~1.1ms x 751 calls, and
--  there's no further win available without reducing the CALL COUNT itself.
--
--  A person's rate is NOT constant for their whole comp_periods span — it
--  can also shift mid-period on two date thresholds inside
--  staff_annual_burdened_cost (057): their own 401k eligibility date
--  (staff_401k_eligibility_date, gated by enrolled_401k) and the company-
--  wide health_insurance_start_date setting (gated by
--  enrolled_health_insurance). Naively grouping "once per comp_period"
--  would silently misprice anyone crossing one of those two thresholds
--  mid-period — exactly the kind of payroll bug this project's rules exist
--  to prevent. Read staff_annual_burdened_cost/staff_hourly_cost end to
--  end (057, 041): those three conditions — which comp_periods row covers
--  the date, the 401k-eligibility comparison, and the health-insurance-
--  start comparison — are the ONLY places p_on enters the calculation.
--  Every other input (FICA/FUTA/workers-comp/SUTA rates, work_state, the
--  employer settings) is looked up by CURRENT state, not by p_on, so it's
--  already identical for every date in one query execution regardless of
--  which day is asked.
--
--  So: two dates for the same staff member produce IDENTICAL output from
--  staff_hourly_cost() if and only if they share the same covering
--  comp_periods row AND the same answer to both threshold comparisons.
--  Grouping time_entries by that exact triple (not by calendar day) is
--  therefore provably lossless — collapses to one call per staff for the
--  overwhelming majority of ranges (comp changes, 401k eligibility, and
--  the one-time HI rollout date are all rare relative to a month), while
--  staying byte-for-byte correct for the rare person who crosses one of
--  the three mid-range: they simply land in two cohorts instead of one,
--  each priced correctly on its own days.
--
--  The comp_periods "covering row" join below replicates staff_hourly_cost/
--  staff_annual_burdened_cost's own selection exactly (same predicate, same
--  order by starts_on desc limit 1, same LEFT JOIN so a genuine gap — no
--  period covering a date — carries through as NULL, same as the function
--  returning NULL). staff_401k_eligibility_date is IMMUTABLE pure date
--  arithmetic (031: no table access), so evaluating it here is free; the
--  health_insurance_start_date setting is read once for the whole query,
--  not once per row, since (like every other setting) it doesn't vary by
--  p_on.
-- ============================================================================

create or replace function hours_page(p_from date, p_to date)
returns jsonb as $$
with te as (
  select * from time_entries where worked_on between p_from and p_to
),
staff_days as (
  select distinct staff_id, worked_on from te
),
hi_setting as (
  select coalesce((select (value #>> '{}')::date from settings
                   where key = 'health_insurance_start_date'), '2099-01-01'::date) as hi_start
),
-- Per (staff, day): which comp_periods row covers it, and this staff's
-- answer to the two threshold comparisons on that day. Three columns that
-- fully determine staff_hourly_cost()'s output for that day (see header).
cohorts as (
  select
    sd.staff_id, sd.worked_on,
    cov.starts_on as period_key,
    (s.enrolled_401k
       and staff_401k_eligibility_date(s.start_date) is not null
       and sd.worked_on >= staff_401k_eligibility_date(s.start_date)) as k401_key,
    (s.enrolled_health_insurance and sd.worked_on >= hi_setting.hi_start) as hi_key
  from staff_days sd
  join staff s on s.id = sd.staff_id
  cross join hi_setting
  left join lateral (
    select cp.starts_on
    from comp_periods cp
    where cp.staff_id = sd.staff_id
      and cp.starts_on <= sd.worked_on
      and (cp.ends_on is null or cp.ends_on >= sd.worked_on)
    order by cp.starts_on desc
    limit 1
  ) cov on true
),
-- One staff_hourly_cost() call per distinct cohort — MATERIALIZED so the
-- planner can't flatten this and push the call back down to per-row (062
-- hit exactly this trap with the plain per-day version).
cohort_rates as materialized (
  select staff_id, period_key, k401_key, hi_key,
         staff_hourly_cost(staff_id, min(worked_on)) as rate
  from cohorts
  group by staff_id, period_key, k401_key, hi_key
),
day_rates as (
  select c.staff_id, c.worked_on, cr.rate
  from cohorts c
  join cohort_rates cr
    on cr.staff_id = c.staff_id
   and cr.period_key is not distinct from c.period_key
   and cr.k401_key = c.k401_key
   and cr.hi_key = c.hi_key
),
labor as (
  select te.deal_id, te.staff_id, date_trunc('month', te.worked_on)::date as month,
         te.hours, te.hours * day_rates.rate as cost
  from te
  join day_rates on day_rates.staff_id = te.staff_id and day_rates.worked_on = te.worked_on
),
planned as (
  select deal_id, staff_id, month, hours as planned_hours
  from assignments
  where month between date_trunc('month', p_from) and date_trunc('month', p_to)
)
select jsonb_build_object(
  'staff', coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active,
      'start_date', s.start_date, 'end_date', s.end_date, 'tracks_capacity', s.tracks_capacity,
      'has_recent_hours', exists(select 1 from time_entries te2 where te2.staff_id = s.id)))
      from staff s), '[]'::jsonb),
  'comp_current', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', s.id, 'kind', cp.kind, 'annual_cost', cp.annual_cost,
      'hourly_cost', cp.hourly_cost, 'weekly_capacity', coalesce(cp.weekly_capacity, 40),
      'starts_on', cp.starts_on))
      from staff s left join comp_periods cp on cp.staff_id = s.id and cp.ends_on is null), '[]'::jsonb),
  'staff_hours_month', coalesce((select jsonb_agg(t) from (
      select staff_id, month, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor group by staff_id, month) t), '[]'::jsonb),
  'staff_hours_deal', coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by staff_id, deal_id) t), '[]'::jsonb),
  'staff_planned', coalesce((select jsonb_agg(t) from (
      select staff_id, sum(planned_hours)::numeric as planned_hours
      from planned group by staff_id) t), '[]'::jsonb),
  'staff_deal_planned', coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by staff_id, deal_id) t), '[]'::jsonb),
  'deal_labor', coalesce((select jsonb_agg(t) from (
      select deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by deal_id) t), '[]'::jsonb),
  'deal_planned', coalesce((select jsonb_agg(t) from (
      select deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by deal_id) t), '[]'::jsonb),
  'time_off', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'starts_on', starts_on, 'ends_on', ends_on, 'kind', kind, 'hours', hours))
      from time_off where ends_on >= p_from and starts_on <= p_to), '[]'::jsonb)
);
$$ language sql stable;

comment on function hours_page is
  'The Team Hours page''s one round trip. Bottom-up labor cost from actual '
  'hours x each staff member''s own resolved comp rate — deliberately separate '
  'from v_deal_month_forecast''s top-down QBO-COGS plan. Revenue is NOT '
  'computed here; Client Profitability/Project Hours join deal_labor against '
  'rev_proj_page()''s own rev_proj by qbo_project_id so pages never disagree '
  'about what counts as revenue. has_recent_hours (033) is true iff this '
  'staff member has any time_entries row at all. tracks_capacity (049) lets '
  'Team Hours/Home exclude non-execution staff from capacity/utilization '
  'math entirely, the same way has_recent_hours already excludes stale '
  'roster entries. staff_planned (034) is this person''s total assigned '
  'hours across every deal in the window. staff_deal_planned (035) is the '
  'same total broken out per deal, for the per-assignment planned-vs-logged '
  'bar in Team Hours'' expand row — all three read empty until assignments '
  'has a real entry mechanism. comp_current (038) is one row per staff '
  'member, always — weekly_capacity defaults to 40 when nobody has entered '
  'a comp period yet; kind/costs stay null in that case, since only '
  'capacity gets a safe default, never pay. day_rates (061-064) resolves '
  'staff_hourly_cost() once per (staff, rate cohort) — the covering '
  'comp_periods row plus the 401k-eligibility and health-insurance-start '
  'threshold comparisons, the only three places p_on affects the formula '
  '(057) — instead of once per calendar day, while staying exactly correct '
  'for anyone crossing one of those thresholds mid-range.';
