-- ============================================================================
--  095 — Hour Planning: capacity, a seed for the empty assignments table, and
--  the page payload.
--
--  assignments (001) is the planned-hours table — staff × deal × month — and
--  it has never had a writer. hours_page already reads it (staff_planned,
--  staff_deal_planned, deal_planned), so every planned-hours column on Team
--  Hours, Project Hours and Client Profitability has shown 0 since day one.
--  The Scoping tool (096+) needs it populated: its capacity check asks "who is
--  free in the flight months", and an empty table answers "everyone".
--
--  Three things land here, nothing about scopes yet:
--
--  staff_capacity(p_from, p_to)
--    Per (staff, month): planning capacity = weekly_capacity / 5 × business
--    days the person is employed in that month × target utilization — the
--    SAME business-day rule Team Hours already uses for its capacity column
--    (a 30-day month with 22 Mon–Fris differs from a 31-day month with 21),
--    clipped to start_date / end_date. Only active, tracks_capacity people.
--    committed = every assignments row in that month (human or seed),
--    free = capacity − committed. Target utilization is the settings knob
--    scope_target_utilization_pct (default 80): the share of a person's
--    hours that may be planned onto client work; the rest is internal time.
--
--  seed_assignments(p_lookback, p_by)
--    Day-one baseline. For every live deal (won/active, not hidden, flight
--    still running) and every active person who logged counted hours on it
--    in the trailing window: average = round(sum(hours) / lookback, 2) —
--    divided by the LOOKBACK LENGTH, not by months-with-hours, so someone who
--    worked one of three months averages down rather than being planned at
--    their busiest. One row per remaining flight month, set_by
--    'seed:trailing-actuals'. A rerun replaces the seed layer: seed rows are
--    updated, seed rows whose (person, deal, month) is no longer in the basis
--    are deleted, and a row a HUMAN wrote is never touched (the upsert's
--    WHERE clause). Counted hours = the rule hours_page uses since 090:
--    attribution not in ('excluded', 'timeoff'), and staff.exclude_hours off.
--    Lookback defaults to settings assignments_seed_lookback_months (3).
--    Writes assignments_seed_last_run so Settings can show when it ran.
--
--  clear_seed_assignments()
--    Deletes ONLY seed-stamped rows. Human rows survive. Settings' "Clear
--    seed" button — the control that makes the seed safe to try.
--
--  assignments_page(p_from, p_to)
--    One payload for app/hour-planning.html: roster, live deals overlapping
--    the range, assignments in the range with their provenance (set_by), the
--    trailing averages the seed would write (shown as ghost hints in empty
--    cells), logged actuals per (person, deal, month) for closed months in
--    the range, staff_capacity rows, and the knobs. No cost, no rate: this
--    page is hours only.
--
--  assignments_seed_basis(p_lookback) is the one copy of the averaging rule,
--  read by the seed and by the page — so the ghost hint a person sees is the
--  number the seed would write, to the hundredth.
--
--  Fixture: db/095_fixture_test.sql (PGlite bed, then mutate and watch it fail).
--  Page: app/hour-planning.html. Settings tab: Scoping (seed panel).
-- ============================================================================

create index if not exists assignments_staff_month_idx on assignments (staff_id, month);

insert into settings (key, value, set_by) values
  ('assignments_seed_lookback_months', '3'::jsonb,  'migration-095'),
  ('scope_target_utilization_pct',     '80'::jsonb, 'migration-095')
on conflict (key) do nothing;

-- ---------------------------------------------------------------------------
-- staff_capacity: planning capacity per person per month, business-day rule.
-- ---------------------------------------------------------------------------
create or replace function staff_capacity(p_from date, p_to date)
returns table (
  staff_id        uuid,
  month           date,
  weekly_capacity numeric,
  business_days   int,
  capacity_hours  numeric,
  committed_hours numeric,
  free_hours      numeric
) as $$
with util as (
  select coalesce((select (value #>> '{}')::numeric from settings
                   where key = 'scope_target_utilization_pct'), 80) as pct
),
months as (
  select gs::date as month
  from generate_series(date_trunc('month', p_from), date_trunc('month', p_to), interval '1 month') gs
),
people as (
  select s.id as staff_id, m.month,
         coalesce(cp.weekly_capacity, 40) as weekly_capacity,
         -- employment clipped to the month: neither date = the whole month
         greatest(m.month, coalesce(s.start_date, m.month)) as emp_from,
         least((m.month + interval '1 month - 1 day')::date,
               coalesce(s.end_date, (m.month + interval '1 month - 1 day')::date)) as emp_to
  from staff s
  cross join months m
  left join lateral (
    select weekly_capacity from comp_periods cp
    where cp.staff_id = s.id and cp.starts_on <= m.month
      and (cp.ends_on is null or cp.ends_on >= m.month)
    order by cp.starts_on desc limit 1
  ) cp on true
  where s.active and s.tracks_capacity
),
biz as (
  select p.*,
         case when p.emp_from > p.emp_to then 0 else
           (select count(*)::int from generate_series(p.emp_from, p.emp_to, interval '1 day') d
            where extract(isodow from d) < 6) end as business_days
  from people p
),
committed as (
  select a.staff_id, a.month, sum(a.hours) as h
  from assignments a
  where a.month between date_trunc('month', p_from) and date_trunc('month', p_to)
  group by a.staff_id, a.month
)
select b.staff_id, b.month, b.weekly_capacity, b.business_days,
       round(b.weekly_capacity / 5 * b.business_days * (select pct from util) / 100, 2) as capacity_hours,
       coalesce(c.h, 0)::numeric as committed_hours,
       round(b.weekly_capacity / 5 * b.business_days * (select pct from util) / 100, 2) - coalesce(c.h, 0) as free_hours
from biz b
left join committed c on c.staff_id = b.staff_id and c.month = b.month;
$$ language sql stable;

comment on function staff_capacity(date, date) is
  'Planning capacity per active tracks_capacity person per month: weekly_capacity/5 × business days employed in the month (Team Hours'' rule, clipped to start/end dates) × scope_target_utilization_pct. committed = all assignments rows that month; free = capacity − committed. No cost.';

-- ---------------------------------------------------------------------------
-- assignments_seed_basis: the ONE copy of the trailing-average rule.
-- ---------------------------------------------------------------------------
create or replace function assignments_seed_basis(p_lookback int default null)
returns table (
  staff_id   uuid,
  deal_id    uuid,
  avg_hours  numeric,
  flight_end date,
  lookback   int,
  win_from   date,
  cur        date
) as $$
with k as (
  select coalesce(p_lookback,
                  (select (value #>> '{}')::int from settings where key = 'assignments_seed_lookback_months'),
                  3) as lookback,
         date_trunc('month', current_date)::date as cur
),
w as (
  select lookback, cur, (cur - (lookback || ' months')::interval)::date as win_from from k
)
select te.staff_id, te.deal_id,
       round(sum(te.hours) / w.lookback, 2) as avg_hours,
       d.flight_end, w.lookback, w.win_from, w.cur
from time_entries te
cross join w
join deals d on d.id = te.deal_id
join staff s on s.id = te.staff_id
where te.worked_on >= w.win_from and te.worked_on < w.cur
  and coalesce(te.attribution, '') not in ('excluded', 'timeoff')
  and d.status in ('won', 'active') and not d.hidden
  and d.flight_end >= w.cur
  and s.active and not s.exclude_hours
group by te.staff_id, te.deal_id, d.flight_end, w.lookback, w.win_from, w.cur
having round(sum(te.hours) / w.lookback, 2) > 0;
$$ language sql stable;

comment on function assignments_seed_basis(int) is
  'Trailing average per (person, live deal): counted hours in the last N whole months ÷ N (the lookback, not months-with-hours). Read by seed_assignments and assignments_page so the ghost hint equals what the seed writes.';

-- ---------------------------------------------------------------------------
-- seed_assignments: write the seed layer; never touch a human row.
-- ---------------------------------------------------------------------------
create or replace function seed_assignments(p_lookback int default null, p_by text default null)
returns jsonb as $$
declare
  v_written int; v_deleted int; v_pairs int; v_lookback int; v_from date; v_cur date;
  v_result jsonb;
begin
  -- a second call in the same transaction (fixture reruns) must not trip
  -- over the first call's temp table
  drop table if exists _seed_target;
  create temp table _seed_target on commit drop as
  select b.staff_id, b.deal_id, b.avg_hours, gs::date as month, b.lookback, b.win_from, b.cur
  from assignments_seed_basis(p_lookback) b
  cross join lateral generate_series(b.cur, date_trunc('month', b.flight_end), interval '1 month') gs;

  select count(distinct (staff_id, deal_id)), max(lookback), max(win_from), max(cur)
    into v_pairs, v_lookback, v_from, v_cur from _seed_target;
  if v_lookback is null then
    v_lookback := coalesce(p_lookback, (select (value #>> '{}')::int from settings where key = 'assignments_seed_lookback_months'), 3);
    v_cur := date_trunc('month', current_date)::date;
    v_from := (v_cur - (v_lookback || ' months')::interval)::date;
  end if;

  with ins as (
    insert into assignments (staff_id, deal_id, month, hours, set_by, set_at)
    select staff_id, deal_id, month, avg_hours, 'seed:trailing-actuals', now() from _seed_target
    on conflict (staff_id, deal_id, month) do update
      set hours = excluded.hours, set_at = now()
      where assignments.set_by = 'seed:trailing-actuals'
    returning 1
  ) select count(*) into v_written from ins;

  with del as (
    delete from assignments a
    where a.set_by = 'seed:trailing-actuals'
      and not exists (select 1 from _seed_target t
                      where t.staff_id = a.staff_id and t.deal_id = a.deal_id and t.month = a.month)
    returning 1
  ) select count(*) into v_deleted from del;

  v_result := jsonb_build_object(
    'rows_written', v_written, 'rows_deleted', v_deleted, 'pairs', coalesce(v_pairs, 0),
    'lookback', v_lookback, 'from', v_from, 'to', v_cur, 'at', now(), 'by', p_by);

  insert into settings (key, value, set_by, set_at)
  values ('assignments_seed_last_run', v_result, coalesce(p_by, 'seed_assignments'), now())
  on conflict (key) do update set value = excluded.value, set_by = excluded.set_by, set_at = excluded.set_at;

  return v_result;
end;
$$ language plpgsql volatile;

comment on function seed_assignments(int, text) is
  'Replaces the seed layer of assignments from assignments_seed_basis: one row per remaining flight month per (person, live deal), set_by seed:trailing-actuals. Updates only seed rows, deletes seed rows no longer in the basis, never touches a human row. Records assignments_seed_last_run.';

create or replace function clear_seed_assignments()
returns jsonb as $$
declare v_deleted int;
begin
  with del as (delete from assignments where set_by = 'seed:trailing-actuals' returning 1)
  select count(*) into v_deleted from del;
  delete from settings where key = 'assignments_seed_last_run';
  return jsonb_build_object('rows_deleted', v_deleted);
end;
$$ language plpgsql volatile;

comment on function clear_seed_assignments() is
  'Deletes only assignments rows stamped seed:trailing-actuals and forgets the last seed run. Human rows survive.';

-- ---------------------------------------------------------------------------
-- assignments_page: the Hour Planning payload. Hours only — no cost, no rate.
-- ---------------------------------------------------------------------------
create or replace function assignments_page(p_from date, p_to date)
returns jsonb as $$
with rng as (
  select date_trunc('month', p_from)::date as m_from,
         date_trunc('month', p_to)::date as m_to,
         (date_trunc('month', p_to) + interval '1 month - 1 day')::date as d_to,
         date_trunc('month', current_date)::date as cur
),
te as (
  select te.staff_id, te.deal_id, date_trunc('month', te.worked_on)::date as month, sum(te.hours) as hours
  from time_entries te, rng
  where te.worked_on >= rng.m_from and te.worked_on <= rng.d_to
    and te.worked_on < rng.cur
    and te.staff_id is not null and te.deal_id is not null
    and coalesce(te.attribution, '') not in ('excluded', 'timeoff')
  group by te.staff_id, te.deal_id, date_trunc('month', te.worked_on)
)
select jsonb_build_object(
  'range', (select jsonb_build_object('from', m_from, 'to', m_to, 'current', cur) from rng),
  'staff', coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active,
      'tracks_capacity', s.tracks_capacity, 'exclude_hours', s.exclude_hours,
      'start_date', s.start_date, 'end_date', s.end_date) order by s.name)
      from staff s), '[]'::jsonb),
  'deals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', d.id, 'name', d.name, 'client_id', d.client_id, 'client_name', c.name,
      'status', d.status, 'flight_start', d.flight_start, 'flight_end', d.flight_end) order by c.name, d.name)
      from deals d join clients c on c.id = d.client_id, rng
      where d.status in ('won', 'active') and not d.hidden
        and d.flight_start <= rng.d_to and d.flight_end >= rng.m_from), '[]'::jsonb),
  'assignments', coalesce((select jsonb_agg(jsonb_build_object(
      'id', a.id, 'staff_id', a.staff_id, 'deal_id', a.deal_id, 'month', a.month,
      'hours', a.hours, 'set_by', a.set_by, 'set_at', a.set_at))
      from assignments a, rng where a.month between rng.m_from and rng.m_to), '[]'::jsonb),
  'trailing', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', b.staff_id, 'deal_id', b.deal_id, 'avg_hours', b.avg_hours))
      from assignments_seed_basis(null) b), '[]'::jsonb),
  'actuals', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'deal_id', deal_id, 'month', month, 'hours', hours)) from te), '[]'::jsonb),
  'capacity', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', sc.staff_id, 'month', sc.month, 'weekly_capacity', sc.weekly_capacity,
      'business_days', sc.business_days, 'capacity_hours', sc.capacity_hours,
      'committed_hours', sc.committed_hours, 'free_hours', sc.free_hours))
      from staff_capacity(p_from, p_to) sc), '[]'::jsonb),
  'settings', jsonb_build_object(
      'lookback_months', coalesce((select (value #>> '{}')::int from settings where key = 'assignments_seed_lookback_months'), 3),
      'utilization_pct', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_utilization_pct'), 80),
      'last_seed_run', (select value from settings where key = 'assignments_seed_last_run'))
);
$$ language sql stable;

comment on function assignments_page(date, date) is
  'Hour Planning in one round trip: roster, live deals overlapping the range, assignments in range with provenance (set_by), the seed''s trailing averages (ghost hints), counted actuals per person/deal/closed month, staff_capacity rows, knobs. Hours only — never a cost or a rate.';
