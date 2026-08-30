-- ============================================================================
--  054 — retire 'closed'/'lost' deal status; hidden is the one exclusion path.
--
--  'closed' and 'lost' are never written by any sync or app code — confirmed
--  by grepping every script and page — only ever reachable by a direct SQL
--  edit. They predate 019's hidden flag, which does the identical job (remove
--  a deal from every forward-looking view, money falls back to the client's
--  unclaimed remainder) but with an audit trail (hidden_by/hidden_at), a UI
--  button, and a documented unhide path. status in ('closed','lost') has none
--  of that: a deal sitting there is invisible everywhere with zero trace of
--  why or who — which is exactly what caused four rounds of "why isn't this
--  deal showing up" in one afternoon (see app/settings.html's
--  statusFlightMismatch panel, added the same day, for the paper trail).
--
--  This does not guess intent — it preserves it. Every closed/lost deal keeps
--  being excluded from forecast/cashflow/sales/index exactly as it is today;
--  only the mechanism changes, from an unaudited status value to the same
--  hidden flag every other excluded deal already uses. Review the hidden set
--  afterward (below) and un-hide any that should actually be live — the same
--  judgment call this migration is deferring, just made visibly instead of by
--  accident.
--
--  Already-reopened deals (status flipped to 'active' by hand, e.g. via the
--  Settings "Reopen" button) are untouched — they're not in scope, and
--  correctly so.
-- ============================================================================

-- Review before running the update: every deal this migration is about to
-- touch, and whether it's already hidden (redundant exclusion) or not
-- (exclusion is moving from status to hidden for the first time).
select id, name, hubspot_deal_id, status, hidden, flight_start, flight_end
from deals
where status in ('closed', 'lost')
order by flight_end desc nulls last;

update deals
set hidden    = true,
    hidden_by = coalesce(hidden_by, 'migration:054'),
    hidden_at = coalesce(hidden_at, now()),
    status    = 'active',
    set_by    = 'migration:054',
    set_at    = now()
where status in ('closed', 'lost');

comment on column deals.status is
  'won/active are equivalent everywhere (active = manually reopened via '
  'Settings). closed/lost are retired as of 054 — nothing writes them anymore; '
  'excluding a deal from the forecast is deals.hidden''s job now, not status.';
