-- Fixture test for 085 + 086 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-086 applied.
--
--   1. paste this whole file (it opens its own transaction)
--   2. look for the five PASS / FAIL lines
--   3. it ends in ROLLBACK — the fixture rows and the override it sets on a
--      real bank account are all undone. Do not swap that for a commit.
--
-- What is being proved:
--   1. The opening position does not move. This is the entire safety argument
--      for 086: cashflow_forecast stopped reading account_type = 'Bank' and
--      started reading the 'cash' class, and every cashflow number in the app
--      rests on that being the same set of accounts and the same total.
--   2. The two sets are identical account for account, not merely equal in
--      total — two different accounts with offsetting balances would pass a
--      sum check and be badly wrong.
--   3. cashflow_forecast still executes. A plpgsql function reproduced whole
--      from 071 can fail at runtime rather than at creation.
--   4. The feature actually works: an Other Current Asset account classed
--      'cash' by hand joins the opening position, which was the point.
--   5. The class genuinely governs in both directions: a Bank account
--      overridden away from 'cash' leaves.

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

select case when old_opening = new_opening
       then '1. OPENING POSITION UNCHANGED: PASS'
       else '1. OPENING POSITION UNCHANGED: FAIL — was ' || old_opening::text
            || ', now ' || new_opening::text end as result
from _fx_base;

select case when not exists (
         (select id from qbo_accounts where account_type = 'Bank'
          except select id from v_cash_accounts)
         union all
         (select id from v_cash_accounts
          except select id from qbo_accounts where account_type = 'Bank'))
       then '2. CASH SET IS EXACTLY THE BANK SET: PASS'
       else '2. CASH SET IS EXACTLY THE BANK SET: FAIL — '
            || coalesce((select string_agg(id, ', ') from (
                 (select id from qbo_accounts where account_type = 'Bank'
                  except select id from v_cash_accounts)
                 union all
                 (select id from v_cash_accounts
                  except select id from qbo_accounts where account_type = 'Bank')) d), '?')
       end as result;

select case when (select count(*) from cashflow_forecast(2)) = 2
       then '3. cashflow_forecast STILL RUNS: PASS'
       else '3. cashflow_forecast STILL RUNS: FAIL' end as result;

-- A Stripe balance: real money, and QuickBooks types it Other Current Asset,
-- so account_type = 'Bank' could never have found it. is_operating mirrors the
-- file's current state so inserting it cannot flip the operating_set fallback
-- and move every other account in or out underneath the assertion.
insert into qbo_accounts (id, name, fully_qualified_name, account_type,
                          derived_class, override_class, balance, is_operating)
select '_fx_stripe', '_fx Stripe balance', '_fx Stripe balance', 'Other Current Asset',
       'excluded', 'cash', 500000, (select operating_set from _fx_base);

select case when (select coalesce(sum(balance), 0) from v_cash_accounts
                  where (not exists (select 1 from v_cash_accounts where is_operating)
                         or is_operating))
                 - (select new_opening from _fx_base) = 500000
       then '4. HAND-CLASSED CASH ACCOUNT COUNTS: PASS'
       else '4. HAND-CLASSED CASH ACCOUNT COUNTS: FAIL — opening moved by '
            || ((select coalesce(sum(balance), 0) from v_cash_accounts
                 where (not exists (select 1 from v_cash_accounts where is_operating)
                        or is_operating))
                - (select new_opening from _fx_base))::text || ', expected 500000'
       end as result;

-- and the other direction: the class governs, so overriding a bank account
-- away from 'cash' removes it. Membership only — asserting the opening delta
-- here would depend on whether that one account was the last operating one.
create temp table _fx_out as
select id from qbo_accounts where account_type = 'Bank' order by balance limit 1;
update qbo_accounts set override_class = 'excluded' where id in (select id from _fx_out);

select case when (select count(*) from _fx_out) = 0
              or not exists (select 1 from v_cash_accounts where id in (select id from _fx_out))
       then '5. OVERRIDE REMOVES A BANK FROM CASH: PASS'
       else '5. OVERRIDE REMOVES A BANK FROM CASH: FAIL' end as result;

rollback;
