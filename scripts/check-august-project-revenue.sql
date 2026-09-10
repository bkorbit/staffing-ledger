-- Diagnostic, not a migration. Read-only, safe to run any time.
--
-- Data check, 10 Sep 2026: QuickBooks' "Project Profitability Summary" for
-- August 2026 (Boris's export, 43 active projects) against the Revenue column
-- Client Profitability and Project Hours show for an August-only range.
--
-- Both tabs read that column from forecast_page(p_from, p_to).rev_proj — per
-- QB project, in cents: invoice totals, minus invoice lines that post to the
-- balance sheet (customer deposits, 080), minus cost lines that hit an income
-- account (contra revenue, 025). QuickBooks' project report is income-account
-- lines only, so the two SHOULD agree line for line. The tabs add plan_deal's
-- bill_future on top unless "measured only" is ticked; for a closed month that
-- addon is zero — the fc_addon column proves it per project.
--
-- One result set. One row per QB project (and per platform project with
-- August revenue that the export does not carry), a TOTAL row last.
--   verdict      MATCH            same to the cent
--                DIFF             both sides have the project, numbers differ
--                NOT IN PLATFORM  the QB name/jobcode matches no qbo_projects row
--                NOT IN QB EXPORT platform has August revenue, export does not list it
--   matched_by   name (exact DisplayName) or jobcode (leading token of the QB name)
--   shown_on     which tab carries the row and under what: a visible deal puts
--                it on both tabs; an unclaimed project only appears in Client
--                Profitability's drill-down, and NOT in the client total.

with aug as (select date '2026-08-01' as m),
qb(project, customer, revenue) as (values
  ('24andb251218 &Barr - Space Coast Credit Union 2026', '&Barr', 120813.83),
  ('24forc260702 Force Multiplier Strategy - 8fold - 26H2', 'Force Multiplier Strategy', 600.00),
  ('24forc3009250 - Force Multiplier Strategy - Solidigm', 'Force Multiplier Strategy', 70316.33),
  ('24mate2604011 Material+ - USTA', 'Materialplus', 47248.60),
  ('24mate260401 Material+ - MIT Sloan - MIT Audience Q1-Q2', 'Materialplus', 13341.84),
  ('24mate260521 Material+ - ABM - Search & Social', 'Materialplus', 14460.38),
  ('24mate260804 MaterialPlus - UC Health - 2H', 'Materialplus', 1382.15),
  ('24o2kl1107240 O2KL - Analytics Retainer', 'O2KL', 7500.00),
  ('24o2kl31026 o2kl - AARP - Dashboard - 26Q1', 'O2KL', 660.00),
  ('24onlo022726 On Location - LA Olympics', 'On Location Events LLC', 324846.36),
  ('24onlo260208 On Location - Super Bowl - 2027', 'On Location Events LLC', 14999.85),
  ('24onlo260507 On Location - UFC 2026', 'On Location Events LLC', 2604.75),
  ('24onlo260724 On Location - Zuffa Boxing - Q3', 'On Location Events LLC', 5465.17),
  ('24onlo260814 On Location - NCAA - 2027', 'On Location Events LLC', 8999.91),
  ('24oran260305 Focus Media - Orange County Tourism - Display - 2026', 'Focus Media', 16319.47),
  ('24oran31026 Focus Media - Orange County - Search - 2026', 'Focus Media', 1769.89),
  ('25alet260408 Aletheia - Social - 26Q2', 'Aletheia Marketing & Media', 1498.50),
  ('25camp251112 Campfire - Go Net Speed 2026', 'Campfire Consulting', 1955.00),
  ('25disc262605 Discover Long Island - Summer Leisure Campaign - 2026', 'Discover Long Island', 11746.76),
  ('25forg2504250 Forge Apollo - Search - 05/15/2025 - 12/31/2025', 'Forge Apollo', 96.68),
  ('25forg260610 Forge Apollo - The Point - Search - 2026', 'Forge Apollo', 782.39),
  ('25forg260818 Forge Apollo - Amare', 'Forge Apollo', 52756.82),
  ('25kati2511141 Katie Brockman - Fourhands', 'Katie Brockman & Co.', 15005.25),
  ('25medi260626 Mediaplus - Social Support - 26Q3', 'MEDIAPLUS', 14835.00),
  ('25moon0606250 Moon Rabbit - AdOps', 'Moon Rabbit', 2700.00),
  ('25moon260827 Moon Rabbit - Tarsus Strategy - 26H2', 'Moon Rabbit', 800.00),
  ('25redh260512 Redhouse - Visit PA- World Cup Phase 2- 2026', 'Red House Communications', 0.00),
  ('26avac260826 AVA Community Energy - AVA Charge', 'Ava Community Energy', 2354.09),
  ('26bran092926 Brand Revolution - Creative - 2026', 'Brand Revolution', 2775.00),
  ('26bran260710 Brand Revolution - Trava', 'Brand Revolution', 33189.71),
  ('26disn260528 Disney Visa - Acquisition', 'Disney Rewards Visa Card', 45000.00),
  ('26disv260527 Disney Visa - Retention', 'Disney Rewards Visa Card', 72550.00),
  ('26gyka260515 GYK - Milo''s + Hometown Financial - 26Q2', 'GYK', 1242.00),
  ('26hawt260810 Hawthorn - Search & Social - 26/27', 'Hawthorn Creative', 7652.51),
  ('26misc260417 Mischief - Cracker Barrel - 26Q2', 'Mischief @ No Fixed Address', 17647.50),
  ('26pard260611 Super Age - AOR - 2026', 'Superage', 5000.00),
  ('26reli260617 Reliefband - 2026', 'Reliefband', 7500.00),
  ('26spyd260813 SpyderCo - Social Test - 26Q3', 'SpyderCo', 346.28),
  ('26wili260424 Window World of LI - Programmatic - 2026', 'Window World Long Island', 12994.37),
  ('26wldc260601 Wild Coffee - Search & Social', 'Wild Coffee Marketing', 6142.57),
  ('26zeno260707 Zeno Group - Social - Q3', 'Zeno Group', 15647.50),
  ('Disney Visa - DisneyDebit.com Maintenance', 'Disney Rewards Visa Card', 4500.00),
  ('LOR - AdOps - 01/01/24 (Cont.)', 'LOR Media LLC', 2260.14)
),
-- the tabs' own call: an August-only range is p_from = p_to = 2026-08-01
fp as (select forecast_page((select m from aug), (select m from aug)) as j),
rp as (
  select r->>'qbo_project_id' as qbo_project_id, (r->>'total')::bigint as cents
  from fp, jsonb_array_elements(fp.j->'rev_proj') r
),
pd as (
  select r->>'deal_id' as deal_id, (r->>'bill_future')::bigint as bill_future
  from fp, jsonb_array_elements(fp.j->'plan_deal') r
),
-- each QB row to a platform project: exact DisplayName first, jobcode second
qbm as (
  select q.project, q.customer, q.revenue,
         coalesce(pn.id, pj.id) as project_id,
         case when pn.id is not null then 'name'
              when pj.id is not null then 'jobcode' end as matched_by
  from qb q
  left join lateral (
    select id from qbo_projects p where trim(p.name) = trim(q.project)
    order by p.hidden, p.id limit 1
  ) pn on true
  left join lateral (
    select id from qbo_projects p
    where pn.id is null
      and p.effective_jobcode is not null
      and lower(p.effective_jobcode) = lower(substring(q.project from '^\S+'))
    order by p.hidden, p.id limit 1
  ) pj on true
),
ids as (
  select project_id as id from qbm where project_id is not null
  union
  select qbo_project_id from rp where cents <> 0
),
platform as (
  select p.id, p.name, p.parent_name, p.hidden,
         coalesce(rp.cents, 0) as cents,
         dl.deals, dl.n_visible, dl.fc_addon
  from ids i
  join qbo_projects p on p.id = i.id
  left join rp on rp.qbo_project_id = p.id
  left join lateral (
    select string_agg(d.name, ' | ' order by d.name) as deals,
           count(*) filter (where not d.hidden
                              and (d.flight_start is null or d.flight_start < (select m from aug) + interval '1 month')
                              and (d.flight_end   is null or d.flight_end  >= (select m from aug))) as n_visible,
           coalesce(sum(pd.bill_future), 0) as fc_addon
    from deals d left join pd on pd.deal_id = d.id::text
    where d.qbo_project_id = p.id
  ) dl on true
),
rows_ as (
  select coalesce(q.project, pl.name)          as qb_project,
         coalesce(q.customer, pl.parent_name)  as customer,
         q.revenue                             as qb_revenue,
         case when pl.id is not null then round(pl.cents / 100.0, 2) end as platform_revenue,
         case when pl.id is not null and q.project is not null
              then round(pl.cents / 100.0 - q.revenue, 2) end as diff,
         case when q.project is null                    then 'NOT IN QB EXPORT'
              when pl.id is null                        then 'NOT IN PLATFORM'
              when pl.cents = round(q.revenue * 100)    then 'MATCH'
              else 'DIFF' end                           as verdict,
         q.matched_by,
         case when pl.id is null            then null
              when pl.hidden                then 'hidden project — nowhere'
              when pl.n_visible > 0         then 'both tabs · deal: ' || pl.deals
              when pl.deals is not null     then 'deal hidden/outside August — CP drill-down only: ' || pl.deals
              else 'unclaimed — CP drill-down only, not in client total' end as shown_on,
         case when pl.id is not null then round(pl.fc_addon / 100.0, 2) end as fc_addon
  from qbm q
  full outer join platform pl on pl.id = q.project_id
)
select * from (
  select qb_project, customer, qb_revenue, platform_revenue, diff, verdict, matched_by, shown_on, fc_addon,
         case verdict when 'DIFF' then 0 when 'NOT IN PLATFORM' then 1 when 'NOT IN QB EXPORT' then 2 else 3 end as k
  from rows_
  union all
  select 'TOTAL', null,
         sum(qb_revenue),
         sum(platform_revenue),
         round(coalesce(sum(platform_revenue), 0) - coalesce(sum(qb_revenue), 0), 2),
         count(*) filter (where verdict = 'MATCH') || ' match · '
           || count(*) filter (where verdict = 'DIFF') || ' diff · '
           || count(*) filter (where verdict = 'NOT IN PLATFORM') || ' not in platform · '
           || count(*) filter (where verdict = 'NOT IN QB EXPORT') || ' not in export',
         null, null, sum(fc_addon), 9
  from rows_
) t
order by k, abs(coalesce(diff, qb_revenue, platform_revenue, 0)) desc, qb_project;
