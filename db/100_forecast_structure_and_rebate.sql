-- ============================================================================
--  100 — The Forecast learns fee structures and rebates: deal_lines.structure,
--  deal_lines.rebate_pct / rebate_basis, and two columns appended to
--  v_deal_month_forecast.
--
--  A promoted scope (101) lands as deals + deal_lines + deal_line_months, and
--  the Forecast must price a tiered fee or a rebate exactly as the scope did.
--  Two things could not be expressed before this:
--
--    deal_lines.structure    the same jsonb scope_lines carries (096): fee
--                            {mode flat|marginal|whole, bands}, fee_min,
--                            fee_cap, prog {model}. The view prices search /
--                            social / programmatic through line_fee(budget,
--                            fee_pct, structure) — for '{}' that is EXACTLY
--                            budget × fee_pct / 100, so every existing line
--                            computes byte-identical numbers (100_fixture_test
--                            proves it against 087's body under a scratch
--                            name). It lives on the LINE, not per month: the
--                            editor deletes and re-inserts deal_line_months on
--                            every save, and a per-month column would vanish.
--    deal_lines.rebate_pct   + rebate_basis (media | fee): what EMG pays back
--                            to the client. The client invoices EMG and it is
--                            booked COGS Other, so it is a COGS, never a
--                            reduction of billable. gp in the view stays
--                            PRE-rebate — measured months already carry the
--                            booked rebate in their COGS, and every 087..094
--                            consumer of gp keeps its meaning — and the new
--                            `rebate` column is what the forward side subtracts.
--    deal_lines.scope_id / deals.scope_id  where a line / deal came from.
--
--  v_deal_month_forecast: `create or replace view` can only APPEND, so `fee`
--  and `rebate` go after pass_through, in that order, and must stay there.
--
--  Consumers reproduced WHOLE with the marked `100` additions (nothing else
--  moved — the fixture re-runs 087/088/092/093/094 on top of this):
--    forecast_page   plan_month.rebate; plan_deal.rebate_all / rebate_future
--    project_detail  months[].rebate_plan
--    client_detail   months[].rebate_plan
--    scope_verdict   the client roll-up's existing deals count gp − rebate
--
--  JS twins in the SAME commit: app/forecast.html gpMonth / revMonth route
--  search / social / programmatic through lineFee (scope-math.js) and gain
--  rebateMonth; forward COGS = billable − gp + rebate in forecast.html (table,
--  editor, chart) and app/index.html rowFor; app/client-profitability.html
--  blend() subtracts rebate_future. scripts/test/scope-math.test.mjs holds
--  the twin cases.
-- ============================================================================

alter table deal_lines add column if not exists structure jsonb not null default '{}'::jsonb;
alter table deal_lines drop constraint if exists deal_lines_structure_check;
alter table deal_lines add constraint deal_lines_structure_check check (structure_is_valid(structure));
alter table deal_lines add column if not exists rebate_pct numeric(6,3);
alter table deal_lines add column if not exists rebate_basis text;
alter table deal_lines drop constraint if exists deal_lines_rebate_basis_check;
alter table deal_lines add constraint deal_lines_rebate_basis_check check (rebate_basis is null or rebate_basis in ('media', 'fee'));
alter table deal_lines add column if not exists scope_id uuid references scopes(id) on delete set null;
alter table deals add column if not exists scope_id uuid references scopes(id) on delete set null;

comment on column deal_lines.structure is
  'Fee structure and programmatic model (096 shape): {"fee":{"mode":"flat"|"marginal"|"whole","bands":[{"upto":cents|null,"pct"}]},"fee_min":cents,"fee_cap":cents,"prog":{"model":"fee_margin"|"cpm"}}. {} = flat fee_pct, byte-identical to pre-100. Priced by line_fee(); bands apply to each month''s spend.';
comment on column deal_lines.rebate_pct is
  'Rebate EMG pays back to the client, % of rebate_basis (media | fee). The client invoices EMG; booked COGS Other. Reduces GP, never billable — v_deal_month_forecast.rebate.';

-- ---------------------------------------------------------------------------
--  v_deal_month_forecast: 087 verbatim, media kinds priced through line_fee,
--  `fee` and `rebate` APPENDED.
-- ---------------------------------------------------------------------------
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
         dl.rate,
         dl.structure, dl.rebate_pct, dl.rebate_basis          -- 100
  from deals d
  join deal_lines dl on dl.deal_id = d.id
  cross join lateral generate_series(
    date_trunc('month', d.flight_start),
    date_trunc('month', d.flight_end),
    interval '1 month') gs(month)
  left join deal_line_months dlm on dlm.deal_line_id = dl.id and dlm.month = gs.month::date
  where d.status in ('won', 'active') and not d.hidden
),
priced as (
  -- 100: ONE line_fee per row, unrounded; for structure '{}' it is exactly
  -- budget * fee_pct / 100, so the rounded results below equal 087's
  select m.*, line_fee(m.budget, m.fee_pct, m.structure) as fee_raw from months m
)
select deal_id, client_id, deal_line_id, kind, label, month, status, reviewed,
       media_funding, billing_day,
  case kind
    when 'retainer'     then amount
    when 'custom'       then amount
    when 'creative'     then case when label like 'creative:hourly%'
                                  then round(rate * hours)::bigint else amount end
    when 'hourly'       then round(rate * hours)::bigint
    when 'search'       then round(fee_raw)::bigint
    when 'social'       then round(fee_raw)::bigint
    when 'programmatic' then round(budget * margin_pct / 100 + fee_raw)::bigint
  end as gp,
  -- REVENUE. 087: agency-funded search/social bill their fee and nothing else
  -- — the media they rebill is pass_through below, not a sale. Programmatic
  -- still bills its media through as gross revenue, by decision.
  case kind
    when 'retainer'     then amount
    when 'custom'       then amount
    when 'creative'     then case when label like 'creative:hourly%'
                                  then round(rate * hours)::bigint else amount end
    when 'hourly'       then round(rate * hours)::bigint
    when 'search'       then round(fee_raw)::bigint
    when 'social'       then round(fee_raw)::bigint
    when 'programmatic' then budget + round(fee_raw)::bigint
  end as billable,
  case when kind in ('search', 'social') and media_funding = 'agency'
       then budget else 0 end as agency_media_out,
  case when kind in ('search', 'social') and media_funding = 'agency'
       then budget else 0 end as pass_through,
  -- 100, APPENDED (create or replace view can only append): the fee the client
  -- sees (media kinds: the media fee; other kinds: the whole line) and the
  -- rebate EMG pays back — COGS, never billable; gp above is PRE-rebate.
  case when kind in ('search', 'social', 'programmatic') then round(fee_raw)::bigint
       else case kind
         when 'creative' then case when label like 'creative:hourly%' then round(rate * hours)::bigint else amount end
         when 'hourly'   then round(rate * hours)::bigint
         else amount end
  end as fee,
  round(line_rebate(budget,
                    case when kind in ('search', 'social', 'programmatic') then fee_raw
                         else case kind
                           when 'creative' then case when label like 'creative:hourly%' then round(rate * hours) else amount end
                           when 'hourly'   then round(rate * hours)
                           else amount end end,
                    rebate_pct, rebate_basis))::bigint as rebate
from priced;

comment on view v_deal_month_forecast is
  'The commercial plan as money, per deal line per month. Flights carry exact '
  'dates; covered months come from truncating both ends. Flat kinds bill full '
  'months; media budgets carry day-weighting in their cells, written by the '
  'editor''s day-weighted spread. media_funding (027) is read per line. Hidden '
  'deals are excluded (058). billable is REVENUE and, since 087, excludes the '
  'media an agency-funded search/social line rebills (pass_through: cash, never '
  'a sale; programmatic is the exception and bills its media through). 100: '
  'search/social/programmatic fees come from line_fee(budget, fee_pct, structure) '
  '— flat for {} and byte-identical to before; marginal / whole-spend bands with '
  'min and cap otherwise. fee (what the client sees) and rebate (what EMG pays '
  'back: COGS, never billable) are appended; gp stays PRE-rebate. Revenue wants '
  'billable; cash wants billable + pass_through; profit wants gp − rebate.';

-- ---------------------------------------------------------------------------
--  forecast_page: 093 verbatim + the `100` lines.
-- ---------------------------------------------------------------------------
create or replace function forecast_page(p_from date, p_to date)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
plan as (
  select deal_id, month, gp, billable, rebate from v_deal_month_forecast   -- 100: + rebate
  where month between p_from and p_to
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on::timestamp)::date between p_from and p_to
),
-- invoice lines that post somewhere other than an income account: customer
-- deposits and pre-payments, which QuickBooks puts on the balance sheet and
-- keeps out of Total Income (079). Subtracted from the invoice total below.
-- Every condition here is a reason to subtract; anything unresolved falls
-- through and stays revenue.
nonrev as (
  select month, qbo_project_id, amount
  from v_invoice_lines_classified
  where month between p_from and p_to
    and account_id is not null
    and not unjoined
    and class is not null
    and class <> 'income'
),
-- one scan of v_cost_lines_classified spanning both the display range and
-- the trailing-6-month runrate window (076) — everything below reads from
-- this, not from the view directly.
bounds as (
  select least(p_from, ((select m from cur) - interval '6 months')::date) as lo,
         greatest(p_to, (select m from cur)) as hi
),
cost_all as (
  select month, class, qbo_project_id, account_name, amount, issued_on, ebitda_addback
  from v_cost_lines_classified
  where month between (select lo from bounds) and (select hi from bounds)
),
cost as (
  select month, class, qbo_project_id, account_name, amount, ebitda_addback
  from cost_all
  where month between p_from and p_to
),
-- same rows cost_runrate_monthly/payroll_loose_runrate/health_insurance_
-- forecast_month's trailing branch would each independently re-select.
cost_trail as (
  select class, account_name, amount, ebitda_addback
  from cost_all
  where issued_on >= (select m from cur) - interval '6 months'
    and issued_on <  (select m from cur)
),
-- matches cost_runrate_monthly(class, 6) for the 2 classes forecast_page uses.
-- 'other' is no longer forecast (093): it holds one-off / incremental lines,
-- and averaging them forward invented a recurring cost that never recurs.
runrate_trail as (
  select class, coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class in ('payroll', 'overhead')
  group by class
),
-- the EBITDA add-back's forward month (093): the same six-month trailing
-- window as the overhead run-rate, restricted to the add-back lines INSIDE
-- that run-rate. Only class 'overhead' — it is the one forecast cost that is
-- a trailing average of real lines. Labour forecasts from Team setup, COGS
-- from the plan, 'other' is not forecast at all, so none of them can carry a
-- depreciation, interest or below-the-line line into a forward month.
addback_trail as (
  select coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class = 'overhead' and ebitda_addback
),
-- matches payroll_loose_runrate() (074: exact match, not substring)
loose_payroll_trail as (
  select coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class = 'payroll' and account_name ilike 'Labor Cost:Payroll expenses'
),
-- matches health_insurance_forecast_month's pre-cutover trailing-average branch
health_ins_trail as (
  select coalesce(round(sum(amount)::numeric / 6)::bigint, 0) as total
  from cost_trail
  where class = 'payroll' and account_name ilike '%health insurance%'
),
-- matches health_insurance_forecast_month's post-cutover tier-sum branch
health_tier_sum as (
  select coalesce(sum(t.monthly_cost), 0) as total
  from staff s
  join health_insurance_tiers t on t.tier_key = s.health_insurance_tier
  where s.enrolled_health_insurance
),
health_cutover as (
  select coalesce(
    (select (value #>> '{}')::date from settings where key = 'health_insurance_flat_rate_cutover'),
    '2026-11-01'::date
  ) as d
),
act_projects as (
  select qbo_project_id as id from inv
  union
  select qbo_project_id from cost where qbo_project_id is not null
  union
  select qbo_project_id from deals where qbo_project_id is not null
),
keep_projects as (
  select p.* from qbo_projects p
  where p.hidden = false and (
    p.id in (select id from act_projects)
    or p.id in (select coalesce(q.parent_id, q.id) from qbo_projects q
                where q.id in (select id from act_projects))
    or p.id in (select qbo_customer_id from clients where qbo_customer_id is not null)
  )
),
bonus_forecast as (
  select date_trunc('month', b.pay_date)::date as month,
         sum(staff_bonus_burdened_cost(b.id)) as total
  from staff_bonuses b
  where date_trunc('month', b.pay_date)::date between p_from and p_to
  group by date_trunc('month', b.pay_date)::date
),
-- one row per future month (from "now" through p_to, clamped to p_from..p_to).
-- loose-payroll and health-insurance no longer call their functions per row
-- (076) — both read from the single-scan CTEs above, computed once.
labor_forecast_month as (
  select gm.month::date as month,
         staff_base_labor_forecast_month(gm.month::date)
           + (select total from loose_payroll_trail)
           + (case when gm.month::date >= (select d from health_cutover)
                   then (select total from health_tier_sum)
                   else (select total from health_ins_trail) end)
           + coalesce((select total from bonus_forecast bf where bf.month = gm.month::date), 0) as total
  from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
)
select jsonb_build_object(
  'plan_month', coalesce((select jsonb_agg(t) from (
      select month, sum(gp)::bigint as gp, sum(billable)::bigint as billable,
             sum(rebate)::bigint as rebate   -- 100: the rebate the plan pays back, COGS in the forward months
      from plan group by month) t), '[]'::jsonb),
  'plan_deal', coalesce((select jsonb_agg(t) from (
      select deal_id,
        sum(gp)::bigint as gp_all,
        coalesce(sum(gp) filter (where month < (select m from cur)), 0)::bigint as gp_settled,
        coalesce(sum(billable) filter (where month >= (select m from cur)), 0)::bigint as bill_future,
        -- 100: rebates, whole plan and forward months only — profit after labor wants gp − rebate
        coalesce(sum(rebate), 0)::bigint as rebate_all,
        coalesce(sum(rebate) filter (where month >= (select m from cur)), 0)::bigint as rebate_future
      from plan group by deal_id) t), '[]'::jsonb),
  'rev_month', coalesce((select jsonb_agg(t) from (
      select month, sum(total)::bigint as total from (
        select month, total from inv
        union all
        -- balance-sheet invoice lines (customer deposits / pre-payments) are
        -- not income in QuickBooks and are not revenue here either (080)
        select month, -amount as total from nonrev
        union all
        -- contra-revenue: debits to income-type accounts (search/social media
        -- pass-through offsets) net against invoiced revenue, as QuickBooks does
        select month, -amount as total from cost where class = 'income'
      ) u group by month) t), '[]'::jsonb),
  'rev_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(total)::bigint as total from (
        select qbo_project_id, month, total from inv
        union all
        select qbo_project_id, month, -amount from nonrev
        where qbo_project_id is not null
        union all
        select qbo_project_id, month, -amount from cost
        where class = 'income' and qbo_project_id is not null
      ) u where month < (select m from cur) and qbo_project_id is not null   -- 092: closed months only
      group by qbo_project_id) t), '[]'::jsonb),
  'cost_month', coalesce((select jsonb_agg(t) from (
      select month, class, sum(amount)::bigint as total from cost group by month, class) t), '[]'::jsonb),
  -- EBITDA add-back per measured month (093): cost lines on accounts flagged
  -- ebitda_addback, in the four classes the chart subtracts from net.
  -- EBITDA for a month = net + this. Other-Income-typed lines are negative in
  -- the view, so interest EARNED lowers EBITDA exactly as it raised net.
  'addback_month', coalesce((select jsonb_agg(t) from (
      select month, sum(amount)::bigint as total from cost
      where ebitda_addback and class in ('cogs', 'payroll', 'overhead', 'other')
      group by month) t), '[]'::jsonb),
  'cogs_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(amount)::bigint as total
      from cost where class = 'cogs' and month < (select m from cur)   -- 092: closed months only
        and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(t) from (
      select class, coalesce(account_name, '(no account)') as account,
             sum(amount)::bigint as total
      from cost group by class, account_name) t), '[]'::jsonb),
  'runrates', jsonb_build_object(
      'payroll',  coalesce((select total from runrate_trail where class = 'payroll'), 0),
      'overhead', coalesce((select total from runrate_trail where class = 'overhead'), 0),
      'addback',  (select total from addback_trail)),
  'labor_forecast_month', coalesce((select jsonb_agg(t) from labor_forecast_month t), '[]'::jsonb),
  'projects', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'parent_id', parent_id, 'jobcode', jobcode))
      from keep_projects), '[]'::jsonb)
);
$$ language sql stable;

comment on function forecast_page is
  'The Forecast page''s data, grouped where it lives: one jsonb, one round trip. '
  'Projects are trimmed to the ones the page shows; the editor''s full picker list '
  'loads lazily. v_cost_lines_classified is scanned exactly once, via cost_all (076). '
  'Measured revenue is the invoice total minus balance-sheet invoice lines (080) minus '
  'contra revenue (025) — QuickBooks'' Total Income; rev_proj/cogs_proj count closed '
  'months only (092). labor_forecast_month is bottoms-up Team-setup Labour (071-075). '
  'Since 093 runrates has no ''other''; addback_month / runrates.addback are the EBITDA '
  'add-back. 100: plan_month.rebate and plan_deal.rebate_all / rebate_future carry the '
  'planned rebates (COGS in forward months); gp stays pre-rebate.';

-- ---------------------------------------------------------------------------
--  project_detail / client_detail: 094 verbatim + rebate_plan.
-- ---------------------------------------------------------------------------
create or replace function project_detail(p_deal_id uuid)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
d as (
  select id, name, client_id, qbo_project_id, flight_start, flight_end
  from deals where id = p_deal_id
),
te as (
  select t.staff_id, t.worked_on, t.hours,
         coalesce(s.department, t.department, '(no department)') as department
  from time_entries t
  left join staff s on s.id = t.staff_id
  where t.deal_id = p_deal_id
    -- 091: the same rows hours_page counts (090_qbtime_hours_provenance) —
    -- excluded people and time-off-pending rows stay in the table, never here
    and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
),
weeks as (
  select date_trunc('week', worked_on)::date as week, department,
         sum(hours)::numeric as hours
  from te
  group by 1, 2
),
-- labor cost per month (094): the hours above priced exactly as hours_page
-- prices them — one staff_hourly_cost() per distinct staff/day, MATERIALIZED
-- so the planner cannot re-evaluate it per row (061/062). A row with no
-- staff (unknown_user) has hours but no rate, and drops out of the cost here
-- as it does from hours_page's deal_labor.
staff_days as (
  select distinct staff_id, worked_on from te where staff_id is not null
),
day_rates as materialized (
  select staff_id, worked_on, staff_hourly_cost(staff_id, worked_on) as rate
  from staff_days
),
labor as (
  select date_trunc('month', te.worked_on)::date as month,
         sum(te.hours * dr.rate)::bigint as labor
  from te
  join day_rates dr on dr.staff_id = te.staff_id and dr.worked_on = te.worked_on
  group by 1
),
plan as (
  select month, sum(billable)::bigint as rev_plan, sum(gp)::bigint as gp_plan,
         sum(rebate)::bigint as rebate_plan   -- 100
  from v_deal_month_forecast
  where deal_id = p_deal_id
  group by month
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, total
  from invoices
  where qbo_project_id = (select qbo_project_id from d)
),
nonrev as (
  select month, amount
  from v_invoice_lines_classified
  where qbo_project_id = (select qbo_project_id from d)
    and account_id is not null
    and not unjoined
    and class is not null
    and class <> 'income'
),
cost as (
  select month, class, amount
  from v_cost_lines_classified
  where qbo_project_id = (select qbo_project_id from d)
),
actual as (
  select month, sum(rev)::bigint as rev_actual, sum(cogs)::bigint as cogs_actual
  from (
    select month, total    as rev, 0::bigint as cogs from inv
    union all
    select month, -amount,         0         from nonrev
    union all
    select month, -amount,         0         from cost where class = 'income'
    union all
    select month, 0,               amount    from cost where class = 'cogs'
  ) u
  where month < (select m from cur)
  group by month
),
months as (
  select month from plan
  union
  select month from actual
  union
  -- a month with hours but no money is still a month with a (negative)
  -- profit after labor — it must have a row (094)
  select month from labor
  union
  select gs.month::date
  from d
  cross join lateral generate_series(
    date_trunc('month', d.flight_start),
    date_trunc('month', d.flight_end),
    interval '1 month') gs(month)
  where d.flight_start is not null and d.flight_end is not null
),
-- a closed month is measured even when nothing happened in it: 0, not null
measured as (
  select m.month,
         case when m.month < (select m from cur) then coalesce(a.rev_actual, 0) end   as rev_actual,
         case when m.month < (select m from cur) then coalesce(a.cogs_actual, 0) end  as cogs_actual,
         -- labor follows the same rule: measured once the month is over, 0 when
         -- nobody logged an hour, null while the month is still running (094)
         case when m.month < (select m from cur) then coalesce(l.labor, 0) end        as labor_actual
  from months m
  left join actual a on a.month = m.month
  left join labor  l on l.month = m.month
)
select jsonb_build_object(
  'deal', (select to_jsonb(d) from d),
  'measured_through', (select (m - interval '1 month')::date from cur),
  'weeks', coalesce((select jsonb_agg(jsonb_build_object(
      'week', w.week, 'department', w.department, 'hours', w.hours)
      order by w.week, w.department) from weeks w), '[]'::jsonb),
  'months', coalesce((select jsonb_agg(jsonb_build_object(
      'month',       m.month,
      'rev_actual',  m.rev_actual,
      'cogs_actual', m.cogs_actual,
      'gp_actual',   m.rev_actual - m.cogs_actual,
      -- 094: hours-based labor and profit after labor (gross profit − labor),
      -- both null until the month closes. No plan twin: assignments carry
      -- no cost, so there is no planned labor to subtract from gp_plan.
      'labor_actual', m.labor_actual,
      'pal_actual',   m.rev_actual - m.cogs_actual - m.labor_actual,
      'rev_plan',    p.rev_plan,
      'gp_plan',     p.gp_plan,
      'rebate_plan', p.rebate_plan)   -- 100: planned rebate (COGS) per month
      order by m.month)
      from measured m
      left join plan p on p.month = m.month), '[]'::jsonb)
);
$$ language sql stable;

create or replace function client_detail(p_client_id uuid)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
d as (
  select id, name, qbo_project_id, flight_start, flight_end
  from deals where client_id = p_client_id
),
projs as (
  select distinct qbo_project_id from d where qbo_project_id is not null
),
te as (
  select t.deal_id, t.staff_id, t.worked_on, t.hours,
         coalesce(s.department, t.department, '(no department)') as department
  from time_entries t
  left join staff s on s.id = t.staff_id
  where t.deal_id in (select id from d)
    and coalesce(t.attribution, '') not in ('excluded', 'timeoff')   -- 091, as above
),
weeks as (
  select date_trunc('week', worked_on)::date as week, department,
         sum(hours)::numeric as hours
  from te
  group by 1, 2
),
weeks_by_deal as (
  select date_trunc('week', worked_on)::date as week, deal_id,
         sum(hours)::numeric as hours
  from te
  group by 1, 2
),
-- labor cost per month (094): the hours above priced exactly as hours_page
-- prices them — one staff_hourly_cost() per distinct staff/day, MATERIALIZED
-- so the planner cannot re-evaluate it per row (061/062). A row with no
-- staff (unknown_user) has hours but no rate, and drops out of the cost here
-- as it does from hours_page's deal_labor.
staff_days as (
  select distinct staff_id, worked_on from te where staff_id is not null
),
day_rates as materialized (
  select staff_id, worked_on, staff_hourly_cost(staff_id, worked_on) as rate
  from staff_days
),
labor as (
  select date_trunc('month', te.worked_on)::date as month,
         sum(te.hours * dr.rate)::bigint as labor
  from te
  join day_rates dr on dr.staff_id = te.staff_id and dr.worked_on = te.worked_on
  group by 1
),
plan as (
  select month, sum(billable)::bigint as rev_plan, sum(gp)::bigint as gp_plan,
         sum(rebate)::bigint as rebate_plan   -- 100
  from v_deal_month_forecast
  where deal_id in (select id from d)
  group by month
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, total
  from invoices
  where qbo_project_id in (select qbo_project_id from projs)
),
nonrev as (
  select month, amount
  from v_invoice_lines_classified
  where qbo_project_id in (select qbo_project_id from projs)
    and account_id is not null
    and not unjoined
    and class is not null
    and class <> 'income'
),
cost as (
  select month, class, amount
  from v_cost_lines_classified
  where qbo_project_id in (select qbo_project_id from projs)
),
actual as (
  select month, sum(rev)::bigint as rev_actual, sum(cogs)::bigint as cogs_actual
  from (
    select month, total    as rev, 0::bigint as cogs from inv
    union all
    select month, -amount,         0         from nonrev
    union all
    select month, -amount,         0         from cost where class = 'income'
    union all
    select month, 0,               amount    from cost where class = 'cogs'
  ) u
  where month < (select m from cur)
  group by month
),
engagement as (
  select min(flight_start) as flight_start, max(flight_end) as flight_end from d
),
months as (
  select month from plan
  union
  select month from actual
  union
  select month from labor   -- 094, as in project_detail
  union
  select gs.month::date
  from engagement e
  cross join lateral generate_series(
    date_trunc('month', e.flight_start),
    date_trunc('month', e.flight_end),
    interval '1 month') gs(month)
  where e.flight_start is not null and e.flight_end is not null
),
measured as (
  select m.month,
         case when m.month < (select m from cur) then coalesce(a.rev_actual, 0) end   as rev_actual,
         case when m.month < (select m from cur) then coalesce(a.cogs_actual, 0) end  as cogs_actual,
         -- labor follows the same rule: measured once the month is over, 0 when
         -- nobody logged an hour, null while the month is still running (094)
         case when m.month < (select m from cur) then coalesce(l.labor, 0) end        as labor_actual
  from months m
  left join actual a on a.month = m.month
  left join labor  l on l.month = m.month
)
select jsonb_build_object(
  'client_id', p_client_id,
  'deal_ids', coalesce((select jsonb_agg(id) from d), '[]'::jsonb),
  'deals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'flight_start', flight_start, 'flight_end', flight_end)
      order by flight_start nulls last, name) from d), '[]'::jsonb),
  'engagement', (select to_jsonb(e) from engagement e),
  'measured_through', (select (m - interval '1 month')::date from cur),
  'weeks', coalesce((select jsonb_agg(jsonb_build_object(
      'week', w.week, 'department', w.department, 'hours', w.hours)
      order by w.week, w.department) from weeks w), '[]'::jsonb),
  'weeks_by_deal', coalesce((select jsonb_agg(jsonb_build_object(
      'week', w.week, 'deal_id', w.deal_id, 'hours', w.hours)
      order by w.week, w.deal_id) from weeks_by_deal w), '[]'::jsonb),
  'months', coalesce((select jsonb_agg(jsonb_build_object(
      'month',       m.month,
      'rev_actual',  m.rev_actual,
      'cogs_actual', m.cogs_actual,
      'gp_actual',   m.rev_actual - m.cogs_actual,
      -- 094: hours-based labor and profit after labor (gross profit − labor),
      -- both null until the month closes. No plan twin: assignments carry
      -- no cost, so there is no planned labor to subtract from gp_plan.
      'labor_actual', m.labor_actual,
      'pal_actual',   m.rev_actual - m.cogs_actual - m.labor_actual,
      'rev_plan',    p.rev_plan,
      'gp_plan',     p.gp_plan,
      'rebate_plan', p.rebate_plan)   -- 100: planned rebate (COGS) per month
      order by m.month)
      from measured m
      left join plan p on p.month = m.month), '[]'::jsonb)
);
$$ language sql stable;

comment on function project_detail is
  'One opened project on Project Hours (088-094): hours per ISO week per department; revenue / gross profit actual vs plan per month; labor_actual and pal_actual per closed month. 100: rebate_plan per month (the plan''s rebate, a COGS the forward side subtracts).';
comment on function client_detail is
  'An opened client on Client Profitability (089-094): project_detail unioned across the client''s deals, actuals over the DISTINCT claimed QB projects, the unclaimed remainder excluded. 100: rebate_plan per month.';

-- ---------------------------------------------------------------------------
--  scope_verdict: 097 verbatim, the client roll-up nets existing rebates.
-- ---------------------------------------------------------------------------
create or replace function scope_verdict(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
with sc as (select * from scopes where id = p_scope_id),
knobs as (
  select coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_profit_per_hour'), 150) * 100 as target_c,
         coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_utilization_pct'), 80) as util
),
econ as (
  select month, sum(gp) as gp, sum(rebate) as rebate, sum(billable) as billable, sum(pass_through) as pass_through
  from scope_months(p_scope_id) group by month
),
lab as (select * from scope_labor(p_scope_id)),
months as (select month from econ union select month from lab),
per as (
  select m.month,
         coalesce(e.gp, 0)::bigint as gp, coalesce(e.rebate, 0)::bigint as rebate, coalesce(e.billable, 0)::bigint as billable,
         coalesce(l.hours, 0) as hours, coalesce(l.cost, 0)::bigint as labor,
         coalesce(l.cost_lo, 0)::bigint as labor_lo, coalesce(l.cost_hi, 0)::bigint as labor_hi,
         coalesce(l.placeholder_hours, 0) + coalesce(l.unassigned_hours, 0) as open_hours,
         coalesce(l.unpriced_hours, 0) as unpriced_hours,
         coalesce(e.gp, 0) - coalesce(e.rebate, 0) - coalesce(l.cost, 0) as pal
  from months m left join econ e on e.month = m.month left join lab l on l.month = m.month
),
tot as (
  select sum(gp) as gp, sum(rebate) as rebate, sum(billable) as billable, sum(hours) as hours, sum(labor) as labor,
         sum(labor_lo) as labor_lo, sum(labor_hi) as labor_hi, sum(pal) as pal, sum(open_hours) as open_hours, sum(unpriced_hours) as unpriced_hours
  from per
),
staffing as (select scope_staffing(p_scope_id) as s),
hire as (
  select sum((h ->> 'hours')::numeric) as hours,
         sum((h ->> 'cost_hire')::bigint) as cost_hire,
         sum((h ->> 'cost_contractor')::bigint) as cost_contractor,
         bool_or((h ->> 'recommend')::boolean) as recommend,
         bool_and(h ->> 'cost_hire' is not null) as hire_priced,
         bool_and(h ->> 'cost_contractor' is not null) as contractor_priced
  from staffing, jsonb_array_elements(staffing.s -> 'hire') h
),
-- capacity: the scope's named hours per person per month against free hours
scope_named as (
  select staff_id, month, sum(hours) as hours from scope_staff_months
  where scope_id = p_scope_id and staff_id is not null group by staff_id, month
),
flight as (select min(month) as f0, max(month) as f1 from per),
cap as (
  select c.staff_id, c.month, c.capacity_hours,
         c.committed_hours - coalesce((select sum(a.hours) from assignments a
                                       where a.scope_id = p_scope_id and a.staff_id = c.staff_id and a.month = c.month), 0) as committed_other
  from flight, staff_capacity(f0, f1) c where f0 is not null
),
caprows as (
  select n.staff_id, n.month, n.hours as scope_hours,
         c.capacity_hours, c.committed_other,
         c.capacity_hours - c.committed_other - n.hours as free_after,
         (c.capacity_hours - c.committed_other - n.hours) < -0.005 as over
  from scope_named n left join cap c on c.staff_id = n.staff_id and c.month = n.month
),
-- client roll-up: the client's other live deals + this scope, per flight month
cd as (select client_detail((select client_id from sc)) as j where (select client_id from sc) is not null),
existing_measured as (
  select (x ->> 'month')::date as month, (x ->> 'gp_actual')::bigint as gp, (x ->> 'labor_actual')::bigint as labor
  from cd, jsonb_array_elements(cd.j -> 'months') x
  where (x ->> 'month')::date < date_trunc('month', current_date)::date
),
existing_plan as (
  select v.month, sum(v.gp - v.rebate)::bigint as gp   -- 100: the client's other deals net of their rebates
  from v_deal_month_forecast v
  where v.client_id = (select client_id from sc) and v.month >= date_trunc('month', current_date)::date
  group by v.month
),
plan_labor_keys as (
  select distinct a.staff_id, a.month from assignments a
  join deals d on d.id = a.deal_id
  where d.client_id = (select client_id from sc) and a.scope_id is distinct from p_scope_id
    and a.month between (select f0 from flight) and (select f1 from flight)
),
plan_rates as materialized (
  select staff_id, month, staff_hourly_cost(staff_id, month) as rate from plan_labor_keys
),
existing_plan_labor as (
  select a.month, sum(round(a.hours * r.rate))::bigint as labor
  from assignments a join deals d on d.id = a.deal_id
  join plan_rates r on r.staff_id = a.staff_id and r.month = a.month
  where d.client_id = (select client_id from sc) and a.scope_id is distinct from p_scope_id
  group by a.month
),
client_rows as (
  select p.month,
         coalesce(em.gp, ep.gp, 0) as gp_existing,
         coalesce(em.labor, epl.labor, 0) as labor_existing,
         p.gp as gp_scope, p.rebate as rebate_scope, p.labor as labor_scope,
         coalesce(em.gp, ep.gp, 0) - coalesce(em.labor, epl.labor, 0) + p.pal as pal_combined
  from per p
  left join existing_measured em on em.month = p.month
  left join existing_plan ep on ep.month = p.month
  left join existing_plan_labor epl on epl.month = p.month
  where (select client_id from sc) is not null
),
checks as (
  select
    (select bool_and(pal >= 0) from per) as monthly_positive,
    (select pal >= 0 from tot) as overall_positive,
    (select case when hours > 0 then round(pal / hours) >= (select target_c from knobs) else false end from tot) as per_hour_ok,
    (select bool_and(not over) from caprows where capacity_hours is not null) as capacity_ok,
    (select bool_and(pal_combined >= 0) from client_rows) as client_ok,
    (select open_hours > 0 from tot) as staff_unclear,
    (select unpriced_hours > 0 from tot) as unpriced,
    (select hours from tot) > 0 as has_hours
),
-- "viable with a hire": re-price the unstaffable hours at the hire / contractor rate
alt as (
  select
    case when h.hours is null or h.hours = 0 then null
         when h.hire_priced then (select pal from tot) - h.cost_hire
             + (select coalesce(sum(round(l.hours * br.r)), 0) from
                (select (x ->> 'department') as department, (k.key)::date as month, (k.value)::numeric as hours
                 from staffing, jsonb_array_elements(staffing.s -> 'hire') x, jsonb_each_text(x -> 'by_month') k) l
                cross join lateral (select band_rate(l.department, null, l.month) as r) br)
         end as pal_hire,
    case when h.hours is null or h.hours = 0 then null
         when h.contractor_priced then (select pal from tot) - h.cost_contractor
             + (select coalesce(sum(round(l.hours * br.r)), 0) from
                (select (x ->> 'department') as department, (k.key)::date as month, (k.value)::numeric as hours
                 from staffing, jsonb_array_elements(staffing.s -> 'hire') x, jsonb_each_text(x -> 'by_month') k) l
                cross join lateral (select band_rate(l.department, null, l.month) as r) br)
         end as pal_contractor,
    h.recommend, h.hours as hire_hours, h.cost_hire, h.cost_contractor
  from hire h
),
status as (
  select case
    when not (select has_hours from checks) then 'unclear'
    when (select unpriced from checks) then 'unclear'
    when (select overall_positive and per_hour_ok and coalesce(capacity_ok, true) and coalesce(client_ok, true) from checks) then 'go'
    when (select recommend from alt) and (select pal_hire from alt) is not null
         and (select pal_hire from alt) >= 0
         and round((select pal_hire from alt) / nullif((select hours from tot), 0)) >= (select target_c from knobs) then 'go_with_hire'
    when (select recommend from alt) and (select pal_contractor from alt) is not null
         and (select pal_contractor from alt) >= 0
         and round((select pal_contractor from alt) / nullif((select hours from tot), 0)) >= (select target_c from knobs) then 'go_with_contractor'
    else 'no_go' end as status
)
select jsonb_build_object(
  'months', coalesce((select jsonb_agg(jsonb_build_object(
      'month', month, 'gp', gp, 'rebate', rebate, 'billable', billable, 'hours', hours, 'labor', labor,
      'labor_lo', labor_lo, 'labor_hi', labor_hi, 'pal', pal,
      'per_hour_c', case when hours > 0 then round(pal / hours) end,
      'open_hours', open_hours, 'unpriced_hours', unpriced_hours) order by month) from per), '[]'::jsonb),
  'total', (select jsonb_build_object(
      'gp', gp, 'rebate', rebate, 'billable', billable, 'hours', hours, 'labor', labor,
      'labor_lo', labor_lo, 'labor_hi', labor_hi, 'pal', pal,
      'per_hour_c', case when hours > 0 then round(pal / hours) end,
      'open_hours', open_hours, 'unpriced_hours', unpriced_hours) from tot),
  'targets', (select jsonb_build_object('per_hour_c', target_c, 'utilization_pct', util) from knobs),
  'checks', (select to_jsonb(c) from checks c),
  'status', (select status from status),
  'hire', (select jsonb_build_object('recommend', recommend, 'hours', hire_hours, 'cost_hire', cost_hire,
                                     'cost_contractor', cost_contractor, 'pal_hire', pal_hire, 'pal_contractor', pal_contractor) from alt),
  'capacity', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'month', month, 'scope_hours', scope_hours, 'capacity_hours', capacity_hours,
      'committed_other', committed_other, 'free_after', free_after, 'over', over) order by staff_id, month) from caprows), '[]'::jsonb),
  'client', coalesce((select jsonb_agg(jsonb_build_object(
      'month', month, 'gp_existing', gp_existing, 'labor_existing', labor_existing,
      'gp_scope', gp_scope, 'rebate_scope', rebate_scope, 'labor_scope', labor_scope,
      'pal_combined', pal_combined) order by month) from client_rows), '[]'::jsonb)
);
$$;
