-- ============================================================================
--  090 — Zero data loss from QuickBooks Time to the ledger, and a way for a
--  human to resolve what the sync could not.
--
--  Before this, sync-qbtime.mjs threw hours away in four places and hid them
--  in a fifth: an excluded person (a hardcoded name list), an unknown user,
--  a jobcode QuickBooks Time never returned, a real-looking jobcode with no
--  parsable code, and a code no won/active deal claims. The last three landed
--  in time_entries with deal_id null — indistinguishable from genuine
--  internal time, the jobcode name gone. Materialplus UC Health (Sep 2026)
--  cost a day to trace because of exactly that.
--
--  Now every timesheet hour lands in time_entries, stamped with WHERE it came
--  from (qbtime_jobcode_id, jobcode_name) and WHY it was placed where it was
--  (attribution):
--
--    deal          the jobcode's code matched a won/active deal's QBO project
--    mapped        a human mapped this jobcode to a deal (qbtime_jobcode_map)
--    internal      the jobcode's name is on the internal list, or a human
--                  resolved it as internal
--    uncoded       real-looking name, no parsable code — NEEDS A HUMAN
--    unmatched     a code, but no won/active deal claims it — NEEDS A HUMAN
--    unresolved    QuickBooks Time returned a jobcode id it never described
--    excluded      the person (staff.exclude_hours) or the jobcode (map
--                  resolution 'exclude') is excluded from labor — kept, never
--                  priced or counted
--    unknown_user  the timesheet's user was not in QuickBooks Time's user
--                  list; staff_id is null, hours are kept
--    timeoff       a human resolved the jobcode as time off; the next sync
--                  moves these hours into time_off. Kept out of labor now.
--
--  Legacy rows (before the next sync run) carry attribution null and behave
--  as they always did.
--
--  qbtime_jobcode_map is the human-owned answer, keyed by QuickBooks Time's
--  own jobcode id (stable across renames). The sync reads it FIRST — a human
--  decision always beats the name parse — and never writes it, same
--  contract as qbo_projects.jobcode_override (037) and hidden (015). A deal
--  resolution whose deal was later deleted (deal_id set null) falls back to
--  the parse, so a stale mapping can never attribute hours to nothing.
--
--  staff.exclude_hours replaces the sync's hardcoded EXCLUDED_PEOPLE list as
--  the source of truth; the list only seeds the flag when it first creates
--  that person's row. Flip it on the Team page or here in SQL.
--
--  unmapped_hours(p_from, p_to) is what Project Hours' "Unmapped hours"
--  panel reads: one group per (jobcode, attribution) needing attention, with
--  hours, people and months, so the person resolving it knows what they are
--  looking at. hours_page is re-created byte-identical to 064 except that
--  its te CTE now leaves out 'excluded' and 'timeoff' rows.
-- ============================================================================

alter table time_entries add column if not exists qbtime_jobcode_id bigint;
alter table time_entries add column if not exists jobcode_name      text;
alter table time_entries add column if not exists attribution       text;
alter table time_entries drop constraint if exists time_entries_attribution_check;
alter table time_entries add constraint time_entries_attribution_check
  check (attribution is null or attribution in
    ('deal','mapped','internal','uncoded','unmatched','unresolved','excluded','unknown_user','timeoff'));
alter table time_entries alter column staff_id drop not null;
create index if not exists time_entries_attention_idx
  on time_entries (attribution, qbtime_jobcode_id)
  where attribution in ('uncoded','unmatched','unresolved','excluded','unknown_user');

comment on column time_entries.qbtime_jobcode_id is
  'QuickBooks Time jobcode id the hours were logged under (sync-owned). Stable across renames; the key of qbtime_jobcode_map.';
comment on column time_entries.jobcode_name is
  'The jobcode''s "Parent › Child" name at sync time, so an unattributed row can be read by a human without opening QuickBooks Time.';
comment on column time_entries.attribution is
  'Why the row sits where it does — see 090 header. uncoded/unmatched/unresolved/unknown_user need a human; excluded/timeoff are kept but never priced.';

alter table staff add column if not exists exclude_hours boolean not null default false;
comment on column staff.exclude_hours is
  'Human-owned. True = this person''s QuickBooks Time hours are stored with attribution ''excluded'' and never priced or counted. Seeded from the sync''s old hardcoded list when it first creates the row.';
update staff set exclude_hours = true where lower(trim(name)) = 'hannah hoffman';

create table if not exists qbtime_jobcode_map (
  qbtime_jobcode_id bigint primary key,
  jobcode_name      text,
  resolution        text not null check (resolution in ('deal','internal','timeoff','exclude')),
  deal_id           uuid references deals(id) on delete set null,
  timeoff_kind      text,
  set_by            text,
  set_at            timestamptz not null default now()
);
alter table qbtime_jobcode_map enable row level security;
drop policy if exists qbtime_jobcode_map_auth_all on qbtime_jobcode_map;
create policy qbtime_jobcode_map_auth_all on qbtime_jobcode_map
  for all to authenticated using (true) with check (true);
grant select, insert, update, delete on qbtime_jobcode_map to authenticated;
grant all on qbtime_jobcode_map to service_role;

comment on table qbtime_jobcode_map is
  'Human-owned: where the hours logged under one QuickBooks Time jobcode belong. Read first by sync-qbtime.mjs on every run (a decision here beats the name parse), never written by it. resolution deal needs deal_id (null after a deal deletion = fall back to the parse); timeoff moves the hours into time_off with timeoff_kind; exclude keeps them with attribution excluded; internal is plain non-billable time.';

-- ---------------------------------------------------------------------------
-- unmapped_hours: what needs a human, in the range, grouped for the panel.
-- ---------------------------------------------------------------------------
create or replace function unmapped_hours(p_from date, p_to date)
returns jsonb as $$
with te as (
  select t.*, s.name as staff_name
  from time_entries t
  left join staff s on s.id = t.staff_id
  where t.worked_on between p_from and p_to
    and t.attribution in ('uncoded','unmatched','unresolved','excluded','unknown_user')
),
grp as (
  select
    coalesce(te.qbtime_jobcode_id, -1)       as qbtime_jobcode_id,
    coalesce(te.jobcode_name, '(no jobcode)') as jobcode_name,
    te.attribution,
    -- excluded rows are grouped per PERSON as well: the fix for an excluded
    -- person is on staff, not on the jobcode
    case when te.attribution = 'excluded' then te.staff_id end as excluded_staff_id,
    sum(te.hours)::numeric  as hours,
    count(*)::int           as rows_n,
    min(te.worked_on)       as first_on,
    max(te.worked_on)       as last_on
  from te
  group by 1, 2, 3, 4
),
people as (
  select coalesce(qbtime_jobcode_id, -1) as qbtime_jobcode_id, attribution,
         case when attribution = 'excluded' then staff_id end as excluded_staff_id,
         jsonb_agg(jsonb_build_object('name', coalesce(staff_name, '(unknown user)'), 'hours', h)
                   order by h desc) as people
  from (select qbtime_jobcode_id, attribution, staff_id, staff_name, sum(hours) as h
        from te group by 1, 2, 3, 4) p
  group by 1, 2, 3
),
months as (
  select coalesce(qbtime_jobcode_id, -1) as qbtime_jobcode_id, attribution,
         case when attribution = 'excluded' then staff_id end as excluded_staff_id,
         jsonb_agg(jsonb_build_object('month', m, 'hours', h) order by m) as months
  from (select qbtime_jobcode_id, attribution, staff_id,
               date_trunc('month', worked_on)::date as m, sum(hours) as h
        from te group by 1, 2, 3, 4) q
  group by 1, 2, 3
)
select jsonb_build_object(
  'total_hours', coalesce((select sum(hours) from grp), 0),
  'groups', coalesce((select jsonb_agg(jsonb_build_object(
      'qbtime_jobcode_id', g.qbtime_jobcode_id,
      'jobcode_name',      g.jobcode_name,
      'attribution',       g.attribution,
      'excluded_staff_id', g.excluded_staff_id,
      'hours',             g.hours,
      'rows_n',            g.rows_n,
      'first_on',          g.first_on,
      'last_on',           g.last_on,
      'people',            coalesce(p.people, '[]'::jsonb),
      'months',            coalesce(m.months, '[]'::jsonb),
      'mapping',           (select to_jsonb(mp) from qbtime_jobcode_map mp
                             where mp.qbtime_jobcode_id = g.qbtime_jobcode_id))
      order by g.hours desc, g.jobcode_name)
    from grp g
    left join people p on p.qbtime_jobcode_id = g.qbtime_jobcode_id and p.attribution = g.attribution
                      and p.excluded_staff_id is not distinct from g.excluded_staff_id
    left join months m on m.qbtime_jobcode_id = g.qbtime_jobcode_id and m.attribution = g.attribution
                      and m.excluded_staff_id is not distinct from g.excluded_staff_id), '[]'::jsonb)
);
$$ language sql stable;

comment on function unmapped_hours is
  'Project Hours'' "Unmapped hours" panel: every (QuickBooks Time jobcode, attribution) group in the range that needs a human — uncoded, unmatched, unresolved, unknown_user, and excluded (grouped per person too, since that fix is staff.exclude_hours) — with hours, people, months and any existing qbtime_jobcode_map row. Rows resolved as internal/deal/mapped/timeoff are not here: they are handled.';

-- ---------------------------------------------------------------------------
-- hours_page: 064 verbatim, except te leaves out excluded / timeoff rows.
-- ---------------------------------------------------------------------------
create or replace function hours_page(p_from date, p_to date)
returns jsonb as $$
with te as (
  -- 090: excluded people / excluded jobcodes and time-off-pending rows are
  -- kept in the table (zero data loss) but never priced or counted here.
  select * from time_entries
  where worked_on between p_from and p_to
    and coalesce(attribution, '') not in ('excluded', 'timeoff')
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
