-- ============================================================================
--  065 — won_deal_dismissals: let a human retire an old won deal from the
--  promotion gate for good.
--
--  pipeline_deals is a full delete-and-reinsert mirror every sync run — a
--  dismissal can't live there, it would vanish on the next sync. Some won
--  HubSpot deals are years-old, abandoned business that will never get real
--  campaign dates (nobody is going back to fix 2024 closed deals) and will
--  otherwise sit in Sales Forecast's "Needs setup" queue forever. This table
--  is the queue's escape hatch: dismissed once, gone for good, independent of
--  the mirror's own churn.
--
--  Same shape as blocked_company_names (029) — a small, human-owned list the
--  gate checks against, not a judgment the sync or matcher ever makes itself.
-- ============================================================================

create table won_deal_dismissals (
  hubspot_deal_id text primary key,
  dismissed_by    text not null,
  dismissed_at    timestamptz not null default now()
);

alter table won_deal_dismissals enable row level security;
create policy won_deal_dismissals_policy on won_deal_dismissals
  for all to authenticated using (true) with check (true);

comment on table won_deal_dismissals is
  'Human-owned; a won HubSpot deal listed here is permanently excluded from '
  'Sales Forecast''s promotion gate (all three sections — ready, blocked, '
  'approved), regardless of what pipeline_deals says on the next sync. For '
  'old/abandoned deals that will never get real campaign dates. Reversible '
  'by deleting the row — no app UI does that, same as blocked_company_names.';
