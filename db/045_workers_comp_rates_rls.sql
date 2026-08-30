-- ============================================================================
--  045 — workers_comp_rates was missing RLS entirely.
--
--  Every table on this platform gets `enable row level security` + a
--  permissive `for all to authenticated` policy right after its own CREATE
--  TABLE (001_init.sql's own DO block for the original tables; 002/005 etc.
--  for everything since) — the one thing 042 forgot when it created
--  workers_comp_rates. With no policy at all, PostgREST returns zero rows to
--  the app regardless of what's actually in the table: the 043 seed and any
--  since-added rate were always there, just invisible to the anon/
--  authenticated client the app runs as. Same shape as 030's sync_state fix,
--  minus the column-level narrowing — this table holds no secrets, so the
--  same blanket policy every other table already uses is enough.
-- ============================================================================

alter table workers_comp_rates enable row level security;

create policy workers_comp_rates_auth_all on workers_comp_rates
  for all to authenticated using (true) with check (true);
