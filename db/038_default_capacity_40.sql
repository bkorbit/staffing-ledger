-- ============================================================================
--  038 — hours_page(): a person with no comp period defaults to 40h/wk
--  capacity, instead of reading as 0.
--
--  comp_current used to be comp_periods rows only (ends_on is null), so
--  anyone without a period entered yet had no row in it at all — Team
--  Hours and Home's time-allocation both then computed
--  `comp ? comp.weekly_capacity * weeksInRange : 0`, i.e. zero capacity.
--  That was a deliberate design choice at the time (DESIGN.md's Priority
--  composition fill section): a missing/zero capacity read as "every
--  client hour is over," an honest red flag that comp data needs fixing.
--
--  Boris's call now: Team is the one place capacity gets set, and it
--  should default new/incomplete records to 40 rather than silently
--  reading as 0 everywhere downstream — real comp data, once entered,
--  still wins (weekly_capacity there is never touched by this).
--
--  Changed at the source (this function), not duplicated as a `|| 40`
--  fallback in team-hours.html AND index.html separately — both already
--  read comp_current from here, so one LEFT JOIN keeps them agreeing by
--  construction instead of by two hand-kept copies of the same rule.
--  kind/annual_cost/hourly_cost/starts_on stay null for a defaulted row —
--  only weekly_capacity gets the fallback, since inventing a pay figure
--  would be a real (and wrong) guess, not a safe planning default.
-- ============================================================================

create or replace function hours_page(p_from date, p_to date)
returns jsonb as $$
with te as (
  select * from time_entries where worked_on between p_from and p_to
),
labor as (
  select te.deal_id, te.staff_id, date_trunc('month', te.worked_on)::date as month,
         te.hours, te.hours * staff_hourly_cost(te.staff_id, te.worked_on) as cost
  from te
),
planned as (
  select deal_id, staff_id, month, hours as planned_hours
  from assignments
  where month between date_trunc('month', p_from) and date_trunc('month', p_to)
)
select jsonb_build_object(
  'staff', coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active,
      'start_date', s.start_date, 'end_date', s.end_date,
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
  'forecast_page()''s own rev_proj by qbo_project_id so pages never disagree '
  'about what counts as revenue. has_recent_hours (033) is true iff this '
  'staff member has any time_entries row at all. staff_planned (034) is this '
  'person''s total assigned hours across every deal in the window. '
  'staff_deal_planned (035) is the same total broken out per deal, for the '
  'per-assignment planned-vs-logged bar in Team Hours'' expand row — all '
  'three read empty until assignments has a real entry mechanism. '
  'comp_current (038) is one row per staff member, always — weekly_capacity '
  'defaults to 40 when nobody has entered a comp period yet; kind/costs stay '
  'null in that case, since only capacity gets a safe default, never pay.';
