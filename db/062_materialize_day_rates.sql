-- ============================================================================
--  062 — day_rates (061) was being flattened away, silently undoing the dedup.
--
--  061's plain distinct-and-join had ZERO effect (2523ms -> 2440ms, noise) —
--  the follow-up EXPLAIN ANALYZE showed why. day_rates was referenced only
--  once (from labor), so Postgres inlined it into one flattened query and
--  pushed staff_hourly_cost()'s evaluation past the grouping boundary, back
--  down to the Hash Join's own row production: the join reported 2409ms of
--  its own time despite BOTH children (the te scan, and the HashAggregate
--  computing the 751 distinct staff/day pairs) finishing in under 2ms each.
--  The Hash side's own reported width (20 bytes — room for staff_id+date,
--  none for a computed rate) confirmed the rate was never actually being
--  carried by the aggregate; it was being recomputed once per of the 2140
--  OUTPUT rows of the join, exactly the redundant work 061 was meant to cut.
--
--  MATERIALIZED (PG12+) is the one-word fix: it forces day_rates to actually
--  execute as its own step and be treated as an opaque prior result, so the
--  planner can no longer flatten staff_hourly_cost()'s evaluation into the
--  outer join. Nothing else about hours_page changes.
-- ============================================================================

create or replace function hours_page(p_from date, p_to date)
returns jsonb as $$
with te as (
  select * from time_entries where worked_on between p_from and p_to
),
staff_days as (
  select distinct staff_id, worked_on from te
),
day_rates as materialized (
  select staff_id, worked_on, staff_hourly_cost(staff_id, worked_on) as rate
  from staff_days
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
  'capacity gets a safe default, never pay. day_rates (061, pinned '
  'MATERIALIZED by 062) resolves staff_hourly_cost() once per distinct '
  '(staff_id, worked_on) instead of once per raw time_entries row — without '
  'MATERIALIZED, Postgres flattens a once-referenced CTE and can push the '
  'function call back down to per-output-row, silently undoing the dedup.';
