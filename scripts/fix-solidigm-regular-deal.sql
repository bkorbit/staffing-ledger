-- One-off data fix, not a migration. Run once in the Supabase SQL editor.
--
-- Solidigm exception (Boris, 10 Sep 2026): QB project 426
-- "24forc3009250 - Force Multiplier Strategy - Solidigm" belongs to the
-- REGULAR deal, "FMS - Solidigm - Programmatic - 8/27/25 - 9/30/25" — hours
-- AND invoices. "FMS - Solidigm - Programmatic - Incremental" claims nothing.
--
-- Before this: both deals claimed 426. The QB Time sync already stamps every
-- Solidigm hour (1,186h since 1 Apr 2026) on the regular deal, but that deal
-- was hidden with a placeholder flight (2025-12-31 → 2025-12-31), so neither
-- tab showed it, while Incremental showed the $70k August revenue with no
-- hours. After this: the regular deal is visible, its flight covers the work,
-- and it is the ONLY claimant, so Project Hours and Client Profitability show
-- revenue and hours together on one row. Incremental keeps its plan lines and
-- stays visible; with no claim and a flight that ended 30 Aug it drops off
-- any measured-only range on its own.
--
-- Nothing undoes this overnight: sync-hubspot never writes flight/hidden/
-- qbo_project_id, match_deals_to_projects() only fills projects NO deal
-- claims (426 stays claimed), and flight_locked stops the flight backfill.
-- Both updates are guarded by name AND project; the final select is the
-- verification — expect updated_incremental = 1 and updated_regular = 1.

update deals
   set qbo_project_id = null,
       set_by = 'boris 2026-09-10: Solidigm exception — regular deal owns QB project 426'
 where name = 'FMS - Solidigm - Programmatic - Incremental'
   and qbo_project_id = '426';

update deals
   set hidden = false, hidden_by = null, hidden_at = null,
       flight_start = '2025-08-27', flight_end = '2026-12-31', flight_locked = true,
       set_by = 'boris 2026-09-10: Solidigm exception — regular deal owns QB project 426'
 where name = 'FMS - Solidigm - Programmatic - 8/27/25 - 9/30/25'
   and qbo_project_id = '426';

with rp as (
  select (r->>'qbo_project_id') as pid, (r->>'total')::bigint as cents
  from jsonb_array_elements(rev_proj_page('2026-08-01', '2026-08-01')) r   -- a bare array, 080
)
select d.name,
       d.status::text as status, d.hidden, d.qbo_project_id,
       d.flight_start, d.flight_end, d.flight_locked,
       (select sum(hours) from time_entries t where t.deal_id = d.id) as hours_all,
       (select sum(hours) from time_entries t where t.deal_id = d.id
          and t.worked_on >= '2026-08-01' and t.worked_on < '2026-09-01') as hours_aug,
       case when d.qbo_project_id = '426'
            then round((select cents from rp where pid = '426') / 100.0, 2) end as aug_revenue,
       (select count(*) from deals where name = 'FMS - Solidigm - Programmatic - Incremental' and qbo_project_id is null) as updated_incremental,
       (select count(*) from deals where name = 'FMS - Solidigm - Programmatic - 8/27/25 - 9/30/25' and not hidden and flight_end = '2026-12-31') as updated_regular
from deals d
where d.name in ('FMS - Solidigm - Programmatic - Incremental', 'FMS - Solidigm - Programmatic - 8/27/25 - 9/30/25')
order by d.name;
