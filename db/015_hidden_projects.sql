-- ============================================================================
--  015 — hiding redundant projects, permanently.
--
--  Human-owned columns on qbo_projects, same contract as is_operating and
--  override_class: the sync NEVER writes them, and upserts only update the
--  columns in their payload, so a hidden project stays hidden through every
--  nightly sync.
--
--  Scope, deliberately: hidden removes a project from every list and picker in
--  the app. It does NOT remove its money — invoices and cost lines on a hidden
--  project still roll up to the client through the parent, because decluttering
--  must never make revenue disappear.
--
--  To unhide:  update qbo_projects set hidden = false where id = '…';
--  To review:  select id, name, hidden_by, hidden_at from qbo_projects where hidden;
-- ============================================================================

alter table qbo_projects add column if not exists hidden    boolean not null default false;
alter table qbo_projects add column if not exists hidden_by text;
alter table qbo_projects add column if not exists hidden_at timestamptz;

comment on column qbo_projects.hidden is
  'Human-owned; sync never writes it. Hidden projects leave the UI lists and '
  'pickers but their financials still roll up through the parent.';
