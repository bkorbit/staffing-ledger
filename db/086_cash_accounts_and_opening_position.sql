-- ============================================================================
--  086 — cash accounts become a class the user owns, and the cashflow opening
--  position reads from that instead of from QuickBooks' account type.
--
--  RUN 085 FIRST. It adds the enum value this migration uses, and Postgres
--  will not allow both in one transaction.
--
--  085's header has the reasoning. This migration does three things:
--
--  1. Bank-typed accounts derive to 'cash'. Retroactive here, and
--     classifyAccount() in scripts/sync-qbo.mjs is changed to match so a
--     newly created bank account classifies correctly without anyone
--     touching it. derived_class is the sync's column, so setting it (rather
--     than override_class) keeps "this is what QuickBooks said" honest and
--     leaves the override column free for the user's own judgement.
--
--  2. v_cash_accounts is the one definition of what counts as money we have.
--     A Stripe balance typed Other Current Asset joins it by being classed
--     'cash' in Settings > Finance; nothing else has to change.
--
--  3. cashflow_forecast reads the opening position from that view. It is
--     reproduced here WHOLE from 071 — the project's rule, and the right one:
--     the body was extracted from 071 programmatically rather than retyped,
--     and only the five lines computing `opening` and `operating_set` differ.
--     Everything else is byte-identical to what is running now.
--
--  EQUIVALENCE. Today every Bank account derives to 'excluded' and nothing
--  else does; after step 1 every Bank account derives to 'cash' and nothing
--  else does. So v_cash_accounts selects exactly the set
--  `account_type = 'Bank'` selected, the is_operating fallback is unchanged,
--  and the opening position cannot move. 086_fixture_test.sql asserts that on
--  real data before and after, rather than asking anyone to take it on faith.
--
--  The one behaviour change is the one that was asked for: an account the
--  user classes 'cash' now counts, and previously could not.
-- ============================================================================

-- 1. QuickBooks' Bank accounts are cash, retroactively and by default.
update qbo_accounts
set derived_class = 'cash'
where account_type = 'Bank'
  and derived_class is distinct from 'cash';

-- 2. The single definition of "money we have".
create or replace view v_cash_accounts as
select a.id, a.name, coalesce(a.fully_qualified_name, a.name) as account,
       a.account_type, a.balance, a.as_of, a.is_operating,
       (a.account_type = 'Bank')                    as is_bank,
       a.override_class is not null                 as is_manual
from qbo_accounts a
where coalesce(a.override_class, a.derived_class) = 'cash';

comment on view v_cash_accounts is
  'Accounts holding money the business can spend — the cashflow opening '
  'position''s only source (086). Membership is the ''cash'' class, not '
  'QuickBooks' account_type: Bank accounts derive into it automatically, and a '
  'Stripe/PayPal/clearing balance QuickBooks types Other Current Asset joins by '
  'being classed cash in Settings > Finance. is_manual marks the ones a person '
  'opted in, as opposed to the ones QuickBooks called Bank. Credit Card '
  'accounts are deliberately absent unless classed by hand — they are negative '
  'cash and have never been in the opening position.';

-- 3. cashflow_forecast (071), whole, with the opening position resourced.

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
    -- due = last day of the spend month + the configured terms (Oct -> Oct 31 + 45d)
    select w.w_start,
      coalesce(sum(greatest(f.billable - f.gp, 0))
        filter (where ((f.month + interval '1 month' - interval '1 day')::date + cogs_due_days)
                between w.w_start and w.w_end), 0)::bigint as amt
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
