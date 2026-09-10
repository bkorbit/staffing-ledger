-- Diagnostic, not a migration. Read-only, safe to run any time.
--
-- Why does a deal show no hours on Project Hours / Client Profitability?
-- Written 10 Sep 2026 for "FMS - Solidigm - Programmatic - Incremental"; the
-- search string in `q` below is the only thing to change for another deal.
--
-- How hours reach a deal (scripts/sync-qbtime.mjs, db/090): a QuickBooks Time
-- jobcode name carries a project code ('24forc3009250'); the sync looks up the
-- QB project with that effective_jobcode, then THE won/active deal whose
-- qbo_project_id is that project, and stamps the entry with that deal_id.
-- hours_page sums time_entries by deal_id. So a deal comes up empty when:
--   A. it has no qbo_project_id (nothing routes to it),
--   B. its status is not won/active (the sync skips it),
--   C. ANOTHER deal claims the same QB project — the sync keeps one deal per
--      project (a Map keyed by qbo_project_id, last row wins), so every hour
--      for that jobcode lands on one deal and the other gets zero,
--   D. the time was logged under a jobcode whose name carries no/another code
--      ('unmatched'/'uncoded' — visible in Project Hours' Unmapped panel),
--   E. nobody logged time to it.
-- One result set, sections in order; the VERDICT rows at the end name which
-- of A–E applies per deal. hours_all is all time, hours_aug is August 2026.

with q as (select '%solidigm%' as needle, date '2026-08-01' as m),
d as (
  select d.id, d.name, d.status::text as status, d.hidden, d.qbo_project_id,
         d.flight_start, d.flight_end, c.name as client,
         p.name as project_name, p.effective_jobcode, p.hidden as project_hidden
  from deals d
  join clients c on c.id = d.client_id
  left join qbo_projects p on p.id = d.qbo_project_id
  where d.name ilike (select needle from q)
     or p.name ilike (select needle from q)
),
-- every deal on a QB project that a searched deal claims (searched ones included)
share as (
  select s.id, s.name, s.status::text as status, s.hidden, s.qbo_project_id,
         (s.id in (select id from d)) as searched
  from deals s
  where s.qbo_project_id in (select qbo_project_id from d where qbo_project_id is not null)
),
te as (
  select t.*, s.name as deal_name
  from time_entries t
  left join deals s on s.id = t.deal_id
  where t.deal_id in (select id from share)
     or t.jobcode_name ilike (select needle from q)
     or lower(t.jobcode_name) like '%' || lower((select min(effective_jobcode) from d)) || '%'
),
hrs as (
  select deal_id, sum(hours) as all_h,
         sum(hours) filter (where worked_on >= (select m from q) and worked_on < (select m from q) + interval '1 month') as aug_h
  from te where deal_id is not null group by deal_id
),
out_ as (
  -- 1. the deal(s) matching the search
  select 1 as sec, '1 deal' as section, name as item,
         'status=' || status || ' hidden=' || hidden || ' client=' || client
           || ' qbo_project=' || coalesce(project_name || ' [' || qbo_project_id || ', code ' || coalesce(effective_jobcode, '?') || ']', '(NONE)')
           || ' flight=' || coalesce(flight_start::text, '?') || '→' || coalesce(flight_end::text, '?') as detail,
         null::numeric as hours_all, null::numeric as hours_aug
  from d
  union all
  -- 2. deals sharing a QB project (the collision in C) — only when >1 on a project
  select 2, '2 deals on the same QB project', s.name,
         'qbo_project=' || s.qbo_project_id || ' status=' || s.status || ' hidden=' || s.hidden
           || case when s.searched then '' else ' (not in search)' end,
         h.all_h, h.aug_h
  from share s left join hrs h on h.deal_id = s.id
  where (select count(*) from share x where x.qbo_project_id = s.qbo_project_id) > 1
  union all
  -- 3. hours by deal / jobcode / attribution
  select 3, '3 time entries', coalesce(deal_name, '(no deal)') || ' ← ' || coalesce(jobcode_name, '(no jobcode name)'),
         'attribution=' || coalesce(attribution, 'null') || ' qbtime_jobcode_id=' || coalesce(qbtime_jobcode_id::text, '?')
           || ' first=' || min(worked_on) || ' last=' || max(worked_on) || ' people=' || count(distinct staff_id),
         sum(hours),
         sum(hours) filter (where worked_on >= (select m from q) and worked_on < (select m from q) + interval '1 month')
  from te
  group by deal_name, jobcode_name, attribution, qbtime_jobcode_id
  union all
  -- 4. human mappings for those jobcodes
  select 4, '4 qbtime_jobcode_map', coalesce(m.jobcode_name, m.qbtime_jobcode_id::text),
         'resolution=' || m.resolution || ' deal=' || coalesce((select name from deals where id = m.deal_id), '-') || ' set_by=' || coalesce(m.set_by, '?'),
         null, null
  from qbtime_jobcode_map m
  where m.qbtime_jobcode_id in (select qbtime_jobcode_id from te where qbtime_jobcode_id is not null)
     or m.deal_id in (select id from share)
  union all
  -- 5. verdicts, one per searched deal
  select 5, '5 VERDICT', d.name,
         case when d.qbo_project_id is null
                then 'A. no QB project claimed — pick one in the editor, then re-run the QB Time sync'
              when d.status not in ('won', 'active')
                then 'B. status ' || d.status || ' — the sync only routes hours to won/active deals'
              when exists (select 1 from share s where s.qbo_project_id = d.qbo_project_id and s.id <> d.id and s.status in ('won', 'active'))
                then 'C. shares QB project ' || d.qbo_project_id || ' with '
                     || (select string_agg(s.name || ' (' || coalesce(h.all_h, 0) || 'h)', ', ')
                         from share s left join hrs h on h.deal_id = s.id
                         where s.qbo_project_id = d.qbo_project_id and s.id <> d.id)
                     || case when coalesce(h.all_h, 0) > 0 then ' — THIS deal holds the jobcode''s hours' else ' — the sibling holds ALL of the jobcode''s hours, this deal gets none' end
                     || '. To split: give this deal''s work its own QB Time jobcode and map it to the deal (Project Hours › Unmapped, writes qbtime_jobcode_map), or its own QB project.'
              when exists (select 1 from te where te.deal_id is null)
                then 'D. hours exist under this code but are unmatched/uncoded — resolve them in Project Hours'' Unmapped panel'
              when coalesce(h.all_h, 0) = 0
                then 'E. no time entries carry this deal or its code — nothing was logged to it in QuickBooks Time'
              else 'hours ARE attributed to this deal — if the tab shows none, check the range and that the flight overlaps it' end,
         h.all_h, h.aug_h
  from d left join hrs h on h.deal_id = d.id
)
select section, item, detail, hours_all, hours_aug
from out_
order by sec, hours_all desc nulls last, item;
