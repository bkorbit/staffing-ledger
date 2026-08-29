-- ============================================================================
--  030 — a human can set the QuickBooks Time import cutoff from Settings
--
--  sync_state has carried refresh_token/realm_id since 001_init.sql, so it was
--  deliberately left with NO RLS policy at all ("service role only") — unlike
--  every other table on this platform, which already runs permissive
--  `for all to authenticated using (true)` policies. That's also been quietly
--  breaking the Settings page's "Syncs" panel (it selects from sync_state and
--  gets nothing back) and left import_from editable only via SQL.
--
--  Column-level grants, not a blanket policy, keep the secrets out of reach:
--  authenticated can read the status columns and import_from, and can write
--  ONLY import_from (+ its own set_by/set_at audit columns) — never
--  refresh_token or realm_id, no matter what a client asks to select or patch.
--
--  REVOKE ALL first, deliberately: no other table in this schema has ever
--  needed a column-level grant (every other RLS policy is a blanket `for all
--  using (true)`), which means Supabase's own default table-level grant to
--  authenticated/anon has never been tested here. A narrower GRANT on top of
--  an untested, possibly-still-broader default grant proves nothing — REVOKE
--  ALL clears whatever that default is before the narrow GRANT adds back
--  exactly the columns above and nothing else.
-- ============================================================================

alter table sync_state add column if not exists import_from_set_by text;
alter table sync_state add column if not exists import_from_set_at timestamptz;

revoke all on sync_state from authenticated, anon;

grant select (id, import_from, last_run_at, last_run_log, import_from_set_by, import_from_set_at)
  on sync_state to authenticated;
grant update (import_from, import_from_set_by, import_from_set_at)
  on sync_state to authenticated;

create policy sync_state_select_status on sync_state
  for select to authenticated using (true);

create policy sync_state_update_import_from on sync_state
  for update to authenticated using (true) with check (true);
