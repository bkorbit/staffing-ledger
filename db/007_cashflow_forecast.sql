-- ============================================================================
--  007 — the cashflow forecast
--
--  Always starts today, from the real bank position. Three bands, because the
--  measured book says the risk is in the spread: median settlement is 35 days and
--  only 3 past terms, but the p90 sits at 80. A single expected line would look
--  right in aggregate and miss exactly the weeks that hurt.
--
--  Money in:  open invoices, dated by each client's observed collection curve
--             (shrunk toward the global curve where history is thin).
--  Money out: known open bills on their due dates; payroll on the 15th and last
--             day at half the trailing monthly average; COGS and overhead as
--             six-month category run-rates spread across the weeks.
--
--  Forward revenue from deals joins this later — the structure already has its
--  seat (the 'contracted' tier), it is simply empty until deals exist.
-- ============================================================================

-- Each open invoice with its expected settlement dates under three assumptions.
-- Conditioning on "still unpaid": a date the curve puts in the past is floored to
-- the near future rather than pretending the money already arrived.
create or replace view v_open_invoice_expectations as
with curve as (
  select i.id as invoice_id,
         i.qbo_customer_name,
         i.issued_on, i.due_on, i.balance,
         coalesce(q.parent_id, i.qbo_project_id) as client_key,
         coalesce(cb.p25_lag,  gb.p25_lag)  as p25,
         coalesce(cb.median_lag, gb.median_lag) as p50,
         coalesce(cb.p90_lag,  gb.p90_lag)  as p90,
         (cb.ref is not null)               as has_own_curve
  from invoices i
  left join qbo_projects q on q.id = i.qbo_project_id
  left join payment_behaviour cb on cb.scope = 'client'
                                and cb.ref = coalesce(q.parent_id, i.qbo_project_id)
  left join payment_behaviour gb on gb.scope = 'global'
  where i.balance > 0 and i.excluded is not true
)
select invoice_id, qbo_customer_name, client_key, issued_on, due_on, balance,
       has_own_curve,
       greatest(issued_on + coalesce(p25, 30), current_date + 2)  as expect_early,
       greatest(issued_on + coalesce(p50, 35), current_date + 5)  as expect_median,
       greatest(issued_on + coalesce(p90, 80), current_date + 14) as expect_late
from curve;

-- Trailing category run-rate over the last N COMPLETE months. The current partial
-- month is excluded: averaging over it would understate every category on the 3rd
-- of the month and flatter the forecast, which is the wrong direction to be wrong.
create or replace function cost_runrate_monthly(p_class cost_class, months int default 6)
returns bigint as $$
  select coalesce(round(sum(amount)::numeric / greatest(months, 1))::bigint, 0)
  from v_cost_lines_classified
  where class = p_class
    and issued_on >= date_trunc('month', current_date) - make_interval(months => months)
    and issued_on <  date_trunc('month', current_date);
$$ language sql stable;

-- The forecast itself. One row per week from today.
create or replace function cashflow_forecast(weeks int default 13)
returns table (
  week_start        date,
  cash_in_early     bigint,
  cash_in_expected  bigint,
  cash_in_late      bigint,
  out_bills         bigint,
  out_payroll       bigint,
  out_cogs_runrate  bigint,
  out_overhead      bigint,
  position_optimistic   bigint,
  position_expected     bigint,
  position_conservative bigint
) as $$
declare
  opening       bigint;
  operating_set boolean;
  payroll_month bigint := cost_runrate_monthly('payroll');
  cogs_week     bigint := round(cost_runrate_monthly('cogs')     * 12.0 / 52);
  overhead_week bigint := round(cost_runrate_monthly('overhead') * 12.0 / 52);
begin
  -- Opening position: the bank accounts a human ticked as operating. Until any are
  -- ticked, every bank account counts, so the first run shows something real rather
  -- than starting from zero — but ticking them in Settings is the intended state.
  select exists (select 1 from qbo_accounts where account_type = 'Bank' and is_operating)
    into operating_set;
  select coalesce(sum(balance), 0) into opening
  from qbo_accounts
  where account_type = 'Bank' and (not operating_set or is_operating);

  return query
  with wk as (
    select (current_date + (g * 7))::date as w_start,
           (current_date + (g * 7) + 6)::date as w_end
    from generate_series(0, weeks - 1) g
  ),
  inflow as (
    select w.w_start,
      coalesce(sum(e.balance) filter (where e.expect_early  between w.w_start and w.w_end), 0)::bigint as early,
      coalesce(sum(e.balance) filter (where e.expect_median between w.w_start and w.w_end), 0)::bigint as expected,
      coalesce(sum(e.balance) filter (where e.expect_late   between w.w_start and w.w_end), 0)::bigint as late
    from wk w cross join v_open_invoice_expectations e
    group by w.w_start
  ),
  bills_due as (
    select w.w_start,
      coalesce(sum(b.balance) filter (where greatest(coalesce(b.due_on, current_date), current_date)
                                      between w.w_start and w.w_end), 0)::bigint as due
    from wk w cross join (select * from bills where balance > 0) b
    group by w.w_start
  ),
  payroll_runs as (
    -- the 15th and the last day of each month in the horizon, each half a month
    select d::date as pay_on from (
      select (date_trunc('month', current_date) + make_interval(months => m) + interval '14 days') as d
      from generate_series(0, (weeks * 7 / 28) + 2) m
      union all
      select (date_trunc('month', current_date) + make_interval(months => m + 1) - interval '1 day')
      from generate_series(0, (weeks * 7 / 28) + 2) m
    ) x where d::date >= current_date
  ),
  payroll_wk as (
    select w.w_start,
      coalesce(count(p.pay_on) * (payroll_month / 2), 0)::bigint as amt
    from wk w left join payroll_runs p on p.pay_on between w.w_start and w.w_end
    group by w.w_start
  )
  select
    w.w_start,
    i.early, i.expected, i.late,
    bd.due,
    pw.amt,
    cogs_week,
    overhead_week,
    (opening + sum(i.early    - bd.due - pw.amt - cogs_week - overhead_week)
                over (order by w.w_start))::bigint,
    (opening + sum(i.expected - bd.due - pw.amt - cogs_week - overhead_week)
                over (order by w.w_start))::bigint,
    (opening + sum(i.late     - bd.due - pw.amt - cogs_week - overhead_week)
                over (order by w.w_start))::bigint
  from wk w
  join inflow i     on i.w_start = w.w_start
  join bills_due bd on bd.w_start = w.w_start
  join payroll_wk pw on pw.w_start = w.w_start
  order by w.w_start;
end;
$$ language plpgsql stable;

comment on function cashflow_forecast is
  'Weekly cash position from today. Inflows are open invoices dated by observed '
  'collection curves; outflows are open bills on due dates, payroll semi-monthly at '
  'the trailing average, and COGS/overhead as six-month run-rates. The conservative '
  'line dates every receipt at its client''s p90 — the trough on that line is the '
  'number to plan around. Forward deal revenue joins this once deals exist.';
