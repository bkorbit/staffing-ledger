-- ============================================================================
--  024 — retainers are flat per month; day-weighting is for media spend only.
--
--  023 pro-rated flat kinds by covered days; the business rule is the opposite:
--  a retainer month bills in full whether the flight enters it on the 1st or the
--  20th. Day-weighting belongs to media budgets — search, social, programmatic —
--  and those carry it in their explicit cells, written day-weighted by the
--  editor's Total Budget spread. The view returns to flat month values for
--  retainer/custom/creative-retainer; explicit overrides still win untouched.
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
  'The commercial plan as money, per deal line per month. Flights carry exact '
  'dates; covered months come from truncating both ends. Flat kinds bill full '
  'months; media budgets carry day-weighting in their cells, written by the '
  'editor''s day-weighted spread.';
