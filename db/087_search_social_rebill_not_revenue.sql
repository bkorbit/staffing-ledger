-- ============================================================================
--  087 — EMG-funded search/social media is cash, not revenue.
--
--  WHAT WAS WRONG. When a search or social line is media_funding = 'agency'
--  (EMG pays the platforms on the card and rebills the client), 009 chose to
--  put the whole rebill into `billable`: budget + fee. Every consumer treats
--  `billable` as revenue — the Forecast chart's forward revenue line, the deal
--  table's "value" column, the editor's "Revenue forecast (billed)" row, the
--  Excel export. So a $200k/mo search line showed $200k of revenue it never
--  earned, and the chart's implied forward COGS (billable - gp) grew by the
--  same $200k to cancel it. Net GP was right; both gross lines were fiction.
--
--  It also disagreed with how the measured months already report. EMG books
--  that media pass-through against income-type contra accounts, and 025 nets
--  those out of measured revenue per month and per project. So the SAME dollar
--  was revenue in a forecast month and not revenue once the month closed — the
--  forecast-vs-actual comparison had a built-in step change at the boundary.
--
--  WHAT THIS CHANGES. The rebill leaves revenue and becomes its own column:
--
--    billable      = fee only for agency-funded search/social (== gp)
--    pass_through  = the media rebilled to the client: cash in, never revenue
--
--  Programmatic is deliberately untouched (Boris, explicitly): its media is
--  billed through as real gross revenue, `billable` stays budget + fee, and
--  pass_through is 0 for it. This migration is scoped to search/social with
--  media_funding = 'agency' and to nothing else. Every other kind — retainer,
--  creative, hourly, custom, client-funded search/social — computes exactly
--  the same billable as it did under 058.
--
--  CASH IS UNCHANGED IN TOTAL, and that is the point of the new column rather
--  than a plain deletion: the client really does pay the media back, so it is
--  a real inflow on that client's payment curve, just not a real sale.
--  cashflow_forecast's contracted inflow now sums billable + pass_through,
--  which is byte-identical to the old sum of billable alone. "contracted in"
--  on the Cashflow page keeps meaning "invoices we will raise and collect".
--
--  AND ONE REAL BUG, fixed here because this migration is already rewriting
--  the function that has it. cashflow_forecast has been subtracting agency
--  media from cash TWICE:
--
--    agency_out       sum(agency_media_out)          at month + 14 days
--    contracted_cogs  sum(greatest(billable-gp,0))   at month end + terms
--
--  026 wrote contracted_cogs for programmatic media and described it that way
--  ("shaped deals' actual programmatic media"), but the filter it actually
--  used was `billable > gp`, and for an agency-funded search line billable-gp
--  is precisely the budget. So the same media budget left the bank in two
--  different half-months. It is restricted to kind = 'programmatic' here,
--  which is what its own comment always claimed it was. Forward cash
--  positions improve by one copy of agency-funded search/social media —
--  expect the Cashflow page's "forecast COGS" column to drop and the position
--  to rise. That is the double count going away, not new optimism.
--
--  Client-side twin: revMonth() and the new passMonth() in app/forecast.html
--  mirror the two case expressions below. Habit 4 — change one, change both,
--  same fixture. 087_fixture_test.sql is that fixture.
-- ============================================================================

-- ---------------------------------------------------------------------------
--  Are we even in the right database? `relation "deals" does not exist` is
--  what this migration says when it is pasted into the wrong Supabase project
--  (the retired bdtzpeazcjgnsxodwzpz has cost hours before) or into a session
--  whose search_path does not include public. Neither is a problem with the
--  SQL, and neither is obvious from the error, so ask the question up front
--  and print what would answer it.
-- ---------------------------------------------------------------------------
do $$
begin
  if to_regclass('deals') is null then
    raise exception
      'WRONG DATABASE OR SEARCH_PATH — no `deals` table is visible from here. '
      'database=%, user=%, search_path=%. The right project is '
      'zytmlowigbfchfqcilrr; check the ref in the Supabase URL.',
      current_database(), current_user, current_setting('search_path');
  end if;
end $$;

create or replace view v_deal_month_forecast as
with months as (
  select d.id as deal_id, d.client_id, d.status,
         d.reviewed_at is not null as reviewed,
         dl.id as deal_line_id, dl.kind, dl.label, dl.billing_day, dl.media_funding,
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
  cross join lateral generate_series(
    date_trunc('month', d.flight_start),
    date_trunc('month', d.flight_end),
    interval '1 month') gs(month)
  left join deal_line_months dlm on dlm.deal_line_id = dl.id and dlm.month = gs.month::date
  where d.status in ('won', 'active') and not d.hidden
)
select deal_id, client_id, deal_line_id, kind, label, month, status, reviewed,
       media_funding, billing_day,
  case kind
    when 'retainer'     then amount
    when 'custom'       then amount
    when 'creative'     then case when label like 'creative:hourly%'
                                  then round(rate * hours)::bigint else amount end
    when 'hourly'       then round(rate * hours)::bigint
    when 'search'       then round(budget * fee_pct / 100)::bigint
    when 'social'       then round(budget * fee_pct / 100)::bigint
    when 'programmatic' then round(budget * margin_pct / 100
                               + budget * fee_pct / 100)::bigint
  end as gp,
  -- REVENUE. 087: agency-funded search/social bill their fee and nothing else
  -- — the media they rebill is pass_through below, not a sale. Programmatic
  -- still bills its media through as gross revenue, by decision.
  case kind
    when 'retainer'     then amount
    when 'custom'       then amount
    when 'creative'     then case when label like 'creative:hourly%'
                                  then round(rate * hours)::bigint else amount end
    when 'hourly'       then round(rate * hours)::bigint
    when 'search'       then round(budget * fee_pct / 100)::bigint
    when 'social'       then round(budget * fee_pct / 100)::bigint
    when 'programmatic' then budget + round(budget * fee_pct / 100)::bigint
  end as billable,
  case when kind in ('search', 'social') and media_funding = 'agency'
       then budget else 0 end as agency_media_out,
  -- CASH IN, NOT REVENUE. The media EMG fronts and invoices straight back:
  -- collected on the client's payment curve, netted against invoiced revenue
  -- by the contra accounts (025) once the month closes, and never counted as
  -- a sale in either direction. Same rows and same amount as
  -- agency_media_out, but they are two different events — this one is the
  -- client's money arriving, that one is the card being charged — and the
  -- cashflow times them independently.
  --
  -- It goes LAST, after agency_media_out, and must stay there: `create or
  -- replace view` can only APPEND columns. Slotting it in beside its twin,
  -- where it reads better, fails outright with "cannot change name of view
  -- column agency_media_out to pass_through".
  case when kind in ('search', 'social') and media_funding = 'agency'
       then budget else 0 end as pass_through
from months;

comment on view v_deal_month_forecast is
  'The commercial plan as money, per deal line per month. Flights carry exact '
  'dates; covered months come from truncating both ends. Flat kinds bill full '
  'months; media budgets carry day-weighting in their cells, written by the '
  'editor''s day-weighted spread. media_funding (027) is read per line, not '
  'per deal — a deal can mix client-funded and agency-funded media lines. '
  'Hidden deals are excluded (058). billable is REVENUE and, since 087, '
  'excludes the media an agency-funded search/social line rebills: that money '
  'is pass_through — invoiced to the client and collected as cash, netted out '
  'of measured revenue by the contra accounts (025), never a sale. '
  'Programmatic is the deliberate exception: its media bills through as gross '
  'revenue inside billable, and its pass_through is 0. agency_media_out is '
  'the other leg of the same pass-through, the card being charged. Anything '
  'summing this view for revenue wants billable; for cash it wants billable + '
  'pass_through.';

-- ----------------------------------------------------------------------------
--  cashflow_forecast, reproduced WHOLE from 086 (the project's rule). Exactly
--  two things differ, both marked `087` below:
--    1. contracted_src sums billable + pass_through, so the rebill still
--       collects as cash now that it has left `billable`. Identical total to
--       what 086 computed.
--    2. contracted_cogs is restricted to kind = 'programmatic', ending the
--       double count of agency-funded search/social media.
--  Everything else — the half-month calendar, open-AR expectations, bills,
--  the bottoms-up payroll cadence, health, bonuses, the three running
--  positions and every LEFT JOIN — is byte-identical to 086.
-- ----------------------------------------------------------------------------

create or replace function cashflow_forecast(periods int default 12)
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
  -- programmatic/forecast COGS terms: due N days after the last day of the spend
  -- month. Human-owned setting, default 45.
  cogs_due_days int := coalesce((select (value #>> '{}')::int from settings
                                 where key = 'programmatic_cogs_due_days'), 45);
  overhead_week bigint := round(cost_runrate_monthly('overhead') / 2.0);
  loose_week    bigint := round(payroll_loose_runrate() / 2.0);
begin
  -- 086: what counts as cash is now a class, not a QuickBooks account type,
  -- and lives in v_cash_accounts so this is the last function that has to know.
  select exists (select 1 from v_cash_accounts where is_operating)
    into operating_set;
  select coalesce(sum(balance), 0) into opening
  from v_cash_accounts
  where not operating_set or is_operating;

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
    -- 087: what gets INVOICED, which is revenue plus the media an agency-funded
    -- search/social line rebills. pass_through left `billable` when it stopped
    -- being revenue; it never left the invoice, so it must not leave the cash.
    select (f.billable + f.pass_through) as billable,
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
      and f.billable + f.pass_through > 0
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
    -- due = last day of the spend month + the configured terms (Oct -> Oct 31 + 45d)
    -- 087: programmatic ONLY. 026 wrote this term for programmatic media and
    -- said so, but filtered on `billable > gp`, which also caught every
    -- agency-funded search/social month — whose media was ALSO leaving via
    -- agency_out below. That was the same budget subtracted from cash twice.
    select w.w_start,
      coalesce(sum(greatest(f.billable - f.gp, 0))
        filter (where ((f.month + interval '1 month' - interval '1 day')::date + cogs_due_days)
                between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join (select * from v_deal_month_forecast
                          where kind = 'programmatic'
                            and billable > gp
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
  -- base salary + statutory burden, on the existing semi-monthly cadence
  -- (15th, month-end) — half of THAT MONTH's bottoms-up total per run,
  -- not a flat GL-trailing-average disconnected from the Forecast chart.
  payroll_runs as (
    select d::date as pay_on, date_trunc('month', d)::date as month from (
      select (date_trunc('month', current_date) + make_interval(months => m) + interval '14 days') as d
      from generate_series(0, (periods / 2) + 2) m
      union all
      select (date_trunc('month', current_date) + make_interval(months => m + 1) - interval '1 day')
      from generate_series(0, (periods / 2) + 2) m
    ) x where d::date >= current_date
  ),
  payroll_wk as (
    select w.w_start,
      coalesce((
        select round(staff_base_labor_forecast_month(p.month) / 2.0)
        from payroll_runs p where p.pay_on between w.w_start and w.w_end
        limit 1
      ), 0)::bigint as amt
    from wk w
  ),
  -- health insurance: one lump on the 1st of the month (H1 always starts on
  -- the 1st), never split
  health_wk as (
    select w.w_start,
      case when extract(day from w.w_start) = 1
           then health_insurance_forecast_month(w.w_start)
           else 0 end::bigint as amt
    from wk w
  ),
  -- each scheduled bonus on its own date — a bonus check happens once, it
  -- doesn't get smeared across the month like the flat categories
  bonus_wk as (
    select w.w_start,
      coalesce(sum(staff_bonus_burdened_cost(b.id))
        filter (where b.pay_date between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join staff_bonuses b
    group by w.w_start
  ),
  payroll_runs_out as (
    select pw.w_start, (coalesce(pw.amt,0) + loose_week + coalesce(hw.amt,0) + coalesce(bw.amt,0))::bigint as total
    from payroll_wk pw
    left join health_wk hw on hw.w_start = pw.w_start
    left join bonus_wk bw on bw.w_start = pw.w_start
  )
  select
    w.w_start,
    trim(to_char(w.w_start, 'Mon')) || ' H' ||
      (case when extract(day from w.w_start) = 1 then '1' else '2' end) ||
      ' ' || to_char(w.w_start, 'YY'),
    coalesce(i.early,0), coalesce(i.expected,0), coalesce(i.late,0),
    coalesce(ct.early,0), coalesce(ct.expected,0), coalesce(ct.late,0),
    coalesce(bd.due,0), coalesce(pr.total,0), overhead_week, coalesce(ao.amt,0), coalesce(cc.amt,0),
    (opening + sum(coalesce(i.early,0) + coalesce(ct.early,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.expected,0) + coalesce(ct.expected,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.late,0) + coalesce(ct.late,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint
  -- LEFT JOINs with coalesce: any of these CTEs is legitimately empty on a given
  -- day (no open AR, no future deal months, no unpaid bills), and an inner join
  -- would silently return no forecast at all — the worst possible failure shape.
  from wk w
  left join inflow i          on i.w_start  = w.w_start
  left join contracted ct     on ct.w_start = w.w_start
  left join bills_due bd      on bd.w_start = w.w_start
  left join payroll_runs_out pr on pr.w_start = w.w_start
  left join agency_out ao     on ao.w_start = w.w_start
  left join contracted_cogs cc on cc.w_start = w.w_start
  order by w.w_start;
end;
$$ language plpgsql stable;

comment on function cashflow_forecast is
  'Half-month cash position (016) from open AR on per-client payment curves, '
  'contracted future deal-months invoiced on their billing day, bills, '
  'bottoms-up payroll/health/bonuses (071) and media cost. Opening position '
  'comes from v_cash_accounts (086). Since 087 the contracted inflow is '
  'billable + pass_through — the media an agency-funded search/social line '
  'rebills is collected as cash even though it is no longer revenue — and '
  'out_contracted_cogs is programmatic media only, which is what 026 always '
  'said it was: filtering on billable > gp instead of on the kind meant '
  'agency-funded search/social media was subtracted from cash twice, once '
  'here and once in out_agency_media.';
