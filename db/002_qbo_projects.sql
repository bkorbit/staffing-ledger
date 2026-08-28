-- ============================================================================
--  002 — the QuickBooks customer catalogue
--
--  Invoices and bills carry a qbo_project_id and nothing else, which makes them
--  unmatchable by a human: nobody can map an id to a client without a name. This
--  is the lookup that makes qbo_project_links fillable, and it is what lets any
--  report say "Visit Akron" instead of "4102".
--
--  SYNC-OWNED. Written only by sync-qbo.mjs.
-- ============================================================================

create table qbo_projects (
  id           text primary key,          -- QBO Customer id
  name         text not null,
  fully_qualified_name text,              -- 'Parent:Child' as QuickBooks shows it
  parent_id    text,
  parent_name  text,
  is_project   boolean not null default false,   -- a sub-customer (QuickBooks "Project")
  jobcode      text,                      -- extracted from the name; the HubSpot join key
  active       boolean not null default true,
  first_txn_on date,
  last_txn_on  date,
  synced_at    timestamptz not null default now()
);
create index qbo_projects_parent_idx  on qbo_projects (parent_id);
create index qbo_projects_jobcode_idx on qbo_projects (jobcode);

alter table qbo_projects enable row level security;
create policy qbo_projects_auth_all on qbo_projects
  for all to authenticated using (true) with check (true);

-- Denormalised so an invoice is readable, and matchable, on its own. The id alone
-- forces a join through a table that may not be populated yet.
alter table invoices add column if not exists qbo_customer_name text;
alter table bills    add column if not exists qbo_customer_name text;
