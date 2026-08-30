-- ============================================================================
--  055 — match v_cost_lines_classified/forecast_page/rev_proj_page's
--  date_trunc('month', issued_on) calls to 053's IMMUTABLE-safe expression.
--
--  053 explains why: issued_on is a date, and unqualified
--  date_trunc('month', issued_on) resolves to date_trunc's STABLE
--  (timestamptz) overload, which can't back an index and — dormant so far,
--  since every session here has used the same TimeZone — could in principle
--  bucket the same row into a different month under a different session
--  TimeZone. Rewriting to date_trunc('month', issued_on::timestamp) forces
--  the IMMUTABLE (plain timestamp) overload; for a date with no time-of-day
--  or zone, this produces the identical calendar month either way, so this
--  is a no-op for every value in the system today, purely enabling the two
--  new indexes to actually be used. Nothing else about any of these three
--  objects changes.
-- ============================================================================

-- v_cost_lines_classified (006): only the `month` column's expression changes.
create or replace view v_cost_lines_classified as
select
  bl.id, bl.bill_id, b.kind, b.vendor_name, b.issued_on,
  date_trunc('month', b.issued_on::timestamp)::date as month,
  bl.account_id, bl.account_name, bl.amount, bl.qbo_project_id,
  coalesce(a.override_class, a.derived_class,
           an.override_class, an.derived_class,
           'other'::cost_class)                          as class,
  (a.id is null and an.id is null)                       as unjoined
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
  'anything above it is a data problem to look at, not to average over. month (055) '
  'uses an explicit ::timestamp cast so it matches bills_month_idx (053).';

-- forecast_page (025): only the inv CTE's two date_trunc calls change.
create or replace function forecast_page(p_from date, p_to date)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
plan as (
  select deal_id, month, gp, billable from v_deal_month_forecast
  where month between p_from and p_to
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on::timestamp)::date between p_from and p_to
),
cost as (
  select month, class, qbo_project_id, account_name, amount
  from v_cost_lines_classified
  where month between p_from and p_to
),
act_projects as (
  select qbo_project_id as id from inv
  union
  select qbo_project_id from cost where qbo_project_id is not null
  union
  select qbo_project_id from deals where qbo_project_id is not null
),
keep_projects as (
  select p.* from qbo_projects p
  where p.hidden = false and (
    p.id in (select id from act_projects)
    or p.id in (select coalesce(q.parent_id, q.id) from qbo_projects q
                where q.id in (select id from act_projects))
    or p.id in (select qbo_customer_id from clients where qbo_customer_id is not null)
  )
)
select jsonb_build_object(
  'plan_month', coalesce((select jsonb_agg(t) from (
      select month, sum(gp)::bigint as gp, sum(billable)::bigint as billable
      from plan group by month) t), '[]'::jsonb),
  'plan_deal', coalesce((select jsonb_agg(t) from (
      select deal_id,
        sum(gp)::bigint as gp_all,
        coalesce(sum(gp) filter (where month < (select m from cur)), 0)::bigint as gp_settled,
        coalesce(sum(billable) filter (where month >= (select m from cur)), 0)::bigint as bill_future
      from plan group by deal_id) t), '[]'::jsonb),
  'rev_month', coalesce((select jsonb_agg(t) from (
      select month, sum(total)::bigint as total from (
        select month, total from inv
        union all
        -- contra-revenue: debits to income-type accounts (search/social media
        -- pass-through offsets) net against invoiced revenue, as QuickBooks does
        select month, -amount as total from cost where class = 'income'
      ) u group by month) t), '[]'::jsonb),
  'rev_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(total)::bigint as total from (
        select qbo_project_id, month, total from inv
        union all
        select qbo_project_id, month, -amount from cost
        where class = 'income' and qbo_project_id is not null
      ) u where month <= (select m from cur) and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'cost_month', coalesce((select jsonb_agg(t) from (
      select month, class, sum(amount)::bigint as total from cost group by month, class) t), '[]'::jsonb),
  'cogs_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(amount)::bigint as total
      from cost where class = 'cogs' and month <= (select m from cur)
        and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(t) from (
      select class, coalesce(account_name, '(no account)') as account,
             sum(amount)::bigint as total
      from cost group by class, account_name) t), '[]'::jsonb),
  'runrates', jsonb_build_object(
      'payroll',  cost_runrate_monthly('payroll'),
      'overhead', cost_runrate_monthly('overhead'),
      'other',    cost_runrate_monthly('other')),
  'projects', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'parent_id', parent_id, 'jobcode', jobcode))
      from keep_projects), '[]'::jsonb)
);
$$ language sql stable;

comment on function forecast_page is
  'The Forecast page''s data, grouped where it lives: one jsonb, one round trip. '
  'Projects are trimmed to the ones the page shows; the editor''s full picker list '
  'loads lazily. inv (055) uses an explicit ::timestamp cast so it matches '
  'invoices_month_idx (053).';

-- rev_proj_page (051): same inv CTE fix, nothing else changes.
create or replace function rev_proj_page(p_from date, p_to date)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on::timestamp)::date between p_from and p_to
),
cost as (
  select month, class, qbo_project_id, amount
  from v_cost_lines_classified
  where month between p_from and p_to
)
select coalesce((select jsonb_agg(t) from (
    select qbo_project_id, sum(total)::bigint as total from (
      select qbo_project_id, month, total from inv
      union all
      -- contra-revenue: debits to income-type accounts (search/social media
      -- pass-through offsets) net against invoiced revenue, same as
      -- forecast_page's rev_proj (025).
      select qbo_project_id, month, -amount from cost
      where class = 'income' and qbo_project_id is not null
    ) u where month <= (select m from cur) and qbo_project_id is not null
    group by qbo_project_id) t), '[]'::jsonb);
$$ language sql stable;

comment on function rev_proj_page is
  'Just forecast_page()''s rev_proj (025), for pages that only need '
  'revenue-per-project and would otherwise pay for the whole Forecast '
  'page''s computation on every load — including three cost_runrate_monthly() '
  'scans that are independent of p_from/p_to and get recomputed for a value '
  'the page never uses. Team Hours (051) is the first caller. Keep this in '
  'lockstep with forecast_page''s own rev_proj by hand, since it is a literal '
  'copy, not a shared call. inv (055) uses an explicit ::timestamp cast so it '
  'matches invoices_month_idx (053).';
