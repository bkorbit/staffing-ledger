-- ============================================================================
--  112 — Benchmarks: more platforms, and the hours the exports are matched to.
--
--  Boris, 14 Sep 2026: "the whole idea of the tool is to match the logged hours
--  to the campaign data from the platform, not really add stuff in manually."
--  And the roster of platforms is longer than three: Viant for programmatic,
--  Reddit and LinkedIn for paid media, Adswerve (Campaign Manager 360
--  trafficking) for AdOps.
--
--    benchmark_uploads.platform   the hard list of six became a shape check
--      (^[a-z0-9_]{2,40}$): the platform registry lives in
--      app/assets/parsers/index.js and Settings › Scoping, and a new platform
--      must not need a migration (SaaS).
--    scope_platform_team_defaults gains viant → Programmatic, reddit → Paid
--      Media, linkedin → Paid Media, cm360 → AdOps; existing keys keep the
--      value the customer set.
--    scope_driver_order            gains `placements` (CM360 trafficking: a
--      placement is the unit of AdOps work).
--    benchmark_deal_hours(deal)    the counted hours per department per month
--      of ONE deal, running month flagged — the table the bench view shows
--      under the uploads so the reader sees what the platform data is being
--      matched to. The same rule as v_benchmark_observed (090/091: excluded
--      and time-off rows never count; department = staff.department, else the
--      entry's own, else "(no department)"), and 112_fixture_test asserts the
--      two agree to the minute for an enrolled deal-month.
--
--  Fixture: db/112_fixture_test.sql.
-- ============================================================================

alter table benchmark_uploads drop constraint if exists benchmark_uploads_platform_check;
alter table benchmark_uploads add constraint benchmark_uploads_platform_check check (platform ~ '^[a-z0-9_]{2,40}$');

comment on column benchmark_uploads.platform is
  'Registry key of the platform the export came from (app/assets/parsers/index.js PLATFORMS): google_ads, meta, reddit, linkedin, dsp, viant, cm360, … — any snake_case key; the list is not enforced here (112) so a new platform needs no migration.';

insert into settings (key, value, set_by) values
  ('scope_platform_team_defaults', '{}'::jsonb, 'migration-112')
on conflict (key) do nothing;
-- the customer's existing choices win; only missing keys are added
update settings
set value = '{"viant":"Programmatic","reddit":"Paid Media","linkedin":"Paid Media","cm360":"AdOps"}'::jsonb || value
where key = 'scope_platform_team_defaults';

update settings
set value = value || '["placements"]'::jsonb
where key = 'scope_driver_order' and jsonb_typeof(value) = 'array' and not (value ? 'placements');

create or replace function benchmark_deal_hours(p_deal_id uuid)
returns jsonb
language sql
stable
as $$
select coalesce((select jsonb_agg(jsonb_build_object(
    'department', x.department, 'month', x.month, 'hours', x.hours, 'people', x.people,
    'closed', x.month < date_trunc('month', current_date)::date)
    order by x.department, x.month)
  from (
    select coalesce(s.department, te.department, '(no department)') as department,
           date_trunc('month', te.worked_on)::date as month,
           sum(te.hours)::numeric as hours,
           count(distinct te.staff_id) as people
    from time_entries te
    left join staff s on s.id = te.staff_id
    where te.deal_id = p_deal_id
      and coalesce(te.attribution, '') not in ('excluded', 'timeoff')
    group by 1, 2) x), '[]'::jsonb);
$$;

comment on function benchmark_deal_hours(uuid) is
  'One deal''s counted hours per department per month (090/091 rule, the department rule of v_benchmark_observed), every month with hours, `closed` false for the running month. Hours and headcount only — never a cost. The bench view''s "hours logged on this campaign" table (112).';
