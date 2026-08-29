-- ============================================================================
--  035 — per-(staff, deal) planned hours, for Team Hours' assignment pop-out.
--
--  034 added staff_planned (per-STAFF total, for the pacing column) and
--  deal_planned already existed (per-DEAL total, for Client/Project Hours'
--  "vs planned" column) — neither answers "how many hours was THIS person
--  planned for on THIS specific deal," which the pop-out's per-assignment
--  planned-vs-logged bar needs. assignments is still empty (no entry
--  mechanism yet) — this returns [] until that changes, same as the other
--  planned aggregates already do.
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
      'staff_id', staff_id, 'kind', kind, 'annual_cost', annual_cost,
      'hourly_cost', hourly_cost, 'weekly_capacity', weekly_capacity, 'starts_on', starts_on))
      from comp_periods where ends_on is null), '[]'::jsonb),
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
  'three read empty until assignments has a real entry mechanism.';
