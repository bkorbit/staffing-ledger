-- ============================================================================
--  005 — the chart of accounts, and cost classification without the old rules
--
--  The previous system carried hand-built tables deciding which accounts were COGS,
--  which were overhead and which to ignore. That was real work, and it lived only in
--  the old database.
--
--  It turns out most of it need not be hand-built at all: QuickBooks already types
--  every account. AccountType is 'Cost of Goods Sold', 'Expense', 'Other Expense',
--  'Income' and so on, which is the same split those rules encoded. Pull the chart of
--  accounts and the classification arrives with it.
--
--  Human judgement is then reduced to overriding the exceptions, stored right beside
--  the derived value so the two never drift apart and it is always obvious which is
--  which.
-- ============================================================================

create type cost_class as enum ('cogs', 'overhead', 'payroll', 'income', 'other', 'excluded');

create table qbo_accounts (
  id                   text primary key,
  name                 text not null,
  fully_qualified_name text,
  account_type         text,          -- QuickBooks' own, e.g. 'Cost of Goods Sold'
  account_sub_type     text,
  parent_id            text,
  active               boolean not null default true,
  balance              bigint not null default 0,
  as_of                date,

  -- Derived from account_type by the sync. Never hand-edited: an override goes in
  -- the column below, so the source classification stays visible for comparison.
  derived_class        cost_class,

  -- Human override. Null means the derived value applies. This is the whole of the
  -- judgement that used to need its own set of rule tables.
  override_class       cost_class,
  override_reason      text,
  override_by          text,
  override_at          timestamptz,

  -- Which bank accounts count toward the cashflow opening position. Never written
  -- by the sync, so a re-run cannot clobber the choice.
  is_operating         boolean not null default false,

  synced_at            timestamptz not null default now()
);
create index qbo_accounts_type_idx on qbo_accounts (account_type);

alter table qbo_accounts enable row level security;
create policy qbo_accounts_auth_all on qbo_accounts
  for all to authenticated using (true) with check (true);

-- The effective classification: override where a human set one, else QuickBooks'.
create view v_account_class as
select id, name, fully_qualified_name, account_type, account_sub_type,
       coalesce(override_class, derived_class) as class,
       override_class is not null              as is_overridden,
       derived_class, override_class, override_reason,
       balance, is_operating, active
from qbo_accounts;

-- cash_accounts was a bank-only table. It becomes a view over the full chart so there
-- is one source for accounts and the cashflow opening position is simply a filter.
drop table if exists cash_accounts cascade;
create view cash_accounts as
select id, name, account_type, balance, as_of, is_operating, synced_at
from qbo_accounts
where account_type = 'Bank';

-- Every expense line with its effective classification. The basis for the run-rate
-- money-out model: six months trailing by category, projected forward.
create view v_cost_lines_classified as
select
  bl.id, bl.bill_id, b.kind, b.vendor_name, b.issued_on,
  date_trunc('month', b.issued_on)::date as month,
  bl.account_name, bl.amount, bl.qbo_project_id,
  coalesce(a.override_class, a.derived_class, 'other'::cost_class) as class
from bill_lines bl
join bills b on b.id = bl.bill_id
left join qbo_accounts a on a.fully_qualified_name = bl.account_name
                         or a.name = bl.account_name;

comment on view v_cost_lines_classified is
  'Expense lines with an effective cost class. Joined on account NAME because that is '
  'all the line records; if QuickBooks account names are not unique this needs the id '
  'carried through the sync instead.';
