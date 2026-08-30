-- ============================================================================
--  067 — measuring the model against itself
--
--  Two different questions, two different mechanisms:
--
--  1. "Is the payment-behaviour curve honest?" — answerable RIGHT NOW, no
--     waiting required. v_invoice_settlement already holds every invoice that
--     has ever fully settled, with how long it actually took. For each one,
--     v_invoice_settlement_calibration checks it against the CURRENT curve's
--     median/p90 lag: if the curve is well-calibrated, ~50% of invoices should
--     have settled within their median window and ~90% within their p90
--     window. This is in-sample (an invoice's own history helped shape the
--     very curve being checked against it), so a tight fit is partly a
--     mathematical guarantee at the global level rather than proof of
--     forecasting skill — the informative signal is at the CLIENT level,
--     where shrinkage toward the global curve (004) pulls thin-history
--     clients away from their own raw percentiles, and can be genuinely
--     wrong. A true held-out backtest would need curve snapshots over time,
--     which is a larger undertaking than this migration takes on.
--
--  2. "Was the cash-position forecast right?" — cannot be answered yet.
--     qbo_accounts only ever holds the CURRENT balance (each sync overwrites
--     it), so there is no history to check the forecast against. This
--     migration starts collecting one: bank_balance_history records the real
--     operating balance once a day (same "operating banks only, if any are
--     flagged" rule cashflow_forecast() already uses — copied here rather
--     than shared, so this migration never has a reason to touch that
--     function), and forecast_snapshots records what cashflow_forecast()
--     predicted for each future half-month period at the time of that same
--     run. v_forecast_accuracy joins the two once a predicted period's date
--     has actually arrived. It will be empty until real time catches up to
--     the first snapshots — sync-qbo.mjs now takes one on every run, so
--     that's a couple of weeks out, not months.
-- ============================================================================

-- ---------------------------------------------------- 1. curve calibration --

create or replace view v_invoice_settlement_calibration as
select
  s.invoice_id, s.client_key, s.client_name, s.days_to_settle,
  coalesce(cb.median_lag, gb.median_lag) as median_lag,
  coalesce(cb.p90_lag,    gb.p90_lag)    as p90_lag,
  (cb.ref is not null)                                             as has_own_curve,
  (s.days_to_settle <= coalesce(cb.median_lag, gb.median_lag))     as settled_within_median,
  (s.days_to_settle <= coalesce(cb.p90_lag,    gb.p90_lag))        as settled_within_p90
from v_invoice_settlement s
left join payment_behaviour cb on cb.scope = 'client' and cb.ref = s.client_key
left join payment_behaviour gb on gb.scope = 'global'
where s.days_to_settle is not null
  and coalesce(cb.median_lag, gb.median_lag) is not null;

comment on view v_invoice_settlement_calibration is
  'One row per settled invoice: did it clear within the median/p90 window the '
  'CURRENT payment_behaviour curve would give it. Aggregate settled_within_median '
  'toward ~50% and settled_within_p90 toward ~90% is what "well-calibrated" looks '
  'like. In-sample, not a held-out backtest — see migration 067''s header.';

-- ---------------------------------------------------- 2. forecast accuracy --

create table bank_balance_history (
  as_of    date primary key,
  balance  bigint not null,
  taken_at timestamptz not null default now()
);

comment on table bank_balance_history is
  'The real operating cash position, once a day. "Operating" means the same '
  'thing it means to cashflow_forecast(): operating-flagged banks only if any '
  'bank is flagged, otherwise every bank account. Upserted on as_of so a re-run '
  'the same day corrects rather than duplicates.';

create table forecast_snapshots (
  id                    bigint generated always as identity primary key,
  taken_on              date not null default current_date,
  taken_at              timestamptz not null default now(),
  week_start            date not null,
  period_label          text not null,
  position_optimistic   bigint not null,
  position_expected     bigint not null,
  position_conservative bigint not null,
  unique (taken_on, week_start)
);
create index forecast_snapshots_week_idx on forecast_snapshots (week_start);

comment on table forecast_snapshots is
  'What cashflow_forecast() predicted for each future half-month period, taken '
  'once a day. One row per (taken_on, week_start) — a re-run the same day '
  'corrects the prior snapshot rather than duplicating it. week_start ranges '
  'over whatever horizon snapshot_forecast() asks cashflow_forecast() for '
  '(24 periods = 12 months), so most week_starts accumulate many rows, taken on '
  'many different days, before their date actually arrives — v_forecast_accuracy '
  'is where those get compared to what really happened.';

alter table bank_balance_history enable row level security;
create policy bank_balance_history_policy on bank_balance_history
  for all to authenticated using (true) with check (true);

alter table forecast_snapshots enable row level security;
create policy forecast_snapshots_policy on forecast_snapshots
  for all to authenticated using (true) with check (true);

create or replace function snapshot_forecast()
returns void as $$
declare
  operating_set  boolean;
  actual_balance bigint;
begin
  select exists (select 1 from qbo_accounts where account_type = 'Bank' and is_operating)
    into operating_set;
  select coalesce(sum(balance), 0) into actual_balance
  from qbo_accounts
  where account_type = 'Bank' and (not operating_set or is_operating);

  insert into bank_balance_history (as_of, balance)
  values (current_date, actual_balance)
  on conflict (as_of) do update set balance = excluded.balance, taken_at = now();

  insert into forecast_snapshots (taken_on, week_start, period_label,
    position_optimistic, position_expected, position_conservative)
  select current_date, f.week_start, f.period_label,
         f.position_optimistic, f.position_expected, f.position_conservative
  from cashflow_forecast(24) f
  on conflict (taken_on, week_start) do update set
    period_label          = excluded.period_label,
    position_optimistic   = excluded.position_optimistic,
    position_expected     = excluded.position_expected,
    position_conservative = excluded.position_conservative,
    taken_at               = now();
end;
$$ language plpgsql;

comment on function snapshot_forecast is
  'Records today''s real operating balance and cashflow_forecast()''s current '
  'prediction for every period in its 12-month horizon. Called once per '
  'sync-qbo.mjs run (same non-fatal-on-failure pattern as '
  'refresh_payment_behaviour) so the accuracy record builds itself.';

create or replace view v_forecast_accuracy as
select
  s.taken_on, s.week_start, s.period_label,
  (s.week_start - s.taken_on)          as lead_days,
  s.position_optimistic, s.position_expected, s.position_conservative,
  b.as_of                              as actual_as_of,
  b.balance                            as actual_balance,
  (b.balance - s.position_expected)    as miss_expected,
  (b.balance between least(s.position_optimistic, s.position_conservative)
              and greatest(s.position_optimistic, s.position_conservative)) as within_band
from forecast_snapshots s
join lateral (
  -- the target date can land on a weekend/holiday with no sync run that day;
  -- take the first real balance on or within 3 days after it rather than
  -- requiring an exact match
  select bh.as_of, bh.balance
  from bank_balance_history bh
  where bh.as_of between s.week_start and s.week_start + 3
  order by bh.as_of asc
  limit 1
) b on true
where s.week_start <= current_date;

comment on view v_forecast_accuracy is
  'Every past forecast_snapshots row whose target week_start has actually '
  'arrived, joined to the real balance that landed. lead_days is how far ahead '
  'that particular prediction was made — the same week_start shows up many '
  'times at different lead_days as it approached. within_band asks whether '
  'reality landed inside the optimistic/conservative spread at all, which '
  'matters as much as the point miss on position_expected.';
