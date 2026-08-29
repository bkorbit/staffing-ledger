-- ============================================================================
--  032 — time_off gets real hours, not just which dates.
--
--  QuickBooks Time reports a real duration for a time-off entry same as any
--  other timesheet row, but sync-qbtime.mjs was only ever recording WHICH
--  dates had time off (a Set of date strings, merged into ranges), throwing
--  the actual hours away entirely — a half-day and a full day looked
--  identical. Fixed on the sync side alongside this migration: hours are now
--  summed per date, then per merged range, and written here.
--
--  hours is a RANGE total, not a per-day figure — a half-day mixed with full
--  days inside one merged range is only reflected in the total. Existing rows
--  default to 0 (unknown) until the next sync run overwrites them for real —
--  every currently-synced row sits inside the sync's own replace window.
-- ============================================================================

alter table time_off add column if not exists hours numeric(7,2) not null default 0;

comment on column time_off.hours is
  'Total hours off across the whole starts_on..ends_on range (a range total, '
  'not a per-day figure — a half-day mixed with full days in one merged range '
  'is only reflected in the sum). Written by sync-qbtime.mjs from QuickBooks '
  'Time''s own logged duration. Existing rows default to 0 until the next '
  'sync run overwrites them with a real figure.';

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
      'staff_id', staff_id, 'starts_on', starts_on, 'ends_on', ends_on, 'kind', kind, 'hours', hours))
      from time_off where ends_on >= p_from and starts_on <= p_to), '[]'::jsonb)
);
$$ language sql stable;

comment on function hours_page is
  'The Team page and Hour-tracking Dashboard''s one round trip. Bottom-up labor '
  'cost from actual hours x each staff member''s own resolved comp rate — '
  'deliberately separate from v_deal_month_forecast''s top-down QBO-COGS plan. '
  'Revenue is NOT computed here; the dashboard joins deal_labor against '
  'forecast_page()''s own rev_proj by qbo_project_id so the two pages never '
  'disagree about what counts as revenue. time_off.hours (032) is a range '
  'total; a query window that only partially overlaps a range gets the whole '
  'range''s hours here — the client prorates by day-overlap if it needs to.';
