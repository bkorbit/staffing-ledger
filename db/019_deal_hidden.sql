-- ============================================================================
--  019 — hiding deals from the forecast, permanently.
--
--  Same contract as qbo_projects.hidden: human-owned columns the sync never
--  writes. The promotion door inserts each HubSpot deal exactly once (guarded by
--  hubspot_deal_id), so a hidden deal is never re-inserted or un-hidden by a
--  sync. Manual deals are never touched by the sync at all.
--
--  hidden removes a deal from the forecast's table and its plan from the chart.
--  Its matched project's actuals, if any, fall back to the client's unclaimed
--  remainder — the money does not vanish, it just stops being attributed to a
--  hidden deal.
-- ============================================================================

alter table deals add column if not exists hidden    boolean not null default false;
alter table deals add column if not exists hidden_by text;
alter table deals add column if not exists hidden_at timestamptz;

comment on column deals.hidden is
  'Human-owned; sync never writes it. Hidden deals leave the forecast; their '
  'project actuals fall back to the client remainder.';
