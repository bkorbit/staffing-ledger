-- ============================================================================
--  060 — promotion_approvals: the record of a human's decision to promote.
--
--  Promotion used to be a fully-automatic nightly insert (sync-hubspot.mjs):
--  a HubSpot deal going Closed Won silently became a live `deals` row with an
--  auto-guessed (or un-guessed) QBO project match, no human ever looking at
--  it until something broke downstream — fine for a one-time historical
--  backfill, wrong for a tool meant to run indefinitely against real client
--  billing. From here on, every deal passes through a human-reviewed
--  promotion gate in Sales Forecast before it's live.
--
--  This table is that gate's only output: which client, which QBO project, a
--  human decided, right now, in the browser. It is deliberately NOT the
--  mechanical write itself — creating deals/promotions/deal_lines rows stays
--  in sync-hubspot.mjs exactly as it works today (including flightFromItems(),
--  the HubSpot-line-item-to-budget parser, left completely unchanged and
--  unported). The nightly sync consumes rows here and deletes them once
--  promoted; `promotions` is already the permanent audit record.
--
--  No FK to pipeline_deals.hubspot_deal_id: that table is a full
--  delete-and-reinsert mirror every sync run ("the mirror is disposable by
--  design"), and a hard FK here would either cascade-wipe approvals mid-sync
--  or make the mirror's own delete step fail outright.
-- ============================================================================

create table promotion_approvals (
  hubspot_deal_id text primary key,
  client_id       uuid not null references clients(id),
  qbo_project_id  text not null references qbo_projects(id),
  approved_by     text not null,
  approved_at     timestamptz not null default now()
);

alter table promotion_approvals enable row level security;
create policy promotion_approvals_policy on promotion_approvals
  for all to authenticated using (true) with check (true);

comment on table promotion_approvals is
  'A human''s decision, made in Sales Forecast, to promote one HubSpot deal '
  'with a specific client + QBO project match. Consumed and deleted by the '
  'next sync-hubspot.mjs run, which does the actual deals/promotions/'
  'deal_lines insert. Not itself an audit trail — promotions (hubspot-sync '
  'original) is that; this is just the queue.';
