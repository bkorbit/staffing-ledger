-- ============================================================================
--  013 — the margin arithmetic corrected: aggregate BEFORE joining.
--
--  012's shape was wrong: the media-COGS lateral ran per (project, invoice) row,
--  so a project with ten invoices counted its media cost ten times — enough to
--  push any client's margin negative. Revenue and cost now aggregate separately
--  per parent, then meet once.
--
--  And the account filter is what was asked for: COGS - Media, NOT the fee —
--  media-named cogs accounts excluding anything named like a fee.
-- ============================================================================

create or replace view v_client_achieved_margin as
with rev as (
  select coalesce(p.parent_id, p.id) as parent,
         sum(i.total)                 as revenue,
         count(distinct p.id)         as projects
  from invoices i
  join qbo_projects p on p.id = i.qbo_project_id
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
  rev.revenue,
  coalesce(med.media_cogs, 0) as cogs,
  round(100.0 * (rev.revenue - coalesce(med.media_cogs, 0))
        / nullif(rev.revenue, 0), 1) as achieved_margin_pct,
  rev.projects
from clients cl
join rev on rev.parent = cl.qbo_customer_id
left join med on med.parent = cl.qbo_customer_id
where rev.revenue > 0;

comment on view v_client_achieved_margin is
  'Invoiced revenue vs media COGS per client, both aggregated per QuickBooks parent '
  'BEFORE joining — 012 multiplied cost by the invoice count. Media = cogs-class '
  'lines on accounts named like media and not like fee. Revenue remains all invoiced '
  'revenue until invoice lines are split by service.';
