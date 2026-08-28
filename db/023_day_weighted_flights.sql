-- ============================================================================
--  023 — partial flight months carry their day-weight.
--
--  A flight starting Jan 15 covers 17 of January's 31 days; a retainer month
--  should pay 17/31 of its amount, not the full month. The view now computes
--  each month's covered-day fraction and pro-rates the FLAT kinds by it —
--  retainer, custom, creative-retainer — wherever the month value falls back to
--  the line default. An explicit deal_line_months override is a human's number
--  and is never scaled.
--
--  Budget kinds (search/social/programmatic) and hourly read explicit cells, so
--  their day-weighting happens where the cells are written: the Total Budget
--  spread in the editor allocates by covered days. Hourly's hrs/mo default
--  stays flat by design — hours are an explicit quantity, not a rate over time.
-- ============================================================================

create or replace view v_deal_month_forecast as
with months as (
  select d.id as deal_id, d.client_id, d.media_funding, d.status,
         d.reviewed_at is not null as reviewed,
         dl.id as deal_line_id, dl.kind, dl.label, dl.billing_day,
         gs.month::date as month,
         -- covered days in this month / days in this month
         ( least(d.flight_end,   (gs.month + interval '1 month - 1 day')::date)
         - greatest(d.flight_start, gs.month::date) + 1 )::numeric
         / extract(day from (gs.month + interval '1 month - 1 day'))::numeric
           as day_frac,
         dlm.amount  as dlm_amount,  dl.amount  as dl_amount,
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
), shaped as (
  select *,
    -- flat kinds pro-rate the LINE default by covered days; explicit overrides don't scale
    coalesce(dlm_amount, round(dl_amount * day_frac)::bigint) as amount
  from months
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
from shaped;

comment on view v_deal_month_forecast is
  'The commercial plan as money, per deal line per month. Flights carry exact '
  'dates: covered months come from truncating both ends, and flat kinds pro-rate '
  'partial months by covered days. Explicit month overrides are never scaled.';
