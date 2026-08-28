-- ============================================================================
--  010 — deals meet their QuickBooks projects
--
--  The join that makes revenue matching real: once a deal knows its QBO project,
--  its invoices are ITS actuals — deal-level past months in the Forecast, and the
--  ability to tell "this deal-month was already invoiced" in the cashflow.
--
--  The ladder, in confidence order, recovered from the old matcher:
--    1. the QB link pasted on the HubSpot deal — parses to an exact project id
--    2. jobcode equality — unambiguous on both sides only
--  Ambiguity never guesses: a jobcode two deals share, or a project already taken,
--  stays unmatched and is reported, because a wrong match silently corrupts the
--  forecast while a missing one is merely visible work.
-- ============================================================================

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

  -- Rung 2: jobcode equality, unambiguous both sides, target free.
  return query
  with jc as (
    update deals d
    set qbo_project_id = sub.qid, set_by = 'matcher:jobcode', set_at = now()
    from (
      select d2.id, min(q.id) as qid
      from deals d2
      join qbo_projects q on lower(q.jobcode) = lower(d2.jobcode)
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
  'jobcode equality. Never guesses on ambiguity. Idempotent — safe after every sync, '
  'and the HubSpot sync calls it. Returns counts per method plus the remaining '
  'unmatched live deals.';
