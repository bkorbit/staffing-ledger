-- ============================================================================
--  031 — hours_page(): the Team page and Hour-tracking Dashboard's one round
--  trip, bottom-up from actual logged hours.
--
--  Deliberately separate from v_deal_month_forecast's top-down, QBO-COGS-based
--  plan — hours x each staff member's own resolved cost rate is a different
--  number answering a different question, not a replacement. Revenue is NOT
--  re-derived here: the dashboard joins this function's per-deal labor cost
--  against forecast_page()'s own rev_proj by qbo_project_id, so the two pages
--  can never quietly disagree about what counts as revenue.
--
--  assignments (planned hours per staff+deal+month) is read as-is and will be
--  empty until its own entry mechanism is designed — the shape is here now so
--  the dashboard doesn't need a second migration once that lands.
-- ============================================================================

-- Cents per hour for a staff member on a given date, resolved from whichever
-- comp_periods row covers it (periods never overlap in practice, but "most
-- recently started" is the tiebreak if one ever does). Salary converts to an
-- hourly equivalent via that period's OWN weekly_capacity (annual_cost /
-- (52 * hrs/wk)) rather than a fixed constant, since capacity varies by
-- person and by period. Null — no rate — when no period covers the date, a
-- real data gap to surface rather than a guess to paper over with an average.
create or replace function staff_hourly_cost(p_staff_id uuid, p_on date)
returns bigint as $$
  select case cp.kind
    when 'hourly' then cp.hourly_cost
    when 'salary' then round(cp.annual_cost / (52 * nullif(cp.weekly_capacity, 0)))::bigint
  end
  from comp_periods cp
  where cp.staff_id = p_staff_id
    and cp.starts_on <= p_on
    and (cp.ends_on is null or cp.ends_on >= p_on)
  order by cp.starts_on desc
  limit 1
$$ language sql stable;

comment on function staff_hourly_cost is
  'Cents per hour for a staff member on a given date, resolved from whichever '
  'comp_periods row covers it. Salary divides annual_cost by that period''s own '
  'weekly_capacity * 52; hourly is used as-is. Null (no rate) if no period covers '
  'the date — a real gap to show, not a guess to paper over.';

-- p_from/p_to convention differs from forecast_page()'s: pass p_from as the
-- 1st of the start month and p_to as the LAST day of the end month (not its
-- 1st) — time_entries/time_off are day-grain and compared directly, so a
-- 1st-of-month p_to would silently drop every day after the 1st.
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
      'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active))
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
  'deal_labor', coalesce((select jsonb_agg(t) from (
      select deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by deal_id) t), '[]'::jsonb),
  'deal_planned', coalesce((select jsonb_agg(t) from (
      select deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by deal_id) t), '[]'::jsonb),
  'time_off', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'starts_on', starts_on, 'ends_on', ends_on, 'kind', kind))
      from time_off where ends_on >= p_from and starts_on <= p_to), '[]'::jsonb)
);
$$ language sql stable;

comment on function hours_page is
  'The Team page and Hour-tracking Dashboard''s one round trip. Bottom-up labor '
  'cost from actual hours x each staff member''s own resolved comp rate — '
  'deliberately separate from v_deal_month_forecast''s top-down QBO-COGS plan. '
  'Revenue is NOT computed here; the dashboard joins deal_labor against '
  'forecast_page()''s own rev_proj by qbo_project_id so the two pages never '
  'disagree about what counts as revenue.';
