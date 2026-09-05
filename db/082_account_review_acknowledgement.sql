-- ============================================================================
--  082 — a reviewed account stops asking to be reviewed.
--
--  081's v_accounts_needing_review flags accounts whose QuickBooks type cannot
--  settle how they should be counted. On EMG's real data it returns 8 rows, and
--  most of them are CORRECT as they stand: 'Pass Through Revenue:Paid Search
--  Media Pass Through' at $2.59M is flagged income_needs_side_check because an
--  income account is being debited, which is exactly what contra revenue looks
--  like and exactly what 025 wants it to do.
--
--  A queue that lists correct things forever is not a queue, it is wallpaper.
--  Worse for the SaaS case: a new company cannot tell "we have not looked at
--  this yet" from "we looked and it is fine", so onboarding never completes.
--
--  So an account can be acknowledged: a person says this classification is
--  right, and it leaves the queue. What is stored is WHY it was acknowledged,
--  not merely that it was — because the reason is what was actually judged. If
--  an account later trips a DIFFERENT reason (a liability that has only ever
--  been costed suddenly appears on an invoice — a new deposit account), the
--  stored reason no longer matches the live one and it comes back. Silence is
--  earned per question, not per account, and forever.
--
--  Reclassifying an account clears its acknowledgement outright. That is done
--  where the class is written (Settings > Finance) rather than by a trigger
--  here: the write and the clear belong in the same statement so a class change
--  can never leave a stale "reviewed" badge behind it.
-- ============================================================================

alter table qbo_accounts add column if not exists review_ack_at     timestamptz;
alter table qbo_accounts add column if not exists review_ack_by     text;
alter table qbo_accounts add column if not exists review_ack_reason text;

comment on column qbo_accounts.review_ack_reason is
  'The v_accounts_needing_review reason that was acknowledged. Stored rather '
  'than a bare boolean so that an account tripping a NEW reason returns to the '
  'queue instead of staying silent on the strength of an older, unrelated '
  'judgement.';

-- 081's view, with the reason lifted into a CTE so it can be both selected and
-- filtered on, and acknowledged rows dropped. Column list and order are
-- unchanged from 081 so this is a valid CREATE OR REPLACE.
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
),
flagged as (
  select a.id,
         coalesce(a.fully_qualified_name, a.name)    as account,
         a.account_type,
         coalesce(a.override_class, a.derived_class) as class,
         a.override_class is not null                as is_overridden,
         a.review_ack_at,
         a.review_ack_reason,
         case
           when coalesce(a.override_class, a.derived_class) is null then 'unclassified'
           when a.account_type in ('Other Current Liability', 'Long Term Liability',
                                   'Other Current Asset', 'Other Asset')
                and coalesce(i.lines, 0) > 0                        then 'liability_on_invoice'
           when coalesce(a.override_class, a.derived_class) = 'income'
                and coalesce(c.lines, 0) > 0                        then 'income_needs_side_check'
         end                                        as reason,
         coalesce(i.amount, 0)                      as invoiced_cents,
         coalesce(c.amount, 0)                      as costed_cents
  from qbo_accounts a
  left join inv_activity  i on i.account_id = a.id
  left join cost_activity c on c.account_id = a.id
)
select id, account, account_type, class, is_overridden, reason,
       invoiced_cents, costed_cents,
       invoiced_cents + costed_cents as at_stake_cents
from flagged
where reason is not null
  -- acknowledged, and still for the same reason -> stays quiet. A new reason
  -- means a new question, and the account returns.
  and (review_ack_at is null or review_ack_reason is distinct from reason);

comment on view v_accounts_needing_review is
  'The accounts a company must look at before its P&L can be trusted, and only '
  'those — QuickBooks'' own account types classify everything else without a '
  'question being asked, and an account acknowledged for a given reason (082) '
  'drops out until it trips a different one. reason says what the type could '
  'not settle: ''liability_on_invoice'' is an invoice billing against a '
  'balance-sheet account, which is a customer deposit or pre-payment and should '
  'be classed ''deposit'' (this is how Managed Service:Media Deposit would have '
  'surfaced in August 2026 without a hand reconciliation against the QuickBooks '
  'P&L); ''income_needs_side_check'' is an income account being debited by a '
  'bill or journal, which is either pass-through contra revenue or a revenue '
  'reclass, and only a human knows which; ''unclassified'' is an account with '
  'money and no class, which is always a data problem. Sorted on by '
  'at_stake_cents in the UI so the biggest exposure is reviewed first.';
