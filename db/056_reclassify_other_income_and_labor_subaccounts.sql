-- ============================================================================
--  056 — fix two cost-classification bugs confirmed against the real
--  QuickBooks P&L (Jan-Jul 2026 reconciliation), both already agreed with
--  Boris:
--
--  1. 'Other Income' accounts (95000 Credit card rewards, 95100 Interest
--     earned) were classified identically to real contra-revenue accounts
--     (49500/49550 Paid Search/Social Media Pass Through, which are QuickBooks
--     type 'Income', not 'Other Income') and netted straight into measured
--     revenue via the same -amount contra formula. They're unrelated to
--     client billing; they're money in, so they should reduce overhead
--     instead. Since these lines only ever reach bill_lines via a Journal
--     Entry (Deposits aren't synced, and neither account is something a
--     vendor Bill or company Purchase would ever post to), a credit to them
--     is already stored as a NEGATIVE amount (journals.forEach's signed
--     PostingType handling in sync-qbo.mjs) — reclassifying to 'overhead'
--     alone would already net correctly. The view still forces the sign
--     explicitly (-abs) rather than assume that convention holds for every
--     future line, so a stray Bill/Purchase somehow coded to one of these
--     accounts (always positive-stored) can't silently flip back to adding
--     cost instead of reducing it.
--
--  2. Several Labor Cost sub-accounts (63050 Contract labor, 64000 Bonuses,
--     64999 Severance, 62001 401k, 62004 Health insurance & accident plans,
--     62005 Officers' life insurance) don't match the payroll-detection
--     regex in scripts/sync-qbo.mjs (only caught
--     payroll/salaries/salary/wages/compensation) and landed in overhead
--     instead, understating Payroll and overstating Overhead every month by
--     the same amount (total costs were never wrong, just split wrong).
--
--  classifyAccount() in scripts/sync-qbo.mjs is fixed so newly-created
--  accounts of both kinds classify correctly without a manual override; this
--  migration reclassifies the accounts that already exist via override_class
--  (immediate and retroactive, past months included — the same mechanism the
--  "How costs are counted" panel already exposes by hand).
-- ============================================================================

update qbo_accounts
set override_class = 'overhead',
    override_reason = 'Other Income (credit card rewards / bank interest) is unrelated to client billing; reduces overhead, not revenue — migration 056',
    override_by = 'migration:056',
    override_at = now()
where account_type = 'Other Income'
  and coalesce(override_class, derived_class) is distinct from 'overhead';

update qbo_accounts
set override_class = 'payroll',
    override_reason = 'Labor Cost sub-account missed by the payroll-detection regex — migration 056',
    override_by = 'migration:056',
    override_at = now()
where account_type in ('Expense', 'Other Expense')
  and (
    name ilike '%contract labor%' or name ilike '%bonus%' or name ilike '%severance%'
    or name ilike '%401k%' or name ilike '%health insurance%' or name ilike '%life insurance%'
  )
  and coalesce(override_class, derived_class) is distinct from 'payroll';

-- v_cost_lines_classified (055's version, only the amount expression changes):
-- force Other-Income-typed lines negative so they always reduce whatever
-- class they land in, regardless of how a given line happened to be signed.
create or replace view v_cost_lines_classified as
select
  bl.id, bl.bill_id, b.kind, b.vendor_name, b.issued_on,
  date_trunc('month', b.issued_on::timestamp)::date as month,
  bl.account_id,
  bl.account_name,
  case when coalesce(a.account_type, an.account_type) = 'Other Income'
       then -abs(bl.amount) else bl.amount end        as amount,
  bl.qbo_project_id,
  coalesce(a.override_class, a.derived_class,
           an.override_class, an.derived_class,
           'other'::cost_class)                       as class,
  (a.id is null and an.id is null)                     as unjoined
from bill_lines bl
join bills b on b.id = bl.bill_id
left join qbo_accounts a  on a.id = bl.account_id
-- name fallback ONLY when there is no id, and only when the name is unambiguous
left join lateral (
  select q.* from qbo_accounts q
  where bl.account_id is null
    and (q.fully_qualified_name = bl.account_name or q.name = bl.account_name)
    and 1 = (select count(*) from qbo_accounts q2
             where q2.fully_qualified_name = bl.account_name or q2.name = bl.account_name)
  limit 1
) an on true;

comment on view v_cost_lines_classified is
  'Expense lines with an effective cost class, joined on account id. Name matching '
  'survives only as an unambiguous fallback. unjoined = true marks lines that matched '
  'nothing and are therefore classified other — that count should be near zero, and '
  'anything above it is a data problem to look at, not to average over. Other-Income-typed '
  'lines (credit card rewards, bank interest) are forced negative so they reduce whatever '
  'class they are classified into rather than add to it.';
