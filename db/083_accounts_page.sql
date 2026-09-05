-- ============================================================================
--  083 — accounts_page(): everything Settings > Finance needs about the chart
--  of accounts, in one round trip.
--
--  Account classification is moving off the Forecast page's disclosure panel,
--  where it was a diagnostic bolted to a chart, and into Settings, where a
--  company that is not EMG sets up its own books. That panel could get away
--  with reading whatever forecast_page already had in hand. A setup screen
--  cannot: it has to show every account, whether each one is classified,
--  how much money rides on it, and — the part that only exists after 079 —
--  which side of the ledger it is actually used on.
--
--  invoiced vs costed is the whole point, and it is what makes Revenue and
--  Contra-Revenue displayable without being separately configurable. An
--  income account with invoiced lines is revenue. The SAME income account
--  with costed lines is contra revenue, because a bill or journal debiting an
--  income account reduces income (025). One class, two roles, decided by
--  which side a line lands on rather than by anything a user picks — so the
--  UI can state both roles as fact instead of offering a choice that would
--  not change the arithmetic.
--
--  review_reason is carried per account rather than returned as a separate
--  list, so the review queue and the full account table are the same rows
--  filtered two ways and can never disagree about an account's state.
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
             coalesce(a.fully_qualified_name, a.name)      as account,
             a.name,
             a.account_type,
             a.derived_class::text                         as derived_class,
             a.override_class::text                        as override_class,
             coalesce(a.override_class, a.derived_class)::text as class,
             a.override_reason,
             a.override_by,
             a.review_ack_at,
             a.review_ack_by,
             a.review_ack_reason,
             r.reason                                      as review_reason,
             coalesce(i.amount, 0)::bigint                 as invoiced_cents,
             coalesce(c.amount, 0)::bigint                 as costed_cents,
             coalesce(i.lines, 0)::bigint                  as invoiced_lines,
             coalesce(c.lines, 0)::bigint                  as costed_lines,
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
      'unclassified', count(*) filter (where coalesce(a.override_class, a.derived_class) is null))
    from qbo_accounts a
    left join v_accounts_needing_review r on r.id = a.id)
);
$$ language sql stable;

comment on function accounts_page is
  'The Settings > Finance chart-of-accounts screen in one jsonb: every account '
  'with its effective class, its acknowledgement state (082), the money riding '
  'on it, and its review_reason when v_accounts_needing_review still wants a '
  'human to look at it. invoiced_cents/costed_cents are the two sides an '
  'account is actually used on, which is how the UI can label an income account '
  'Revenue and Contra-Revenue at once without either being a setting: the role '
  'follows the side a line lands on (025/080), not a choice. Ordered by money '
  'at stake so the biggest exposure sorts first.';
