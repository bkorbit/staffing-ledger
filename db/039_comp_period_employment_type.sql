-- ============================================================================
--  039 — employment_type moves from staff (one value, ever) to comp_periods
--  (one value per period).
--
--  036 put employment_type on staff, assuming it was fixed for a person's
--  whole tenure. It isn't — people switch between full_time/contractor/
--  part_time over time, and the app now needs to know which one applied to
--  a GIVEN period, same as pay and capacity already do. Team's edit modal
--  sets Type per comp-period row (and on "+ add period"), not once for the
--  whole person.
--
--  Backfill: every existing comp_periods row inherits its staff member's
--  current (single) employment_type value — the only guess available, since
--  there was no per-period record before this. Boris corrects any period
--  that was actually a different type by hand on Team, same as any other
--  comp-history fix.
--
--  staff.employment_type (036) is dropped once backfilled — comp_periods is
--  now the only source of truth, so a stale unused duplicate on staff can't
--  drift out of sync with it.
-- ============================================================================

alter table comp_periods add column if not exists employment_type text not null default 'full_time'
  check (employment_type in ('full_time', 'contractor', 'part_time'));

update comp_periods cp
set employment_type = s.employment_type
from staff s
where cp.staff_id = s.id;

comment on column comp_periods.employment_type is
  'full_time | contractor | part_time, set per comp period on Team''s edit '
  'modal — people switch between these over time, so it travels with the '
  'period, not the person. full_time means weekly_capacity on THIS row is '
  'always treated as 40 regardless of what''s stored (the app forces 40 on '
  'save); contractor and part_time expose weekly_capacity as a real '
  'editable value. Replaces staff.employment_type (036), which assumed one '
  'value for a person''s whole tenure.';

alter table staff drop column if exists employment_type;
