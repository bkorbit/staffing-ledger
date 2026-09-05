-- ============================================================================
--  079 — invoice lines learn which account they post to, so revenue can mean
--  what QuickBooks means by it.
--
--  Measured revenue has always summed invoices.total — QuickBooks' TotalAmt,
--  the whole invoice document. QuickBooks' P&L "Total Income" counts only the
--  part of an invoice that lands on an Income-type account. Any line coded to
--  a balance-sheet account is therefore ours and not theirs.
--
--  Confirmed against August 2026, to within 0.18%:
--
--    invoices gross                              1,177,471.50
--    contra revenue netted out (025)              -467,865.34
--    = what the platform showed                    709,606.16
--    Managed Service:Media Deposit (2 lines)      -146,082.68
--    Customer Prepayment (1 line)                  -10,000.00
--    =                                             553,523.48
--    QuickBooks Total Income, August               554,546.25
--    residual                                       -1,022.77
--
--  Both items post to the balance sheet as customer pre-payments, not to
--  income. The same overstatement is in January ($4,909.66) and June
--  ($22,697.68) — inside the ~$20k/mo band 025 wrote off as "refunds and
--  credit memos", which is partly what it actually was. No month in 2026 has
--  a negative Media Deposit line, so a deposit is never drawn down as an
--  offsetting invoice line: the money is recognised later, on the real media
--  invoice, and dropping the deposit line loses nothing permanently.
--
--  The reason this could not simply be filtered: invoice_lines stores item_id
--  and item_name but no account (001), so nothing in the database knew where
--  'Media Deposit' posts. scripts/sync-qbo.mjs already builds exactly the map
--  needed — the Item list keyed to each item's IncomeAccountRef, built at the
--  credit-memo/refund step because those lines resolve their account the same
--  way. This migration adds the columns; the sync change moves that map above
--  the invoice block and stamps every invoice line with it.
--
--  Deliberately NOT a list of item names to exclude. Revenue becomes
--  account-driven, the way cost already is (v_cost_lines_classified), so the
--  next deposit-style item somebody creates in QuickBooks drops out on its
--  own instead of silently reintroducing this bug.
--
--  Existing rows have a null account until a full QBO re-sync backfills them.
--  080 is written so that null means "count it as revenue, exactly as today",
--  which is why 079 and 080 are safe to run together before the re-sync: the
--  numbers do not move until the accounts arrive.
-- ============================================================================

alter table invoice_lines add column if not exists account_id   text;
alter table invoice_lines add column if not exists account_name text;

-- The account is resolved per line, so the filter in 080 can be an indexed
-- lookup rather than a scan of every line on every invoice in range.
create index if not exists invoice_lines_account_idx
  on invoice_lines (account_id) where account_id is not null;

-- Invoice lines with an effective class, mirroring v_cost_lines_classified
-- (056) — same id join, same unambiguous-name fallback, same unjoined flag.
--
-- One difference in meaning, worth being explicit about because the class
-- names collide: in v_cost_lines_classified, class = 'income' marks a COST
-- line hitting an income account, i.e. contra revenue, which SUBTRACTS from
-- revenue. Here, class = 'income' marks an invoice line hitting an income
-- account, i.e. real revenue, which ADDS. Same account, opposite side of the
-- transaction. 080 uses both and the sign follows from which table a row
-- came from, not from the class.
create or replace view v_invoice_lines_classified as
select
  il.id, il.invoice_id, il.line_no, il.item_id, il.item_name,
  i.issued_on,
  date_trunc('month', i.issued_on::timestamp)::date as month,
  i.qbo_project_id,
  il.account_id,
  il.account_name,
  il.amount,
  coalesce(a.override_class, a.derived_class,
           an.override_class, an.derived_class)      as class,
  -- true only when this line carries an account we could not resolve at all.
  -- Distinct from account_id being null, which means the sync has not stamped
  -- this row yet (pre-backfill) — 080 must treat those two the same way and
  -- count the line as revenue, so neither can silently delete money.
  (il.account_id is not null and a.id is null and an.id is null) as unjoined
from invoice_lines il
join invoices i on i.id = il.invoice_id
left join qbo_accounts a on a.id = il.account_id
-- name fallback ONLY when there is no id, and only when the name is unambiguous
left join lateral (
  select q.* from qbo_accounts q
  where il.account_id is null
    and (q.fully_qualified_name = il.account_name or q.name = il.account_name)
    and 1 = (select count(*) from qbo_accounts q2
             where q2.fully_qualified_name = il.account_name or q2.name = il.account_name)
  limit 1
) an on true;

comment on view v_invoice_lines_classified is
  'Invoice lines with an effective cost class, resolved through the posting '
  'account the sync reads from each item''s IncomeAccountRef. The twin of '
  'v_cost_lines_classified (056) on the revenue side, with the same id join and '
  'unambiguous-name fallback. class = ''income'' here means real revenue (an '
  'invoice line hitting an income account), the opposite role the same class '
  'plays in v_cost_lines_classified, where it means contra revenue. class is '
  'null when the line has no account yet — that is the pre-backfill state, not '
  'an error, and 080 counts those as revenue so the numbers cannot move until '
  'a re-sync has actually stamped them.';

comment on column invoice_lines.account_id is
  'QuickBooks account this line posts to, read from the line item''s '
  'IncomeAccountRef by scripts/sync-qbo.mjs (079). Null until a full re-sync '
  'backfills it, and null is treated as revenue so nothing disappears in the '
  'meantime.';
