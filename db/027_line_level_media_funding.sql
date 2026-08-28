-- ============================================================================
--  027 — Media funding moves from the whole deal to the specific line.
--
--  media_funding (003) was one flag on `deals`, applied uniformly to every
--  search/social line in that deal. Real deals don't always work that way —
--  a deal can carry paid social that the client funds directly alongside paid
--  search that EMG funds and rebills. A deal-level flag can't represent a
--  mixed deal; it forces one line's funding onto the other.
--
--  Moves the flag onto deal_lines, where it was always conceptually scoped
--  anyway — v_deal_month_forecast already only reads it for kind in
--  ('search','social'); programmatic is always agency-funded regardless of
--  this flag, per 003's own comment, and retainer/creative/hourly/custom
--  never read it at all.
--
--  Backfill preserves every deal's current computed forecast exactly: an
--  existing agency-funded deal's search/social lines become agency-funded
--  per-line; everything else defaults to 'client' (unchanged, since 'client'
--  was already the default and the common case).
-- ============================================================================

alter table deal_lines
  add column if not exists media_funding media_funding not null default 'client';

update deal_lines dl
set media_funding = 'agency'
from deals d
where dl.deal_id = d.id
  and dl.kind in ('search', 'social')
  and d.media_funding = 'agency';

comment on column deal_lines.media_funding is
  'Who pays for THIS LINE''s media — only meaningful for search/social. '
  'client = client buys direct, no EMG cash. agency = EMG pays on card and '
  'invoices it back: a cash outflow at spend and an inflow at collection, '
  'neither of which is revenue. Programmatic is always agency-funded '
  'regardless of this flag. Replaces deals.media_funding (027) — a deal-level '
  'flag couldn''t represent a deal with mixed-funding lines.';

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
  'editor''s day-weighted spread. media_funding (027) is read per line, not '
  'per deal — a deal can mix client-funded and agency-funded media lines.';

-- Nothing reads the deal-level flag anymore.
alter table deals drop column if exists media_funding;
