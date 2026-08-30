-- ============================================================================
--  063 — new cost_kind values for Credit Memos, Refund Receipts, and Credit
--  Card Credits: three QuickBooks entity types this sync has never pulled at
--  all (only Invoice/Bill/Purchase/JournalEntry).
--
--  (Originally shipped as 057 — renumbered to 063 after a collision with
--  057_batch_burdened_cost_settings.sql, and 061/062 also already taken, all
--  from a peer session's concurrent work. Not yet run against the live
--  database under either number, so the rename is safe.)
--
--  Confirmed as the exact, to-the-penny cause of two real gaps found
--  reconciling against the P&L (Elite Media Group_Account+QuickReport.xlsx):
--
--  - April's "99996 Non Operating Loss" was short $102,634.48 — exactly
--    three Credit Memos ($2,295 + $45,000 + $55,339.48), "TN Waived Invoices
--    Write Off" for True North. Credit Memos were never synced at all.
--
--  - July's "99996 Non Operating Loss" showed +$22,315.45 in our data vs the
--    real -$4,774.55 — the real books have $13,545.00 of "Credit Card
--    Credit" transactions (PURCHASE ADJUSTMENT reversals) exactly offsetting
--    that month's Facebook charges, which this sync never fetched.
--
--  scripts/sync-qbo.mjs now pulls all three. This migration only adds the
--  enum values they're stored under — 'if not exists' so it's safe to
--  re-run.
-- ============================================================================

alter type cost_kind add value if not exists 'credit_memo';
alter type cost_kind add value if not exists 'refund_receipt';
alter type cost_kind add value if not exists 'credit_card_credit';
