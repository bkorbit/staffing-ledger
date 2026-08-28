-- ============================================================================
--  012 — achieved margin is a PROGRAMMATIC number: media COGS only.
--
--  The 011 view measured invoiced revenue against ALL classified COGS, which
--  pollutes the margin for any client with mixed work. Programmatic cost lives
--  in the media COGS account(s), so the margin hint measures against exactly
--  those: class = cogs AND the account name contains 'media'.
--
--  Honest limit, stated: the revenue side is still ALL invoiced revenue for the
--  client, because invoice lines are not split by service yet. For clients that
--  are mostly programmatic the number is right; for heavily mixed clients it
--  overstates. The editor label says what it measures.
-- ============================================================================

create or replace view v_client_achieved_margin as
select
  cl.id as client_id,
  cl.name,
  sum(i.total)                                   as revenue,
  coalesce(sum(cg.media_cogs), 0)                as cogs,
  round(100.0 * (sum(i.total) - coalesce(sum(cg.media_cogs),0))
        / nullif(sum(i.total), 0), 1)            as achieved_margin_pct,
  count(distinct i.qbo_project_id)               as projects
from clients cl
join qbo_projects p  on coalesce(p.parent_id, p.id) = cl.qbo_customer_id
join invoices i      on i.qbo_project_id = p.id
left join lateral (
  select sum(c.amount) as media_cogs
  from v_cost_lines_classified c
  where c.qbo_project_id = p.id
    and c.class = 'cogs'
    and ( exists (select 1 from qbo_accounts a
                  where a.id = c.account_id
                    and (a.name ilike '%media%' or a.fully_qualified_name ilike '%media%'))
          or c.account_name ilike '%media%' )
) cg on true
where cl.qbo_customer_id is not null
group by cl.id, cl.name
having sum(i.total) > 0;

comment on view v_client_achieved_margin is
  'Invoiced revenue vs MEDIA COGS per client (cogs-class lines on accounts named '
  'like media) — the programmatic margin basis. Revenue is still all invoiced '
  'revenue until invoice lines exist; the editor label states the measure.';
