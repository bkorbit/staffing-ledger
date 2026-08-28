-- ============================================================================
--  028 — recover the exact flight dates promotion threw away, lock them
--  against ever being silently overwritten again.
--
--  Migration 022 dropped deals' first-of-month CHECK constraints and taught
--  v_deal_month_forecast to date_trunc internally for its own month series —
--  the schema and the view were both upgraded to carry exact flight dates.
--  scripts/sync-hubspot.mjs's promotion step was never updated to match: it
--  kept calling monthStart() on HubSpot's campaign_start_date/campaign_end_date
--  before writing deals.flight_start/flight_end, so every deal promoted since
--  (which, today, is all of them) has its real day-of-month precision thrown
--  away in favor of the 1st of the month.
--
--  pipeline_deals is a full, unfiltered mirror of every HubSpot deal —
--  including won/promoted ones — refreshed on every sync run, so the exact
--  dates are still sitting right there, keyed by the same hubspot_deal_id.
--  This backfills deals.flight_start/flight_end from that mirror.
--
--  flight_locked is new: once a human adjusts a deal's flight dates in the
--  platform editor, this flips true and no future HubSpot-sourced backfill
--  (this one or a later one) may touch that deal's dates again. Everything
--  is false today, so this first run applies to every promoted deal that
--  still has a matching, dated row in pipeline_deals.
-- ============================================================================

alter table deals
  add column if not exists flight_locked boolean not null default false;

comment on column deals.flight_locked is
  'true once a human has set flight_start/flight_end in the platform editor. '
  'Any HubSpot-sourced backfill of campaign dates (028 and any future one) '
  'must skip a deal once this is true — the platform, not HubSpot, owns it.';

update deals d
set flight_start = pd.campaign_start,
    flight_end   = pd.campaign_end,
    set_by = 'hubspot-backfill-028',
    set_at = now()
from pipeline_deals pd
where d.hubspot_deal_id = pd.hubspot_deal_id
  and d.flight_locked = false
  and pd.campaign_start is not null
  and pd.campaign_end is not null
  and pd.campaign_end >= pd.campaign_start
  and (d.flight_start is distinct from pd.campaign_start
       or d.flight_end is distinct from pd.campaign_end);
