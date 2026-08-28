-- ============================================================================
--  016 — the cashflow paced in calendar half-months.
--
--  Buckets become H1 (1st..15th) and H2 (16th..month end), starting with the half
--  that contains today. Every flow already filtered `between w_start and w_end`,
--  so re-defining the windows re-paces everything: AR on its curves, contracted
--  revenue and its implied COGS, agency media, bills on due dates. Payroll's two
--  runs land one per half naturally; the cogs/overhead run-rates become
--  half-month rates. period_label carries 'Jul H1 26' for the page.
-- ============================================================================

drop function if exists cashflow_forecast(int);

create function cashflow_forecast(periods int default 12)
returns table (
  week_start        date,
  period_label      text,
  cash_in_early     bigint,
  cash_in_expected  bigint,
  cash_in_late      bigint,
  in_contracted_early    bigint,
  in_contracted_expected bigint,
  in_contracted_late     bigint,
  out_bills         bigint,
  out_payroll       bigint,
  out_cogs_runrate  bigint,
  out_overhead      bigint,
  out_agency_media  bigint,
  out_contracted_cogs bigint,
  position_optimistic   bigint,
  position_expected     bigint,
  position_conservative bigint
) as $$
declare
  opening       bigint;
  operating_set boolean;
  payroll_month bigint := cost_runrate_monthly('payroll');
  cogs_week     bigint := round(cost_runrate_monthly('cogs')     / 2.0);   -- per half-month
  overhead_week bigint := round(cost_runrate_monthly('overhead') / 2.0);
begin
  select exists (select 1 from qbo_accounts where account_type = 'Bank' and is_operating)
    into operating_set;
  select coalesce(sum(balance), 0) into opening
  from qbo_accounts
  where account_type = 'Bank' and (not operating_set or is_operating);

  return query
  -- calendar half-months: H1 = 1st..15th, H2 = 16th..month end, starting with the
  -- half that contains today, exactly `periods` of them
  with wk as (
    select h.w_start,
           case when extract(day from h.w_start) = 1
                then (h.w_start + interval '14 days')::date
                else (date_trunc('month', h.w_start) + interval '1 month' - interval '1 day')::date
           end as w_end
    from (
      select unnest(array[ m.m0, (m.m0 + interval '15 days')::date ]) as w_start
      from (select (date_trunc('month', current_date) + make_interval(months => g))::date as m0
            from generate_series(0, (periods / 2) + 1) g) m
    ) h
    where case when extract(day from h.w_start) = 1
               then (h.w_start + interval '14 days')::date
               else (date_trunc('month', h.w_start) + interval '1 month' - interval '1 day')::date
          end >= current_date
    order by h.w_start
    limit periods
  ),
  -- open AR, as before
  inflow as (
    select w.w_start,
      coalesce(sum(e.balance) filter (where e.expect_early  between w.w_start and w.w_end), 0)::bigint as early,
      coalesce(sum(e.balance) filter (where e.expect_median between w.w_start and w.w_end), 0)::bigint as expected,
      coalesce(sum(e.balance) filter (where e.expect_late   between w.w_start and w.w_end), 0)::bigint as late
    from wk w cross join v_open_invoice_expectations e
    group by w.w_start
  ),
  -- contracted: future deal months become expected invoices on the billing day,
  -- collected on the client's curve. Months already begun are excluded — their
  -- invoices either exist (open AR above) or are imminent and arrive next sync.
  contracted_src as (
    select f.billable,
      case f.billing_day
        when 'first' then f.month
        else (f.month + interval '1 month' - interval '1 day')::date
      end as invoice_on,
      coalesce(cb.p25_lag,  gb.p25_lag, 30)  as p25,
      coalesce(cb.median_lag, gb.median_lag, 35) as p50,
      coalesce(cb.p90_lag,  gb.p90_lag, 80)  as p90
    from v_deal_month_forecast f
    join clients c on c.id = f.client_id
    left join payment_behaviour cb on cb.scope = 'client' and cb.ref = c.qbo_customer_id
    left join payment_behaviour gb on gb.scope = 'global'
    where f.month > date_trunc('month', current_date)::date
      and f.billable > 0
  ),
  contracted as (
    select w.w_start,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p25 between w.w_start and w.w_end), 0)::bigint as early,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p50 between w.w_start and w.w_end), 0)::bigint as expected,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p90 between w.w_start and w.w_end), 0)::bigint as late
    from wk w cross join contracted_src s
    group by w.w_start
  ),
  -- agency-funded media leaves on card mid-spend-month
  -- the cost contracted months imply (billable - gp), paid mid spend month —
  -- forecast programmatic media is cash leaving, same timing as agency media
  contracted_cogs as (
    select w.w_start,
      coalesce(sum(greatest(f.billable - f.gp, 0))
        filter (where (f.month + 14) between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join (select * from v_deal_month_forecast
                          where billable > gp
                            and month > date_trunc('month', current_date)::date) f
    group by w.w_start
  ),
  agency_out as (
    select w.w_start,
      coalesce(sum(f.agency_media_out)
        filter (where (f.month + 14) between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join (select * from v_deal_month_forecast
                          where agency_media_out > 0
                            and month >= date_trunc('month', current_date)::date) f
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
    select d::date as pay_on from (
      select (date_trunc('month', current_date) + make_interval(months => m) + interval '14 days') as d
      from generate_series(0, (periods / 2) + 2) m
      union all
      select (date_trunc('month', current_date) + make_interval(months => m + 1) - interval '1 day')
      from generate_series(0, (periods / 2) + 2) m
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
    trim(to_char(w.w_start, 'Mon')) || ' H' ||
      (case when extract(day from w.w_start) = 1 then '1' else '2' end) ||
      ' ' || to_char(w.w_start, 'YY'),
    coalesce(i.early,0), coalesce(i.expected,0), coalesce(i.late,0),
    coalesce(ct.early,0), coalesce(ct.expected,0), coalesce(ct.late,0),
    coalesce(bd.due,0), coalesce(pw.amt,0), cogs_week, overhead_week, coalesce(ao.amt,0), coalesce(cc.amt,0),
    (opening + sum(coalesce(i.early,0) + coalesce(ct.early,0)
        - coalesce(bd.due,0) - coalesce(pw.amt,0) - cogs_week - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.expected,0) + coalesce(ct.expected,0)
        - coalesce(bd.due,0) - coalesce(pw.amt,0) - cogs_week - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.late,0) + coalesce(ct.late,0)
        - coalesce(bd.due,0) - coalesce(pw.amt,0) - cogs_week - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint
  -- LEFT joins with coalesce: any of these CTEs is legitimately empty on a given
  -- day (no open AR, no future deal months, no unpaid bills), and an inner join
  -- would silently return no forecast at all — the worst possible failure shape.
  from wk w
  left join inflow i      on i.w_start  = w.w_start
  left join contracted ct on ct.w_start = w.w_start
  left join bills_due bd  on bd.w_start = w.w_start
  left join payroll_wk pw on pw.w_start = w.w_start
  left join agency_out ao on ao.w_start = w.w_start
  left join contracted_cogs cc on cc.w_start = w.w_start
  order by w.w_start;
end;
$$ language plpgsql stable;

comment on function cashflow_forecast is
  'Half-month cash position in three bands. periods counts halves (12 = six '
  'months). H1 = 1st..15th, H2 = 16th..month end; the first period is the half '
  'containing today.';
