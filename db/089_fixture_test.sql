-- Fixture test for 089 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-089 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the NINE rows of the single result set at the bottom
--   3. it ends in ROLLBACK — every fixture row is undone. Do not commit it.
--
-- What is being proved (the trigger deals_name_lock and the 089 backfill):
--   1. EDITOR RENAME locks — a rename stamped with a human email flips
--      name_locked even when the statement does not set name_locked itself.
--   2. SYNC vs LOCKED — a hubspot-sync:refresh rename of a locked deal keeps
--      the human's name, but its jobcode fill-in still lands.
--   3. SECOND SYNC — the row's set_by is ALREADY 'hubspot-sync:refresh' from
--      the previous run (only set_at moves); still recognised as the sync,
--      still dropped. A "set_by changed" discriminator would fail here.
--   4. SYNC vs UNLOCKED — the sync still refreshes a never-renamed deal, and
--      that refresh does not lock it.
--   5. SQL RENAME, NO STAMP — a bare `update deals set name = …` on a row the
--      sync last wrote (set_by still hubspot-sync:refresh) is a human's: the
--      rename lands and locks. Then a sync attempt on it is dropped.
--   6. SYNC WITHOUT RENAME — a hubspot-stamped jobcode-only update never locks.
--   7. BACKFILL locks a promoted deal whose name differs from its mirror,
--   8. BACKFILL leaves alone a deal that matches its mirror, and
--   9. BACKFILL leaves alone a deal whose mirror row has an empty name.
--
-- Adversarial on purpose: the sync stamp already sitting on the row, a rename
-- without any stamp, a sync update that carries no rename, an empty mirror
-- name. A one-row "rename then sync" fixture passes while getting these wrong.

begin;

insert into clients (id, name, active)
values ('f0f0f0f0-0000-0000-0000-000000000089', '_fx089 Name Lock Client', true);

insert into pipeline_deals (hubspot_deal_id, name) values
  ('fx089-a', 'HS Name A'),
  ('fx089-b', 'HS Name B v2'),
  ('fx089-c', 'HS Name C'),
  ('fx089-d', 'HS Name D'),
  ('fx089-f', '');

insert into deals (id, client_id, name, hubspot_deal_id, set_by, set_at) values
  ('f0f0f0f0-0000-0000-0000-00000000089a', 'f0f0f0f0-0000-0000-0000-000000000089', 'HS Name A',    'fx089-a', 'hubspot-sync:refresh', now() - interval '2 hour'),
  ('f0f0f0f0-0000-0000-0000-00000000089b', 'f0f0f0f0-0000-0000-0000-000000000089', 'HS Name B',    'fx089-b', 'hubspot-sync:refresh', now() - interval '2 hour'),
  ('f0f0f0f0-0000-0000-0000-00000000089c', 'f0f0f0f0-0000-0000-0000-000000000089', 'HS Name C',    'fx089-c', 'hubspot-sync:refresh', now() - interval '2 hour'),
  ('f0f0f0f0-0000-0000-0000-00000000089d', 'f0f0f0f0-0000-0000-0000-000000000089', 'Human D name', 'fx089-d', 'someone@elitemedia.group', now() - interval '1 hour'),
  ('f0f0f0f0-0000-0000-0000-00000000089f', 'f0f0f0f0-0000-0000-0000-000000000089', 'Deal F',       'fx089-f', 'hubspot-sync:refresh', now() - interval '2 hour');

-- 1. the Forecast editor renames A (email stamp, fresh set_at, NO explicit lock)
update deals set name = 'Editor A', set_by = 'boris@elitemedia.group', set_at = now()
where id = 'f0f0f0f0-0000-0000-0000-00000000089a';
create temp table _fx1 as
select name, name_locked from deals where id = 'f0f0f0f0-0000-0000-0000-00000000089a';

-- 2. the sync refreshes A from the mirror, with a jobcode fill-in
update deals set name = 'HS Name A', jobcode = '26abc12345', set_by = 'hubspot-sync:refresh', set_at = now() + interval '1 second'
where id = 'f0f0f0f0-0000-0000-0000-00000000089a';
create temp table _fx2 as
select name, name_locked, jobcode from deals where id = 'f0f0f0f0-0000-0000-0000-00000000089a';

-- 3. the NEXT sync: set_by is already the sync stamp, only set_at moves
update deals set name = 'HS Name A renamed', set_by = 'hubspot-sync:refresh', set_at = now() + interval '2 second'
where id = 'f0f0f0f0-0000-0000-0000-00000000089a';
create temp table _fx3 as
select name, name_locked from deals where id = 'f0f0f0f0-0000-0000-0000-00000000089a';

-- 4. the sync refreshes never-renamed B
update deals set name = 'HS Name B v2', set_by = 'hubspot-sync:refresh', set_at = now()
where id = 'f0f0f0f0-0000-0000-0000-00000000089b';
create temp table _fx4 as
select name, name_locked from deals where id = 'f0f0f0f0-0000-0000-0000-00000000089b';

-- 5. a bare SQL rename of C (no stamp at all), then a sync attempt on it
update deals set name = 'SQL C' where id = 'f0f0f0f0-0000-0000-0000-00000000089c';
create temp table _fx5a as
select name, name_locked from deals where id = 'f0f0f0f0-0000-0000-0000-00000000089c';
update deals set name = 'HS Name C', set_by = 'hubspot-sync:refresh', set_at = now()
where id = 'f0f0f0f0-0000-0000-0000-00000000089c';
create temp table _fx5b as
select name, name_locked from deals where id = 'f0f0f0f0-0000-0000-0000-00000000089c';

-- 6. a sync jobcode-only update on B (unlocked) — no rename, must not lock
update deals set jobcode = '26xyz54321', set_by = 'hubspot-sync:refresh', set_at = now() + interval '1 second'
where id = 'f0f0f0f0-0000-0000-0000-00000000089b';
create temp table _fx6 as
select name, name_locked, jobcode from deals where id = 'f0f0f0f0-0000-0000-0000-00000000089b';

-- 7-9. the 089 backfill, verbatim, run again over the fixture rows
update deals d
set name_locked = true
from pipeline_deals pd
where d.hubspot_deal_id = pd.hubspot_deal_id
  and d.name_locked = false
  and nullif(pd.name, '') is not null
  and d.name <> pd.name;
create temp table _fx7 as
select id, name, name_locked from deals where id in
  ('f0f0f0f0-0000-0000-0000-00000000089b',
   'f0f0f0f0-0000-0000-0000-00000000089d',
   'f0f0f0f0-0000-0000-0000-00000000089f');

with r(n, result) as (
  select 1, case when (select name = 'Editor A' and name_locked from _fx1)
    then '1. EDITOR RENAME LANDS AND LOCKS: PASS'
    else '1. EDITOR RENAME: FAIL — ' || (select format('name=%s locked=%s', name, name_locked) from _fx1) end
  union all
  select 2, case when (select name = 'Editor A' and name_locked and jobcode = '26abc12345' from _fx2)
    then '2. SYNC RENAME OF LOCKED DEAL DROPPED, JOBCODE STILL LANDS: PASS'
    else '2. SYNC vs LOCKED: FAIL — ' || (select format('name=%s locked=%s jobcode=%s', name, name_locked, jobcode) from _fx2) end
  union all
  select 3, case when (select name = 'Editor A' and name_locked from _fx3)
    then '3. SECOND SYNC (set_by unchanged, set_at moved) STILL DROPPED: PASS'
    else '3. SECOND SYNC: FAIL — ' || (select format('name=%s locked=%s', name, name_locked) from _fx3) end
  union all
  select 4, case when (select name = 'HS Name B v2' and not name_locked from _fx4)
    then '4. SYNC REFRESHES UNLOCKED DEAL WITHOUT LOCKING IT: PASS'
    else '4. SYNC vs UNLOCKED: FAIL — ' || (select format('name=%s locked=%s', name, name_locked) from _fx4) end
  union all
  select 5, case when (select name = 'SQL C' and name_locked from _fx5a)
                 and (select name = 'SQL C' and name_locked from _fx5b)
    then '5. BARE SQL RENAME ON SYNC-STAMPED ROW LANDS, LOCKS, SURVIVES SYNC: PASS'
    else '5. SQL RENAME: FAIL — after rename ' || (select format('name=%s locked=%s', name, name_locked) from _fx5a)
         || ' · after sync ' || (select format('name=%s locked=%s', name, name_locked) from _fx5b) end
  union all
  select 6, case when (select name = 'HS Name B v2' and not name_locked and jobcode = '26xyz54321' from _fx6)
    then '6. SYNC JOBCODE-ONLY UPDATE DOES NOT LOCK: PASS'
    else '6. SYNC NO-RENAME: FAIL — ' || (select format('name=%s locked=%s jobcode=%s', name, name_locked, jobcode) from _fx6) end
  union all
  select 7, case when (select name_locked from _fx7 where id = 'f0f0f0f0-0000-0000-0000-00000000089d')
    then '7. BACKFILL LOCKS A DEAL WHOSE NAME DIFFERS FROM ITS MIRROR: PASS'
    else '7. BACKFILL DIFFERS: FAIL' end
  union all
  select 8, case when not (select name_locked from _fx7 where id = 'f0f0f0f0-0000-0000-0000-00000000089b')
    then '8. BACKFILL LEAVES A DEAL THAT MATCHES ITS MIRROR UNLOCKED: PASS'
    else '8. BACKFILL MATCHES: FAIL' end
  union all
  select 9, case when not (select name_locked from _fx7 where id = 'f0f0f0f0-0000-0000-0000-00000000089f')
    then '9. BACKFILL IGNORES AN EMPTY MIRROR NAME: PASS'
    else '9. BACKFILL EMPTY MIRROR: FAIL' end
)
select result from r order by n;
rollback;
