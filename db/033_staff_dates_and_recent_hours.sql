-- ============================================================================
--  033 — staff start/end dates, and an automatic "no recent hours" signal.
--
--  start_date/end_date are new, human-entered on the new Team Setup page —
--  informational for now (capacity math doesn't prorate by them yet).
--
--  has_recent_hours answers a different question automatically, with no data
--  entry: does this person have ANY row in time_entries at all right now?
--  Because sync-qbtime.mjs purges every time_entries row before the current
--  import cutoff on every run (db/030's cutoff feature), a staff member with
--  zero rows has logged nothing since the cutoff, period — an existence
--  check against time_entries IS "hours since cutoff" by construction, no
--  separate date comparison needed. This is what actually explains stale
--  roster entries like a person who left before the cutoff was raised: the
--  sync only ever creates/touches staff rows, never removes or deactivates
--  them, so someone with no post-cutoff activity just sits there forever
--  until something looks at time_entries and notices. staff.active stays a
--  human-owned flag (sync/pages never write it) — this is a separate,
--  purely computed signal pages can filter on by default without touching it.
-- ============================================================================

alter table staff add column if not exists start_date date;
alter table staff add column if not exists end_date date;

comment on column staff.start_date is
  'Employment start date, human-entered on Team Setup. Informational — '
  'capacity is not yet prorated by it.';
comment on column staff.end_date is
  'Employment end date, human-entered on Team Setup. Informational — '
  'capacity is not yet prorated by it; has_recent_hours (hours_page()) is '
  'what actually drives automatic roster filtering, independent of this.';

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
  'disagree about what counts as revenue. has_recent_hours (033) is true iff '
  'this staff member has any time_entries row at all, which — because the '
  'sync purges everything before its own cutoff — means "logged something '
  'since the current import cutoff." Pages use it to auto-hide stale roster '
  'entries without touching the human-owned active flag.';
