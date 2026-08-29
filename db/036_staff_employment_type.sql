-- ============================================================================
--  036 — staff.employment_type: full_time / contractor / part_time.
--
--  Every comp_periods row already defaults weekly_capacity to 40 (001_init),
--  which was fine as long as everyone WAS full time — but there was no field
--  saying so, and no way for Team's edit modal to know a contractor or
--  part-timer's hours/week should be editable while a full-timer's stays
--  locked at 40. This column is that switch, not a new capacity source of
--  truth: weekly_capacity still lives on comp_periods (a person's capacity
--  can change over time, same as their pay), this just tells the UI whether
--  that field is worth showing.
--
--  Backfilled to 'full_time' for every existing row by the column default —
--  matches reality (EMG's roster was entered as full time by default before
--  this field existed) and Boris's instruction that nobody should need to be
--  touched for this to ship; contractors/part-timers get flipped by hand on
--  Team as they're noticed.
-- ============================================================================

alter table staff add column if not exists employment_type text not null default 'full_time'
  check (employment_type in ('full_time', 'contractor', 'part_time'));

comment on column staff.employment_type is
  'full_time | contractor | part_time, set on Team''s edit modal. full_time '
  'means weekly_capacity is always treated as 40 regardless of what''s '
  'stored on any comp_periods row (the app forces 40 on save); contractor '
  'and part_time expose weekly_capacity as a real per-period editable '
  'value. Defaults every row to full_time.';
