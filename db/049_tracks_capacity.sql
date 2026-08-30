-- ============================================================================
--  049 — tracks_capacity: lets the roster hold everyone, not just the
--  execution side, without polluting capacity/utilization math.
--
--  Team was designed to only manage people on the execution side of the
--  business (media/creative/accounts — the staff whose hours actually get
--  logged against client work and whose capacity is a real planning number).
--  Sales, marketing, leadership etc. were never added, because they aren't
--  tied to capacity in that sense.
--
--  Now that comp_periods/staff_annual_burdened_cost (040-048) give a real
--  fully-loaded cost per person, that math is completely capacity-agnostic
--  — it only needs a comp_periods row, nothing about hours or utilization.
--  So the plan is: everyone stays in ONE staff table (reusing all of that
--  cost machinery for free), and tracks_capacity is the flag that keeps
--  Team Hours/Home's capacity-and-utilization rollups scoped to execution
--  staff only, the same way has_recent_hours already keeps stale roster
--  entries out without touching the human-owned active flag.
--
--  Defaults true: every person in the system today IS execution-side (that
--  was the whole roster's previous definition), so nothing about their
--  capacity math changes on this migration alone. false is something a
--  human sets going forward for a new non-execution hire.
-- ============================================================================

alter table staff add column if not exists tracks_capacity boolean not null default true;

comment on column staff.tracks_capacity is
  'Whether this person counts toward capacity/utilization (Team Hours, '
  'Home''s department rollup) — true for execution-side staff (the '
  'original scope of this roster), false for sales/marketing/leadership/etc, '
  'who can now live in the same staff table for fully-loaded cost purposes '
  '(staff_annual_burdened_cost, 040-048) without being counted as capacity '
  'that was never real. Human-set on Team, defaults true since every '
  'existing person in the system already was execution-side.';

-- hours_page() ships the flag through to Team Hours/Home so they can filter
-- on it client-side, same as active/has_recent_hours already are — the rest
-- of the function is untouched from 038.
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
  'forecast_page()''s own rev_proj by qbo_project_id so pages never disagree '
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
  'capacity gets a safe default, never pay.';
