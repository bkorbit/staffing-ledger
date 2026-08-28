-- ============================================================================
--  014 — the programmatic margin, exactly as defined:
--
--    Programmatic Margin = (Programmatic Media revenue − COGS Media) / Programmatic Media revenue
--
--  Revenue side: INVOICE LINES whose item is named like programmatic (fee items
--  excluded) — already mirrored nightly into invoice_lines since 001.
--  Cost side: cogs-class bill lines on media-named, non-fee accounts (as 013).
--  Both aggregate per QuickBooks parent BEFORE joining (013's lesson holds).
-- ============================================================================

create or replace view v_client_achieved_margin as
with prog_rev as (
  select coalesce(p.parent_id, p.id) as parent,
         sum(il.amount)              as revenue,
         count(distinct i.qbo_project_id) as projects
  from invoice_lines il
  join invoices i     on i.id = il.invoice_id
  join qbo_projects p on p.id = i.qbo_project_id
  where coalesce(il.item_name,'') ilike '%programmatic%'
    and coalesce(il.item_name,'') not ilike '%fee%'
  group by 1
),
med as (
  select coalesce(p.parent_id, p.id) as parent,
         sum(c.amount)               as media_cogs
  from v_cost_lines_classified c
  join qbo_projects p on p.id = c.qbo_project_id
  where c.class = 'cogs'
    and ( exists (select 1 from qbo_accounts a
                  where a.id = c.account_id
                    and (a.name ilike '%media%'
                         or coalesce(a.fully_qualified_name,'') ilike '%media%')
                    and a.name not ilike '%fee%'
                    and coalesce(a.fully_qualified_name,'') not ilike '%fee%')
          or (c.account_id is null and coalesce(c.account_name,'') ilike '%media%'
                                   and coalesce(c.account_name,'') not ilike '%fee%') )
  group by 1
)
select
  cl.id   as client_id,
  cl.name,
  pr.revenue,
  coalesce(med.media_cogs, 0) as cogs,
  round(100.0 * (pr.revenue - coalesce(med.media_cogs, 0))
        / nullif(pr.revenue, 0), 1) as achieved_margin_pct,
  pr.projects
from clients cl
join prog_rev pr on pr.parent = cl.qbo_customer_id
left join med   on med.parent = cl.qbo_customer_id
where pr.revenue > 0;

comment on view v_client_achieved_margin is
  'Programmatic margin per client: programmatic-item invoice-line revenue vs media '
  'COGS, each aggregated per QuickBooks parent before joining. Clients with no '
  'programmatic lines have no row — the editor hint stays silent rather than '
  'flattering a mixed client with a meaningless number.';
