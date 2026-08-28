-- ============================================================================
--  009 — forward revenue: deal lines become months, months become cash
--
--  The maths ported from the old build, minus its fatal flaw. GP and billable are
--  computed from the COMMERCIAL plan (deal_lines and their per-month overrides) and
--  from nothing else. Assignments and time entries do not appear anywhere below —
--  revenue never reads the operational side.
--
--  Per line kind, per month:
--    retainer       gp = amount            billable = amount            bill 1st
--    hourly         gp = rate x hours      billable = the same          bill last
--    custom         gp = amount            billable = amount            per line
--    search/social  gp = budget x fee%     billable = fee...            bill last
--                   ...plus the media itself when the DEAL is agency-funded: EMG
--                   pays the media out on card in the spend month and invoices it
--                   back, so billable gains the budget while gp does not.
--    programmatic   gp = budget x margin%  (+ fee if set)               bill last
--                   billable = budget + fee — this media always runs through EMG.
--                   margin falls back to the programmatic_margin_default setting.
-- ============================================================================

create or replace view v_deal_month_forecast as
with months as (
  select d.id as deal_id, d.client_id, d.media_funding, d.status,
         d.reviewed_at is not null as reviewed,
         dl.id as deal_line_id, dl.kind, dl.label, dl.billing_day,
         gs.month::date as month,
         coalesce(dlm.amount, dl.amount)  as amount,
         coalesce(dlm.budget, dl.budget)  as budget,
         coalesce(dlm.hours,  dl.hours_per_month) as hours,
         dl.fee_pct,
         coalesce(dl.margin_pct,
           (select (value #>> '{}')::numeric from settings
             where key = 'programmatic_margin_default')) as margin_pct,
         dl.rate
  from deals d
  join deal_lines dl on dl.deal_id = d.id
  cross join lateral generate_series(d.flight_start, d.flight_end, interval '1 month') gs(month)
  left join deal_line_months dlm on dlm.deal_line_id = dl.id and dlm.month = gs.month::date
  where d.status in ('won', 'active')
)
select deal_id, client_id, deal_line_id, kind, label, month, status, reviewed,
       media_funding, billing_day,
  case kind
    when 'retainer'     then amount
    when 'custom'       then amount
    when 'hourly'       then round(rate * hours)::bigint
    when 'search'       then round(budget * fee_pct / 100)::bigint
    when 'social'       then round(budget * fee_pct / 100)::bigint
    when 'programmatic' then round(budget * margin_pct / 100
                               + budget * fee_pct / 100)::bigint
  end as gp,
  case kind
    when 'retainer'     then amount
    when 'custom'       then amount
    when 'hourly'       then round(rate * hours)::bigint
    when 'search'       then round(budget * fee_pct / 100)::bigint
                             + case when media_funding = 'agency' then budget else 0 end
    when 'social'       then round(budget * fee_pct / 100)::bigint
                             + case when media_funding = 'agency' then budget else 0 end
    when 'programmatic' then budget + round(budget * fee_pct / 100)::bigint
  end as billable,
  -- Media EMG pays for out of its own pocket in the spend month. Cash out only;
  -- never revenue. Programmatic media is netted inside QuickBooks bills already
  -- (it is in the COGS run-rate), so only the agency-funded search/social
  -- exception appears here.
  case when kind in ('search', 'social') and media_funding = 'agency'
       then budget else 0 end as agency_media_out
from months;

comment on view v_deal_month_forecast is
  'The commercial plan as money: GP and billable per deal line per month, computed '
  'from deal_lines and deal_line_months only. Nothing here reads assignments or time '
  'entries, by invariant. Cashflow and the Forecast module both read this.';

-- ---------------------------------------------------------------------------
--  Cashflow gains the contracted tier. Return type changes, so drop first.
-- ---------------------------------------------------------------------------
drop function if exists cashflow_forecast(int);

create function cashflow_forecast(weeks int default 13)
returns table (
  week_start        date,
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
    coalesce(i.early,0), coalesce(i.expected,0), coalesce(i.late,0),
    coalesce(ct.early,0), coalesce(ct.expected,0), coalesce(ct.late,0),
    coalesce(bd.due,0), coalesce(pw.amt,0), cogs_week, overhead_week, coalesce(ao.amt,0),
    (opening + sum(coalesce(i.early,0) + coalesce(ct.early,0)
        - coalesce(bd.due,0) - coalesce(pw.amt,0) - cogs_week - overhead_week - coalesce(ao.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.expected,0) + coalesce(ct.expected,0)
        - coalesce(bd.due,0) - coalesce(pw.amt,0) - cogs_week - overhead_week - coalesce(ao.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.late,0) + coalesce(ct.late,0)
        - coalesce(bd.due,0) - coalesce(pw.amt,0) - cogs_week - overhead_week - coalesce(ao.amt,0))
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
  order by w.w_start;
end;
$$ language plpgsql stable;

comment on function cashflow_forecast is
  'Weekly cash position from today, now with the contracted tier: future deal months '
  'become invoices on the billing day and collect on each client''s curve. Open AR and '
  'contracted revenue are reported separately so it is always visible how much of any '
  'week is money already owed versus money still to be billed. Agency-funded media '
  'leaves on card in its spend month. COGS run-rate still covers programmatic media '
  'costs — those flow through QuickBooks bills and were never in this exception.';
