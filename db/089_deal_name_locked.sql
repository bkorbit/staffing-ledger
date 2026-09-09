-- ============================================================================
--  089 — a deal renamed on the platform keeps its name.
--
--  Bug: the Forecast editor writes deals.name, and every HubSpot sync run
--  (sync-hubspot.mjs "refresh name/jobcode on already-promoted deals")
--  copied pipeline_deals.name back over it two hours later. The comment there
--  said "name unconditionally (a pure display label — nothing reads it
--  expecting staleness)". Wrong on the human side: a rename in the editor IS
--  a decision, and it silently reverted on the next sync.
--
--  Fix, same shape as flight_locked (028): deals.name_locked. Once true the
--  platform, not HubSpot, owns the name. Two owners are told apart by the
--  stamp the update carries: every sync path writes set_by 'hubspot-…'
--  (hubspot-sync:refresh, hubspot-backfill-028) AND a fresh set_at in the
--  same statement. A human in the editor stamps their email; a human in the
--  SQL editor typically stamps nothing — and since the LAST writer to a row
--  is usually the sync, "set_by looks like hubspot" alone would misread that
--  SQL rename as sync-sourced. Requiring set_at to move as well tells them
--  apart. freeze-on-close and the matcher never touch name.
--
--  The lock is enforced HERE, in a trigger, not only in the sync script:
--    - any rename whose set_by is not 'hubspot-…' locks the row (so a rename
--      by SQL, by an older cached page, or by a future page is covered, not
--      just the editor that also sets name_locked = true explicitly);
--    - a 'hubspot-…' rename of a locked row keeps the old name and lets the
--      rest of the patch (jobcode, set_at) through.
--  That makes the deploy order safe: run this first and the currently
--  deployed sync can no longer revert a rename even before its own change
--  (skip locked rows) ships.
--
--  Backfill: after every sync, deals.name == pipeline_deals.name for every
--  promoted deal whose mirror row still carries a name. Any divergence at the
--  moment this runs is therefore a human rename since the last sync — lock it
--  now rather than lose it in two hours.
--
--  To hand a name back to HubSpot: update deals set name_locked = false
--  where id = '…'; — the next sync refreshes it.
-- ============================================================================

alter table deals
  add column if not exists name_locked boolean not null default false;

comment on column deals.name_locked is
  'true once a human has renamed the deal on the platform (Forecast editor or '
  'SQL). While true, sync-hubspot.mjs must not refresh deals.name from '
  'pipeline_deals, and the deals_name_lock trigger discards any hubspot-… '
  'rename anyway. Set false by hand to let HubSpot own the name again.';

create or replace function deals_name_lock()
returns trigger
language plpgsql
as $$
begin
  if new.name is distinct from old.name then
    if coalesce(new.set_by, '') like 'hubspot-%'
       and new.set_at is distinct from old.set_at then
      -- sync-sourced rename: never over a human's
      if old.name_locked then
        new.name := old.name;
      end if;
    else
      new.name_locked := true;
    end if;
  end if;
  return new;
end;
$$;

comment on function deals_name_lock() is
  'Row trigger on deals (before update of name). A rename that does not carry '
  'a fresh hubspot-… stamp (set_by like hubspot-% AND set_at changed) is a '
  'human''s and locks the name; a hubspot-… rename of a locked row is dropped, '
  'keeping the rest of the update.';

drop trigger if exists deals_name_lock on deals;
create trigger deals_name_lock
  before update of name on deals
  for each row
  execute function deals_name_lock();

-- lock every rename that has happened since the last sync run
update deals d
set name_locked = true
from pipeline_deals pd
where d.hubspot_deal_id = pd.hubspot_deal_id
  and d.name_locked = false
  and nullif(pd.name, '') is not null
  and d.name <> pd.name;
