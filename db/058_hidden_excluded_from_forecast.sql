-- ============================================================================
--  058 — hidden deals stop leaking into the forecast plan.
--
--  019 documented the promise: "hidden removes a deal from the forecast's
--  table AND its plan from the chart." It never did the second half.
--  v_deal_month_forecast (027's definition, unchanged since) filters
--  `d.status in ('won','active')` but never checks `d.hidden` — so a hidden
--  deal's plan money still flowed into plan_month/plan_deal, the
--  company-wide aggregate totals every page's chart and KPI ribbon sum from,
--  even though the deal itself is invisible everywhere else. Found auditing
--  the Mediaplus matching saga; a real, silent, pre-existing money-
--  correctness bug, unrelated to that saga's actual cause.
--
--  Nothing else changes: same case expressions, same columns, same joins —
--  one added condition in the `months` CTE's where clause. No client-side
--  change needed — app/forecast.html already fetches deals with
--  `.eq('hidden', false)`, so hidden deals never entered client-side row or
--  chart aggregation; only this server-side view was leaking. Every
--  forecast_page() consumer (index, sales, cashflow, client-profitability,
--  team-hours) gets the fix for free the moment this view changes.
-- ============================================================================

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
  'editor''s day-weighted spread. media_funding (027) is read per line, not '
  'per deal — a deal can mix client-funded and agency-funded media lines. '
  'Hidden deals are excluded (058) — hidden means gone from the plan, not '
  'just gone from the table.';

-- Preview only — run this after the view change to confirm the leak is
-- closed: every hidden deal should now show zero rows here.
-- select * from v_deal_month_forecast f join deals d on d.id = f.deal_id where d.hidden;
