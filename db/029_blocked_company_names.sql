-- ============================================================================
--  029 — a "Don't match" list: company names HubSpot promotion must never
--  turn into (or attach a deal to) a client.
--
--  client_aliases already lets a human say "this company name IS this client"
--  — a positive redirect. There was no way to say the opposite: "this company
--  name is bad data, never create or reuse a client for it." A mismatched
--  HubSpot deal (wrong company on it) would otherwise keep silently creating —
--  or, after a human deactivates the resulting bad client, keep silently
--  reattaching to — a client that never should have existed.
--
--  Checked inside promotionBlocker(), the same place "no campaign dates" is
--  checked: a blocked name holds the deal at the door, mirrored but never
--  promoted, exactly like any other unpromotable deal. A human resolves it by
--  fixing the company on the deal in HubSpot (so it no longer matches the
--  blocked name) or by clearing the block once a proper alias exists instead.
-- ============================================================================

create table blocked_company_names (
  name_key text primary key,   -- nameKey()-normalized: trim, collapse spaces, lowercase
  name     text not null,      -- original display name, for the run log and the UI
  reason   text,
  set_by   text,
  set_at   timestamptz not null default now()
);

comment on table blocked_company_names is
  'Company names that must never auto-create or auto-attach to a client during '
  'HubSpot promotion. Checked before a deal can promote, the same way missing '
  'campaign dates are — a match here holds the deal at the door on every sync '
  'until a human fixes the mismatch in HubSpot or clears the block here.';
