-- Fixture test for 085 + 086 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-087 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. read the SIX rows of the single result set at the bottom
--   3. it ends in ROLLBACK — the fixture account and the override it sets on a
--      real bank account are both undone. Do not swap that for a commit.
--
-- RESHAPED 8 Sep 2026, for two reasons.
--
-- ONE: it was five separate select statements, and the Supabase SQL editor
-- returns only the LAST one's result. Running it showed a single line and
-- silently discarded the other four verdicts. Assertions are now rows of one
-- final select; setup stays as separate statements because it has to.
--
-- TWO, and more important: tests 1 and 2 asserted that the cash set is
-- EXACTLY the Bank-typed set. That was 086's equivalence argument on the day
-- it shipped, and it decays the moment anyone uses the feature — classing a
-- Stripe balance as cash in Settings > Finance is the whole point of 086, and
-- it would have made this file report FAIL for a system working correctly. A
-- test that cries wolf as soon as the feature is adopted gets ignored, which
-- is worse than no test. They now assert the durable invariant instead: the
-- two sets may differ ONLY by accounts a human deliberately classed
-- (override_class is not null), and every such difference is named in the
-- output so it can be eyeballed.
--
-- What is being proved:
--   1. OPENING POSITION — the cashflow opening equals the old Bank-typed
--      total, or differs from it only by hand-classed accounts, itemised.
--   2. MEMBERSHIP — every account where Bank-ness and cash-ness disagree is
--      one a human decided on. An unexplained divergence is a real failure:
--      it would mean the derivation changed underneath everyone.
--   3. cashflow_forecast still executes. A plpgsql function reproduced whole
--      from 071 can fail at runtime rather than at creation.
--   4. A hand-classed Other Current Asset account joins the opening position,
--      which was the point of 086.
--   5. The class governs in both directions: a Bank account overridden away
--      from 'cash' leaves.
--   6. END TO END — cashflow_forecast's own first-period position moves by
--      exactly the hand-classed balance. 1 through 5 test v_cash_accounts;
--      this tests the thing 086 actually changed, which is that the FORECAST
--      reads from it. The original file never checked that at all.

begin;

create temp table _fx_base as
select
  (select coalesce(sum(balance), 0) from qbo_accounts
    where account_type = 'Bank'
      and (not exists (select 1 from qbo_accounts where account_type = 'Bank' and is_operating)
           or is_operating))                                      as old_opening,
  (select coalesce(sum(balance), 0) from v_cash_accounts
    where (not exists (select 1 from v_cash_accounts where is_operating)
           or is_operating))                                      as new_opening,
  (select exists (select 1 from v_cash_accounts where is_operating)) as operating_set;

-- every account where "QuickBooks types it Bank" and "it is classed cash"
-- disagree, with whether a human is the reason
create temp table _fx_diff as
select a.id,
       coalesce(a.fully_qualified_name, a.name)  as account,
       a.account_type,
       (a.override_class is not null)            as is_manual,
       a.balance,
       a.is_operating,
       case when a.account_type = 'Bank' then 'Bank-typed, NOT classed cash'
            else 'classed cash, not Bank-typed' end as side
from qbo_accounts a
where (a.account_type = 'Bank') <> (a.id in (select id from v_cash_accounts));

-- run it once on the untouched state, before anything is inserted
create temp table _fx_runs as
select (select count(*) from cashflow_forecast(2)) = 2 as ok;

create temp table _fx_pos_before as
select position_expected as pos
from cashflow_forecast(2) order by week_start limit 1;

-- A Stripe balance: real money, and QuickBooks types it Other Current Asset,
-- so account_type = 'Bank' could never have found it. is_operating mirrors the
-- file's current state so inserting it cannot flip the operating_set fallback
-- and move every other account in or out underneath the assertion.
insert into qbo_accounts (id, name, fully_qualified_name, account_type,
                          derived_class, override_class, balance, is_operating)
select '_fx_stripe', '_fx Stripe balance', '_fx Stripe balance', 'Other Current Asset',
       'excluded', 'cash', 500000, (select operating_set from _fx_base);

create temp table _fx_t4 as
select (select coalesce(sum(balance), 0) from v_cash_accounts
        where (not exists (select 1 from v_cash_accounts where is_operating)
               or is_operating))
       - (select new_opening from _fx_base) as delta;

-- the same 500000, but measured through cashflow_forecast rather than through
-- the view. Nothing else about the fixture touches AR, bills or payroll, so
-- the first period's position must move by exactly the new balance.
create temp table _fx_pos_after as
select position_expected as pos
from cashflow_forecast(2) order by week_start limit 1;

-- and the other direction: the class governs, so overriding a bank account
-- away from 'cash' removes it. Membership only — asserting the opening delta
-- here would depend on whether that one account was the last operating one.
-- Picks an account that is currently IN the cash set, so the assertion cannot
-- pass trivially on one that had already been overridden out.
create temp table _fx_out as
select a.id from qbo_accounts a
where a.account_type = 'Bank' and a.id in (select id from v_cash_accounts)
order by a.balance limit 1;

update qbo_accounts set override_class = 'excluded' where id in (select id from _fx_out);

create temp table _fx_t5 as
select (select count(*) from _fx_out) = 0
    or not exists (select 1 from v_cash_accounts where id in (select id from _fx_out)) as ok;

-- ======================= THE RESULT: six rows, read them all ==============
with r(n, result) as (

  select 1, case
    when b.old_opening = b.new_opening
    then '1. OPENING POSITION: PASS — identical to the Bank-typed total ('
         || round(b.new_opening / 100.0, 2)::text || ')'
    when not exists (select 1 from _fx_diff where not is_manual)
    then '1. OPENING POSITION: PASS — ' || round(b.new_opening / 100.0, 2)::text
         || ' vs Bank-typed ' || round(b.old_opening / 100.0, 2)::text
         || ', and every account behind the difference was classed by hand: '
         || coalesce((select string_agg(account || ' (' || side || ', '
                        || round(balance / 100.0, 2)::text || ')', '; ') from _fx_diff), '?')
    else '1. OPENING POSITION: FAIL — ' || round(b.new_opening / 100.0, 2)::text
         || ' vs Bank-typed ' || round(b.old_opening / 100.0, 2)::text
         || ', NOT explained by hand classification: '
         || coalesce((select string_agg(account || ' (' || side || ')', '; ')
                      from _fx_diff where not is_manual), '?')
    end
  from _fx_base b

  union all
  select 2, case
    when not exists (select 1 from _fx_diff)
    then '2. MEMBERSHIP: PASS — the cash set is exactly the Bank-typed set'
    when not exists (select 1 from _fx_diff where not is_manual)
    then '2. MEMBERSHIP: PASS — ' || (select count(*) from _fx_diff)::text
         || ' account(s) differ, all of them a human''s explicit choice'
    else '2. MEMBERSHIP: FAIL — ' || (select count(*) from _fx_diff where not is_manual)::text
         || ' account(s) differ with no override to explain it: '
         || coalesce((select string_agg(account || ' [' || account_type || '] ' || side, '; ')
                      from _fx_diff where not is_manual), '?')
    end

  union all
  select 3, case when (select ok from _fx_runs)
    then '3. cashflow_forecast STILL RUNS: PASS'
    else '3. cashflow_forecast STILL RUNS: FAIL — did not return 2 periods' end

  union all
  select 4, case when (select delta from _fx_t4) = 500000
    then '4. HAND-CLASSED CASH ACCOUNT COUNTS: PASS'
    else '4. HAND-CLASSED CASH ACCOUNT COUNTS: FAIL — opening moved by '
         || (select delta from _fx_t4)::text || ', expected 500000' end

  union all
  select 5, case when (select ok from _fx_t5)
    then '5. OVERRIDE REMOVES A BANK FROM CASH: PASS'
    else '5. OVERRIDE REMOVES A BANK FROM CASH: FAIL — '
         || coalesce((select string_agg(id, ', ') from _fx_out), 'no bank account to test')
         || ' is still in v_cash_accounts after override_class = excluded' end

  union all
  select 6, case when (select pos from _fx_pos_after) - (select pos from _fx_pos_before) = 500000
    then '6. CASHFLOW POSITION READS THE CASH CLASS: PASS (first period +500000)'
    else '6. CASHFLOW POSITION: FAIL — first-period position moved by '
         || ((select pos from _fx_pos_after) - (select pos from _fx_pos_before))::text
         || ', expected 500000. cashflow_forecast is not sourcing its opening '
         || 'from v_cash_accounts.' end
)
select result from r order by n;

rollback;
