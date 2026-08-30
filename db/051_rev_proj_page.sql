-- ============================================================================
--  051 — rev_proj_page: revenue-per-project only, for pages that don't need
--  the rest of forecast_page's payload.
--
--  Team Hours calls forecast_page() purely to get rev_proj (attributing
--  revenue per hour so it can compute each person's profit), but was paying
--  for the WHOLE Forecast page's cost on every load and every quick-range
--  click: plan_month/plan_deal (a join against v_deal_month_forecast),
--  cost_month/cogs_proj/accounts, keep_projects (a multi-union against
--  qbo_projects/clients), and three cost_runrate_monthly() calls that each
--  scan a trailing 6-month window INDEPENDENT of p_from/p_to — the same
--  fixed-cost work redone on every single click for numbers the page never
--  displays. Project Hours has the identical pattern and the identical
--  opportunity, left alone here since only Team Hours asked to be faster.
--
--  This is a literal copy of forecast_page's own rev_proj sub-query (025),
--  not a shared helper both call — a shared function returning a table
--  would itself force a materialization boundary, where a plain inlined
--  copy keeps this one planner-optimized query. Keep the two in lockstep
--  by hand: if this ever disagrees with forecast_page's rev_proj, that's a
--  bug in this migration, not a second opinion on what revenue means.
-- ============================================================================

create or replace function rev_proj_page(p_from date, p_to date)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
inv as (
  select date_trunc('month', issued_on)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on)::date between p_from and p_to
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
  'copy, not a shared call.';
