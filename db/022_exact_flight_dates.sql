-- ============================================================================
--  022 — flights carry exact dates; the month spread truncates properly.
--
--  flight_start/flight_end were always DATE columns, but the UI only ever wrote
--  first-of-month values, and v_deal_month_forecast series'd over the raw dates.
--  Feed that a Jan-15 start and it generates the 15th of every month as the
--  month keys — which then fail to join deal_line_months and every month bucket.
--  The series now runs over date_trunc'd ends, so a Jan-15 → Mar-20 flight
--  yields exactly Jan-01, Feb-01, Mar-01.
--
--  Also fixed while the view is open: the 'creative' kind (020) had no case
--  branch, so creative lines produced NULL gp and billable — invisible to the
--  chart and cashflow. Creative bills like a retainer or hourly per its label
--  marker, always on the 1st.
-- ============================================================================

-- the schema itself enforced first-of-month flights; that rule is retired.
-- (constraint names are Postgres defaults for inline checks on deals)
alter table deals drop constraint if exists deals_flight_start_check;
alter table deals drop constraint if exists deals_flight_end_check;

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
  cross join lateral generate_series(
    date_trunc('month', d.flight_start),
    date_trunc('month', d.flight_end),
    interval '1 month') gs(month)
  left join deal_line_months dlm on dlm.deal_line_id = dl.id and dlm.month = gs.month::date
  where d.status in ('won', 'active')
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
  case kind
    when 'retainer'     then amount
    when 'custom'       then amount
    when 'creative'     then case when label like 'creative:hourly%'
                                  then round(rate * hours)::bigint else amount end
    when 'hourly'       then round(rate * hours)::bigint
    when 'search'       then round(budget * fee_pct / 100)::bigint
                             + case when media_funding = 'agency' then budget else 0 end
    when 'social'       then round(budget * fee_pct / 100)::bigint
                             + case when media_funding = 'agency' then budget else 0 end
    when 'programmatic' then budget + round(budget * fee_pct / 100)::bigint
  end as billable,
  case when kind in ('search', 'social') and media_funding = 'agency'
       then budget else 0 end as agency_media_out
from months;

comment on view v_deal_month_forecast is
  'The commercial plan as money: GP and billable per deal line per month, from '
  'deal_lines and deal_line_months only. Flights carry exact dates; the month '
  'spread truncates both ends. Creative bills per its label: retainer-like or '
  'rate x hours.';
