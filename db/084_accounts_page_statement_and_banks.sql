-- ============================================================================
--  084 — accounts_page() gains the two things the Finance table was missing:
--  whether an account is on the P&L or the balance sheet, and everything about
--  a bank account.
--
--  P&L vs BALANCE SHEET
--  --------------------
--  Derived from QuickBooks' own account type, not from our cost_class, and the
--  distinction is the one that actually matters when reading the table: an
--  account on the balance sheet moves money without earning or spending it.
--  It is the whole reason 'Customer prepayments' was overstating revenue —
--  invoices billed against a balance-sheet account, and nothing on screen said
--  so. Naming the statement makes that visible before it costs anyone $146k.
--
--  Computed here rather than in the page so there is one definition of which
--  statement an account belongs to, the same way cost_class has one.
--
--  BANK ACCOUNTS
--  -------------
--  Which accounts ARE banks was never a choice — QuickBooks' account_type says
--  so, and the sync has always mirrored it. What IS a choice is which of them
--  count toward the cashflow opening position (is_operating, 005), and until
--  now that lived in its own panel listing bank accounts separately from the
--  chart of accounts they are part of.
--
--  Two lists of accounts on one screen is one list too many. is_operating,
--  balance and as_of come back with every other account here so the chart of
--  accounts can be the single place accounts are looked at and decided about,
--  and the separate Bank accounts panel goes away rather than becoming a
--  second control writing the same column.
-- ============================================================================

create or replace function accounts_page()
returns jsonb as $$
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
select jsonb_build_object(
  'accounts', coalesce((select jsonb_agg(t order by t.at_stake_cents desc, t.account) from (
      select a.id,
             coalesce(a.fully_qualified_name, a.name)          as account,
             a.name,
             a.account_type,
             -- QuickBooks' own split. Anything not on the P&L is on the
             -- balance sheet; a typeless account is neither until it is fixed.
             case
               when a.account_type is null then null
               when a.account_type in ('Income', 'Other Income', 'Cost of Goods Sold',
                                       'Expense', 'Other Expense') then 'pl'
               else 'bs'
             end                                              as statement,
             (a.account_type = 'Bank')                        as is_bank,
             a.is_operating,
             a.balance::bigint                                as balance_cents,
             a.as_of,
             a.derived_class::text                            as derived_class,
             a.override_class::text                           as override_class,
             coalesce(a.override_class, a.derived_class)::text as class,
             a.override_reason,
             a.override_by,
             a.review_ack_at,
             a.review_ack_by,
             a.review_ack_reason,
             r.reason                                         as review_reason,
             coalesce(i.amount, 0)::bigint                    as invoiced_cents,
             coalesce(c.amount, 0)::bigint                    as costed_cents,
             coalesce(i.lines, 0)::bigint                     as invoiced_lines,
             coalesce(c.lines, 0)::bigint                     as costed_lines,
             (coalesce(i.amount, 0) + coalesce(c.amount, 0))::bigint as at_stake_cents
      from qbo_accounts a
      left join inv_activity  i on i.account_id = a.id
      left join cost_activity c on c.account_id = a.id
      left join v_accounts_needing_review r on r.id = a.id) t), '[]'::jsonb),
  'counts', (select jsonb_build_object(
      'total',        count(*),
      'needs_review', count(*) filter (where r.id is not null),
      'acknowledged', count(*) filter (where a.review_ack_at is not null),
      'overridden',   count(*) filter (where a.override_class is not null),
      'unclassified', count(*) filter (where coalesce(a.override_class, a.derived_class) is null),
      'banks',        count(*) filter (where a.account_type = 'Bank'),
      'operating',    count(*) filter (where a.is_operating))
    from qbo_accounts a
    left join v_accounts_needing_review r on r.id = a.id)
);
$$ language sql stable;

comment on function accounts_page is
  'The Settings > Finance chart-of-accounts screen in one jsonb: every account '
  'with its effective class, its acknowledgement state (082), the money riding '
  'on it, its review_reason when v_accounts_needing_review still wants a human '
  'to look at it, and (084) which financial statement it belongs to plus its '
  'bank balance and operating flag. statement is QuickBooks'' own P&L/balance-'
  'sheet split, and it is the distinction that matters most when reading the '
  'table — a balance-sheet account moves money without earning or spending it, '
  'which is exactly how Customer prepayments overstated revenue unnoticed. '
  'invoiced_cents/costed_cents are the two sides an account is actually used '
  'on, which is how the UI labels an income account Revenue and Contra-Revenue '
  'at once without either being a setting: the role follows the side a line '
  'lands on (025/080), not a choice.';
