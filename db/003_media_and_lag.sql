-- ============================================================================
--  003 — media funding, and a corrected basis for payment lag
-- ============================================================================

-- ---------------------------------------------------------- media funding --
-- Who actually pays for the media. Almost always the client, who buys search and
-- social directly — so none of it is EMG cash and only the fee ever moves. The
-- exception (On Location's Olympics work) has EMG paying the media on card and
-- invoicing it back, which is invisible in the P&L because it is not revenue, and
-- enormous in cashflow because the money leaves immediately and returns weeks later.
--
-- Defaulted to 'client' so the normal case needs no thought and the exception has to
-- be set deliberately. A one-off that is invisible in the model is exactly the thing
-- that surprises you a year later.
--
-- Programmatic is not covered by this flag: that media always runs through EMG by
-- the nature of the buy, regardless of what this says.
create type media_funding as enum ('client', 'agency');

alter table deals
  add column if not exists media_funding media_funding not null default 'client';

comment on column deals.media_funding is
  'Who pays for search/social media. client = client buys direct, no EMG cash. '
  'agency = EMG pays on card and invoices it back: a cash outflow at spend and an '
  'inflow at collection, neither of which is revenue. Programmatic is always agency-'
  'funded regardless of this flag.';

-- ------------------------------------------------- payment lag, done right --
-- The first cut measured lag per PAYMENT-to-invoice link, which counted a single
-- invoice settled in nine instalments as nine independent observations. Seen Media's
-- two invoices produced nine data points that way and dragged the whole distribution
-- to the right; the p90 of 83 days across the book was overstated as a result.
--
-- The correct unit is the INVOICE, settled when the LAST payment lands. Partly paid
-- invoices are excluded rather than counted early, because a half-paid invoice has no
-- settlement date yet and pretending otherwise biases the figure optimistic.
create view v_invoice_settlement as
select
  i.id                                as invoice_id,
  i.qbo_project_id,
  coalesce(q.parent_id, i.qbo_project_id) as client_key,   -- QuickBooks' own hierarchy
  coalesce(qp.name, q.name, i.qbo_customer_name)           as client_name,
  i.issued_on,
  i.due_on,
  i.total,
  count(p.id)                         as payment_count,
  max(p.paid_on)                      as settled_on,
  sum(p.amount)                       as paid_total,
  max(p.paid_on) - i.issued_on        as days_to_settle,
  max(p.paid_on) - i.due_on           as days_late
from invoices i
join payments p        on p.invoice_id = i.id
left join qbo_projects q  on q.id = i.qbo_project_id
left join qbo_projects qp on qp.id = q.parent_id
where i.balance = 0                    -- fully settled only
  and i.issued_on is not null
group by i.id, i.qbo_project_id, q.parent_id, qp.name, q.name, i.qbo_customer_name,
         i.issued_on, i.due_on, i.total;

comment on view v_invoice_settlement is
  'One row per fully settled invoice, with the date of its LAST payment. The unit for '
  'all payment-behaviour analysis. client_key rolls projects up to their QuickBooks '
  'parent, which is the client — no manual mapping required.';

-- payment_behaviour caches a curve per entity; 'global' is the fallback prior used by
-- clients with too little history of their own.
alter table payment_behaviour drop constraint if exists payment_behaviour_scope_check;
alter table payment_behaviour add constraint payment_behaviour_scope_check
  check (scope in ('client', 'vendor', 'global'));

alter table payment_behaviour
  add column if not exists p90_lag int,
  add column if not exists mean_lag numeric(6,1),
  add column if not exists median_days_late int,
  add column if not exists pct_on_time numeric(5,1);
