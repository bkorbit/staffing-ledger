-- ============================================================================
--  044 — 401k grandfather clause: anyone hired on or before a cutoff date
--  skips the 6-month wait entirely and is eligible from their own hire date.
--
--  Boris: everyone with a start_date on/before 2026-01-01 was grandfathered
--  into the 401k when the plan (or its current match terms) started — the
--  041 waiting-period formula only ever applied to people hired AFTER that
--  point. The cutoff lives in settings (k401_grandfather_cutoff) rather than
--  hardcoded, so it's correctable without another migration if the date
--  turns out wrong.
--
--  staff_401k_eligibility_date moves from immutable to stable — it now
--  reads a settings value, so its result can change if that value is
--  edited later even for the same hire date input; immutable would have
--  told Postgres "this result never changes for a given input," which
--  stopped being true the moment a table read entered the function body.
-- ============================================================================

insert into settings (key, value, set_by) values
  ('k401_grandfather_cutoff', '"2026-01-01"', 'migration-044')
on conflict (key) do nothing;

create or replace function staff_401k_eligibility_date(p_hire_date date)
returns date as $$
  select case
    when p_hire_date is null then null
    when p_hire_date <= coalesce(
      (select (value #>> '{}')::date from settings where key = 'k401_grandfather_cutoff'),
      '2026-01-01'::date
    ) then p_hire_date
    when extract(day from p_hire_date) = 1
      then (date_trunc('month', p_hire_date) + interval '6 months')::date
    else (date_trunc('month', p_hire_date) + interval '7 months')::date
  end
$$ language sql stable;

comment on function staff_401k_eligibility_date is
  'Standard 401k entry-date formula for anyone hired AFTER '
  'settings.k401_grandfather_cutoff (044): 6 months of service, entry on '
  'the 1st of the month coinciding with or following. Jan 15 hire -> Jul 15 '
  'is the 6-month mark, not itself a 1st -> Aug 1. Jan 1 hire -> Jul 1 '
  'already is a 1st -> Jul 1 exactly. Anyone hired ON OR BEFORE the cutoff '
  'is grandfathered — eligible immediately, from their own hire date, no '
  'wait at all.';
