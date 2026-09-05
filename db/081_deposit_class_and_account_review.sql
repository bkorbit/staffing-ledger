-- ============================================================================
--  081 — a 'deposit' account class, and a view of what a new company has to
--  look at before its P&L can be trusted.
--
--  Groundwork for moving account classification out of the Forecast page's
--  disclosure panel and into Settings > Finance, where a company that is not
--  EMG can set up its own chart of accounts.
--
--  THE TAXONOMY, and why it is one new value and not six
--  -----------------------------------------------------
--  The classes a user picks from are Revenue, COGS, Labor, Overhead, Other,
--  Deposits, Excluded. Only one of those needs a new enum value:
--
--    Revenue        -> stored as 'income'   (existing)
--    Contra-Revenue -> DERIVED, never picked (see below)
--    COGS           -> 'cogs'               (existing)
--    Labor          -> 'payroll'            (existing, display name only)
--    Overhead       -> 'overhead'           (existing)
--    Other          -> 'other'              (existing)
--    Deposits       -> 'deposit'            (NEW, this migration)
--    Excluded       -> 'excluded'           (existing)
--
--  Contra-Revenue is a consequence, not a choice. An Income account is
--  revenue when an invoice line lands on it and contra revenue when a bill or
--  journal line does — same account, opposite side of the transaction. That
--  is how 025 and 080 already work, and offering it in the picker would put a
--  setting in front of the user that cannot change anything.
--
--  'payroll' is NOT renamed to 'labor'. The label belongs in the UI; renaming
--  the enum value would force a rewrite of every function filtering
--  class = 'payroll' across 069, 070, 071, 072, 074, 076 and 080 to buy
--  nothing but a different word in the catalog.
--
--  Adding a 'revenue' value would have been an active bug: 080 subtracts an
--  invoice line whose class is anything other than 'income', so a line
--  classified 'revenue' would have been subtracted from revenue.
--
--  WHY 'deposit' EXISTS AT ALL
--  ---------------------------
--  Arithmetically it is 'excluded': 080 subtracts any invoice line whose
--  class is not 'income', so both are kept out of the P&L identically, and
--  neither touches cashflow, which collects on invoices.balance (007) and
--  never asks about class. A customer deposit therefore already arrives as
--  cash on its own due date, exactly as it should, under either class.
--
--  It exists because "which of your accounts are customer deposits?" is a
--  question a new company must answer deliberately, and 'excluded' is where
--  bank accounts, AR, AP and equity go — a bucket nobody reviews. Naming
--  deposits separately makes the setup step real and gives Cashflow a hook if
--  those dollars should ever be shown apart from ordinary collections.
--
--  Nothing auto-classifies AS 'deposit'. A customer-deposit liability is
--  indistinguishable from any other liability by type alone, so the sync
--  keeps sending liabilities to 'excluded' and the user promotes the ones
--  that are deposits. That is the point: the user tells us.
--
--  No math changes here. This migration adds an enum value and a view.
-- ============================================================================

alter type cost_class add value if not exists 'deposit';

-- ----------------------------------------------------------------------------
-- What a company has to review before trusting its numbers.
--
-- The onboarding contract is: QuickBooks account types auto-classify
-- everything, and this view surfaces only the accounts where the type alone
-- cannot decide. Everything else is left alone and never shown as a task.
--
-- Three things a type genuinely cannot tell us apart:
--
--   income_needs_side_check — an Income account that has been DEBITED by a
--     bill/purchase/journal line. That is the signature of pass-through
--     contra revenue (EMG's 49500/49550), but it is also what a revenue
--     reclass journal looks like. Worth a human glance, because it is the
--     difference between netting money out of revenue and not.
--
--   liability_on_invoice — a balance-sheet account that an INVOICE line
--     posts to. There is no innocent reason to bill a customer against a
--     liability except a deposit or pre-payment, so this is the
--     deposit-discovery query. It is exactly how Managed Service:Media
--     Deposit would have been found in August 2026 without reconciling by
--     hand against the P&L.
--
--   unclassified — an account carrying real money that resolved to no class
--     at all. Always a data problem, never a preference.
--
-- Ordered by money at stake, because a $146k account and a $12 account do not
-- deserve equal attention.
-- ----------------------------------------------------------------------------
create or replace view v_accounts_needing_review as
with inv_activity as (
  select account_id, sum(abs(amount)) as amount, count(*) as lines
  from v_invoice_lines_classified
  where account_id is not null
  group by account_id
),
cost_activity as (
  select account_id, sum(abs(amount)) as amount, count(*) as lines
  from v_cost_lines_classified
  where account_id is not null
  group by account_id
)
select a.id,
       coalesce(a.fully_qualified_name, a.name)          as account,
       a.account_type,
       coalesce(a.override_class, a.derived_class)       as class,
       a.override_class is not null                      as is_overridden,
       case
         when coalesce(a.override_class, a.derived_class) is null then 'unclassified'
         when a.account_type in ('Other Current Liability', 'Long Term Liability',
                                 'Other Current Asset', 'Other Asset')
              and coalesce(i.lines, 0) > 0                        then 'liability_on_invoice'
         when coalesce(a.override_class, a.derived_class) = 'income'
              and coalesce(c.lines, 0) > 0                        then 'income_needs_side_check'
       end                                              as reason,
       coalesce(i.amount, 0)                            as invoiced_cents,
       coalesce(c.amount, 0)                            as costed_cents,
       coalesce(i.amount, 0) + coalesce(c.amount, 0)    as at_stake_cents
from qbo_accounts a
left join inv_activity  i on i.account_id  = a.id
left join cost_activity c on c.account_id = a.id
where
  coalesce(a.override_class, a.derived_class) is null
  or (a.account_type in ('Other Current Liability', 'Long Term Liability',
                         'Other Current Asset', 'Other Asset')
      and coalesce(i.lines, 0) > 0)
  or (coalesce(a.override_class, a.derived_class) = 'income'
      and coalesce(c.lines, 0) > 0);

comment on view v_accounts_needing_review is
  'The accounts a company must look at before its P&L can be trusted, and only '
  'those — QuickBooks'' own account types classify everything else without a '
  'question being asked. reason says what the type could not settle: '
  '''liability_on_invoice'' is an invoice billing against a balance-sheet '
  'account, which is a customer deposit or pre-payment and should be classed '
  '''deposit'' (this is how Managed Service:Media Deposit would have surfaced '
  'in August 2026 without a hand reconciliation against the QuickBooks P&L); '
  '''income_needs_side_check'' is an income account being debited by a bill or '
  'journal, which is either pass-through contra revenue or a revenue reclass, '
  'and only a human knows which; ''unclassified'' is an account with money and '
  'no class, which is always a data problem. Sorted on by at_stake_cents in the '
  'UI so the biggest exposure is reviewed first.';
