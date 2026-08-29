-- ============================================================================
--  037 — qbo_projects.jobcode gets a human override, and an effective column.
--
--  jobcode has always been sync-derived only: jobcodeFromName() parses it out of
--  the QuickBooks customer name, with no way for a human to correct a miss and no
--  visibility when it fails. That's an asymmetry with the deal side, which already
--  has a real source of truth — HubSpot's job_code custom field, preferred over
--  regex parsing whenever a human filled it in (sync-hubspot.mjs). This gives
--  qbo_projects the same shape as the two precedents already in this schema for
--  "sync guesses, human corrects, and the two never drift apart or silently
--  fight" — override_class (005_chart_of_accounts) and hidden (015_hidden_projects).
--
--  The regex itself was also hardened (client short codes can carry a digit, e.g.
--  'o2kl' in '24o2kl1107240') — but a hand override is what stops the NEXT naming
--  convention it doesn't anticipate from requiring another migration to fix: the
--  parser only ever needs to be good enough that overrides stay rare, not perfect.
--
--  effective_jobcode is a generated column, not a coalesce() repeated at every call
--  site — match_deals_to_projects() (010) and sync-qbtime.mjs's jobcode->project
--  lookup both read it directly, so there is exactly one place the precedence is
--  decided.
--
--  To set:    update qbo_projects set jobcode_override = '…', jobcode_override_by
--             = '…', jobcode_override_at = now() where id = '…';
--  To review: select id, name, jobcode, jobcode_override from qbo_projects
--             where is_project and effective_jobcode is null;
-- ============================================================================

alter table qbo_projects add column if not exists jobcode_override    text;
alter table qbo_projects add column if not exists jobcode_override_by text;
alter table qbo_projects add column if not exists jobcode_override_at timestamptz;

comment on column qbo_projects.jobcode_override is
  'Human-owned; sync never writes it. Set when jobcodeFromName() cannot parse (or '
  'mis-parses) a project''s real short code from its QuickBooks name — the '
  'override always wins over the derived jobcode, see effective_jobcode.';

alter table qbo_projects add column if not exists effective_jobcode text
  generated always as (coalesce(jobcode_override, jobcode)) stored;

create index if not exists qbo_projects_effective_jobcode_idx
  on qbo_projects (effective_jobcode);

-- Rung 2 (jobcode equality) now reads the effective value; everything else about
-- the ladder — the QB-link rung, ambiguity never guessing — is unchanged from 010.
create or replace function match_deals_to_projects()
returns table (method text, matched int) as $$
begin
  -- Deals promoted before the job_code field was pulled inherit it from the mirror.
  update deals d
  set jobcode = pd.jobcode, set_by = 'matcher', set_at = now()
  from pipeline_deals pd
  where pd.hubspot_deal_id = d.hubspot_deal_id
    and d.jobcode is null and pd.jobcode is not null;

  -- Rung 1: the QB link. An exact id, so the only check is that the project exists
  -- and is not already someone else's.
  return query
  with linked as (
    update deals d
    set qbo_project_id = sub.pid, set_by = 'matcher:qb-link', set_at = now()
    from (
      select d2.id, (regexp_match(pd.qbo_link, '[?&](?:id|nameId)=(\d+)'))[1] as pid
      from deals d2
      join pipeline_deals pd on pd.hubspot_deal_id = d2.hubspot_deal_id
      where d2.qbo_project_id is null
        and pd.qbo_link ~ '[?&](?:id|nameId)=\d+'
    ) sub
    where d.id = sub.id
      and exists (select 1 from qbo_projects q where q.id = sub.pid)
      and not exists (select 1 from deals d3 where d3.qbo_project_id = sub.pid)
    returning 1
  )
  select 'qb-link'::text, count(*)::int from linked;

  -- Rung 2: jobcode equality (override-aware), unambiguous both sides, target free.
  return query
  with jc as (
    update deals d
    set qbo_project_id = sub.qid, set_by = 'matcher:jobcode', set_at = now()
    from (
      select d2.id, min(q.id) as qid
      from deals d2
      join qbo_projects q on lower(q.effective_jobcode) = lower(d2.jobcode)
      where d2.qbo_project_id is null and d2.jobcode is not null
      group by d2.id
      having count(distinct q.id) = 1                          -- one project per code
         and 1 = (select count(*) from deals dd
                  where lower(dd.jobcode) = lower(d2.jobcode)) -- one deal per code
    ) sub
    where d.id = sub.id
      and not exists (select 1 from deals d3 where d3.qbo_project_id = sub.qid)
    returning 1
  )
  select 'jobcode'::text, count(*)::int from jc;

  return query
  select 'unmatched'::text, count(*)::int
  from deals
  where qbo_project_id is null and status in ('won','active');
end;
$$ language plpgsql;

comment on function match_deals_to_projects is
  'Links deals to QuickBooks projects: QB link first (exact id), then unambiguous '
  'jobcode equality against qbo_projects.effective_jobcode (jobcode_override where '
  'a human set one, else the sync-derived jobcode). Never guesses on ambiguity. '
  'Idempotent — safe after every sync, and the HubSpot sync calls it. Returns '
  'counts per method plus the remaining unmatched live deals.';
