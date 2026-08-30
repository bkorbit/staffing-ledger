-- ============================================================================
--  059 — schema-level guarantees for deal matching: no more silent regressions.
--
--  Two independent statements. Run the first immediately. Run the SELECT
--  before the second and read its output — only run the second if it comes
--  back empty. Same precedent as 054: an irreversible schema change gets a
--  mandatory human-reviewed step first, not an automatic assumption.
-- ============================================================================

-- 1. 'closed'/'lost' are retired (054). Nothing should ever write them again —
--    make it impossible, not just conventional. 054 already normalized every
--    existing row, so this is safe to run immediately.
alter table deals add constraint deals_status_no_closed_lost
  check (status not in ('closed', 'lost'));

-- 2a. Preview: does any qbo_project_id currently belong to more than one deal?
--     Nothing at the schema level has ever stopped this — match_deals_to_projects()
--     (010/037) only guards its OWN writes; a manual picker edit goes straight
--     through with no check. Run this first.
select qbo_project_id, array_agg(id) as deal_ids, array_agg(name) as deal_names
from deals
where qbo_project_id is not null
group by qbo_project_id
having count(*) > 1;

-- 2b. Only run this if the select above returned zero rows. If it returned
--     rows, resolve which deal actually keeps each contested project first
--     (a judgment call, not something to automate) — then re-run the select
--     to confirm it's empty, then run this:
-- create unique index deals_qbo_project_unique on deals (qbo_project_id)
--   where qbo_project_id is not null;
