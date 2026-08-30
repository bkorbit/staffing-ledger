-- ============================================================================
--  071 — the last two pieces: health insurance's two-phase model, and
--  wiring the real bottoms-up labor numbers into Cashflow (not just Forecast).
--
--  HEALTH INSURANCE
--  Boris: today's plan is percent-based (80%/60%/etc) and genuinely can't be
--  forecast without knowing exactly who's on what — there's no clean formula
--  for it. Starting 11/1/2026 the company switches to flat amounts per tier,
--  at which point forecasting becomes trivial: sum each enrolled person's
--  tier rate. So this is date-branched:
--
--    before the cutover: the same flat trailing-6-month GL average 069 already
--    had (health_insurance_forecast_month keeps that behavior unconditionally
--    for months before the cutover). I originally floated scaling that average
--    by current enrolled headcount, but there's no historical enrollment-count
--    data to make that genuinely more accurate than the flat average — it
--    would've either collapsed back to the same number or needed data that
--    doesn't exist. Not worth the complexity for a ~2-month bridge; simple and
--    honest beats fake precision here.
--
--    from the cutover on: health_insurance_tiers holds a flat monthly
--    company-paid amount per tier (seeded with $0 placeholders — Boris still
--    needs to fill in the real tier names/rates before 11/1, either via SQL
--    directly or a Settings UI addition closer to the date). staff.
--    health_insurance_tier assigns each person to one; Team setup got a
--    dropdown next to the existing Health Insurance checkbox so tiers can be
--    assigned now, ahead of the cutover. The cutover date itself lives in
--    settings ('health_insurance_flat_rate_cutover') so it can move without
--    a migration if the rollout date slips.
--
--  labor_addendum_runrate (069/070) is retired — its two remaining pieces
--  split into their own functions: payroll_loose_runrate (the "loose
--  payroll expenses" catch-all, unconditionally flat) and
--  health_insurance_forecast_month (above). staff_base_labor_forecast_month
--  factors out just the per-person base-pay-plus-statutory-burden total,
--  reused by both forecast_page (already had it inline) and, new here,
--  cashflow_forecast — so Cashflow's payroll cash-out is no longer a flat
--  GL-trailing-average disconnected from the bottoms-up model driving the
--  Forecast chart.
--
--  CASHFLOW TIMING (Boris's note)
--  Base salary + its statutory burden: split across the existing semi-
--  monthly cadence (15th + month-end) — same run dates cashflow_forecast()
--  already used, just no longer a flat number, the actual bottoms-up total
--  for whichever month that run falls in. Loose payroll expenses ride the
--  same flat-per-period treatment overhead already gets (no better timing
--  signal exists for them). Health insurance: a single charge on the 1st of
--  the month, not split. Each bonus: on its own scheduled date, not smeared
--  across the month at all — a bonus check happens once.
-- ============================================================================

-- ---------------------------------------------------- 1. health insurance --

create table health_insurance_tiers (
  tier_key     text primary key,
  label        text not null,
  monthly_cost bigint not null default 0,   -- cents, company-paid portion — PLACEHOLDER, fill in before 11/1
  updated_at   timestamptz not null default now()
);

insert into health_insurance_tiers (tier_key, label, monthly_cost) values
  ('employee_only',   'Employee only',      0),
  ('employee_spouse',  'Employee + spouse',  0),
  ('employee_family',  'Employee + family',  0);

alter table health_insurance_tiers enable row level security;
create policy health_insurance_tiers_policy on health_insurance_tiers
  for all to authenticated using (true) with check (true);

comment on table health_insurance_tiers is
  'Flat company-paid monthly amount per tier, effective from the '
  'health_insurance_flat_rate_cutover setting onward (071). Seeded with $0 '
  'placeholders — real tier names and rates still need to go in before the '
  'cutover date, either directly via SQL or a future Settings UI.';

alter table staff add column if not exists health_insurance_tier text
  references health_insurance_tiers(tier_key);

comment on column staff.health_insurance_tier is
  'Which flat-rate tier (071) this person is assigned to, effective from '
  'the cutover date. Independent of enrolled_health_insurance (041), which '
  'still gates the pre-cutover flat-runrate placeholder and is not implied '
  'by setting a tier — set both by hand.';

insert into settings (key, value, set_by) values
  ('health_insurance_flat_rate_cutover', '"2026-11-01"', 'migration:071')
on conflict (key) do nothing;

create or replace function health_insurance_forecast_month(p_month date)
returns bigint as $$
  select case
    when p_month >= coalesce(
      (select (value #>> '{}')::date from settings where key = 'health_insurance_flat_rate_cutover'),
      '2026-11-01'::date
    ) then coalesce((
      select sum(t.monthly_cost)
      from staff s
      join health_insurance_tiers t on t.tier_key = s.health_insurance_tier
      where s.enrolled_health_insurance
    ), 0)
    else coalesce(round(
      (select sum(amount) from v_cost_lines_classified
       where class = 'payroll' and account_name ilike '%health insurance%'
         and issued_on >= date_trunc('month', current_date) - interval '6 months'
         and issued_on <  date_trunc('month', current_date)
      )::numeric / 6
    )::bigint, 0)
  end;
$$ language sql stable;

comment on function health_insurance_forecast_month is
  'Health insurance cost for one future month: before the cutover setting, '
  'the flat trailing-6-month GL average (same figure 069 used); from the '
  'cutover on, the sum of each enrolled person''s assigned tier rate. See '
  'migration 071''s header for why the pre-cutover side stayed a flat '
  'average rather than a fake per-head scale.';

-- --------------------------------------------- 2. labor_addendum retired ---

drop function if exists labor_addendum_runrate(int);

create or replace function payroll_loose_runrate(months int default 6)
returns bigint as $$
  select coalesce(round(sum(amount)::numeric / greatest(months, 1))::bigint, 0)
  from v_cost_lines_classified
  where class = 'payroll'
    and account_name ilike '%payroll expenses%'
    and issued_on >= date_trunc('month', current_date) - make_interval(months => months)
    and issued_on <  date_trunc('month', current_date);
$$ language sql stable;

comment on function payroll_loose_runrate is
  'Trailing average of the "loose/unattributed payroll expenses" GL account '
  '(60001) — the one labor_addendum_runrate (069/070) category with no real '
  'per-person model of its own, split out on its own now that health '
  'insurance (071) needed date-branched logic the other did not.';

create or replace function staff_base_labor_forecast_month(p_month date)
returns bigint as $$
  select round(sum(coalesce(staff_annual_labor_cost(s.id, p_month), 0))::numeric / 12)::bigint
  from staff s
$$ language sql stable;

comment on function staff_base_labor_forecast_month is
  'Per-person base pay + statutory burden (staff_annual_labor_cost, 052) for '
  'every staff row, for one month — factored out of forecast_page (068) so '
  'cashflow_forecast (071) can use the SAME number for its payroll cash-out '
  'instead of an independently-computed, inevitably-diverging one.';

-- ------------------------------------------------------ 3. forecast_page ---

create or replace function forecast_page(p_from date, p_to date)
returns jsonb as $$
with cur as (select date_trunc('month', current_date)::date as m),
plan as (
  select deal_id, month, gp, billable from v_deal_month_forecast
  where month between p_from and p_to
),
inv as (
  select date_trunc('month', issued_on::timestamp)::date as month, qbo_project_id, total
  from invoices
  where date_trunc('month', issued_on::timestamp)::date between p_from and p_to
),
cost as (
  select month, class, qbo_project_id, account_name, amount
  from v_cost_lines_classified
  where month between p_from and p_to
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
-- staff_base_labor_forecast_month (071) already sums across every staff row
-- internally — a person contributes $0 for a month their comp_periods don't
-- cover, so no active/date filtering is needed here either.
labor_forecast_month as (
  select gm.month::date as month,
         staff_base_labor_forecast_month(gm.month::date)
           + payroll_loose_runrate()
           + health_insurance_forecast_month(gm.month::date)
           + coalesce((select total from bonus_forecast bf where bf.month = gm.month::date), 0) as total
  from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
)
select jsonb_build_object(
  'plan_month', coalesce((select jsonb_agg(t) from (
      select month, sum(gp)::bigint as gp, sum(billable)::bigint as billable
      from plan group by month) t), '[]'::jsonb),
  'plan_deal', coalesce((select jsonb_agg(t) from (
      select deal_id,
        sum(gp)::bigint as gp_all,
        coalesce(sum(gp) filter (where month < (select m from cur)), 0)::bigint as gp_settled,
        coalesce(sum(billable) filter (where month >= (select m from cur)), 0)::bigint as bill_future
      from plan group by deal_id) t), '[]'::jsonb),
  'rev_month', coalesce((select jsonb_agg(t) from (
      select month, sum(total)::bigint as total from (
        select month, total from inv
        union all
        -- contra-revenue: debits to income-type accounts (search/social media
        -- pass-through offsets) net against invoiced revenue, as QuickBooks does
        select month, -amount as total from cost where class = 'income'
      ) u group by month) t), '[]'::jsonb),
  'rev_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(total)::bigint as total from (
        select qbo_project_id, month, total from inv
        union all
        select qbo_project_id, month, -amount from cost
        where class = 'income' and qbo_project_id is not null
      ) u where month <= (select m from cur) and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'cost_month', coalesce((select jsonb_agg(t) from (
      select month, class, sum(amount)::bigint as total from cost group by month, class) t), '[]'::jsonb),
  'cogs_proj', coalesce((select jsonb_agg(t) from (
      select qbo_project_id, sum(amount)::bigint as total
      from cost where class = 'cogs' and month <= (select m from cur)
        and qbo_project_id is not null
      group by qbo_project_id) t), '[]'::jsonb),
  'accounts', coalesce((select jsonb_agg(t) from (
      select class, coalesce(account_name, '(no account)') as account,
             sum(amount)::bigint as total
      from cost group by class, account_name) t), '[]'::jsonb),
  'runrates', jsonb_build_object(
      'payroll',  cost_runrate_monthly('payroll'),
      'overhead', cost_runrate_monthly('overhead'),
      'other',    cost_runrate_monthly('other')),
  'labor_forecast_month', coalesce((select jsonb_agg(t) from labor_forecast_month t), '[]'::jsonb),
  'projects', coalesce((select jsonb_agg(jsonb_build_object(
      'id', id, 'name', name, 'parent_id', parent_id, 'jobcode', jobcode))
      from keep_projects), '[]'::jsonb)
);
$$ language sql stable;

comment on function forecast_page is
  'The Forecast page''s data, grouped where it lives: one jsonb, one round trip. '
  'Projects are trimmed to the ones the page shows; the editor''s full picker list '
  'loads lazily. inv (055) uses an explicit ::timestamp cast so it matches '
  'invoices_month_idx (053). labor_forecast_month is bottoms-up Team-setup '
  'Labour for the chart''s future months: staff_base_labor_forecast_month '
  '(071, per-person base pay + statutory burden) + payroll_loose_runrate '
  '(071) + health_insurance_forecast_month (071, date-branched) + '
  'bonus_forecast (070, scheduled bonuses, employer-burdened, in the month '
  'each is actually due).';

-- --------------------------------------------------- 4. cashflow_forecast --

drop function if exists cashflow_forecast(int);

create function cashflow_forecast(periods int default 12)
returns table (
  week_start        date,
  period_label      text,
  cash_in_early     bigint,
  cash_in_expected  bigint,
  cash_in_late      bigint,
  in_contracted_early    bigint,
  in_contracted_expected bigint,
  in_contracted_late     bigint,
  out_bills         bigint,
  out_payroll       bigint,
  out_overhead      bigint,
  out_agency_media  bigint,
  out_contracted_cogs bigint,
  position_optimistic   bigint,
  position_expected     bigint,
  position_conservative bigint
) as $$
declare
  opening       bigint;
  operating_set boolean;
  -- programmatic/forecast COGS terms: due N days after the last day of the spend
  -- month. Human-owned setting, default 45.
  cogs_due_days int := coalesce((select (value #>> '{}')::int from settings
                                 where key = 'programmatic_cogs_due_days'), 45);
  overhead_week bigint := round(cost_runrate_monthly('overhead') / 2.0);
  loose_week    bigint := round(payroll_loose_runrate() / 2.0);
begin
  select exists (select 1 from qbo_accounts where account_type = 'Bank' and is_operating)
    into operating_set;
  select coalesce(sum(balance), 0) into opening
  from qbo_accounts
  where account_type = 'Bank' and (not operating_set or is_operating);

  return query
  -- calendar half-months: H1 = 1st..15th, H2 = 16th..month end, starting with the
  -- half that contains today, exactly `periods` of them
  with wk as (
    select h.w_start,
           case when extract(day from h.w_start) = 1
                then (h.w_start + interval '14 days')::date
                else (date_trunc('month', h.w_start) + interval '1 month' - interval '1 day')::date
           end as w_end
    from (
      select unnest(array[ m.m0, (m.m0 + interval '15 days')::date ]) as w_start
      from (select (date_trunc('month', current_date) + make_interval(months => g))::date as m0
            from generate_series(0, (periods / 2) + 1) g) m
    ) h
    where case when extract(day from h.w_start) = 1
               then (h.w_start + interval '14 days')::date
               else (date_trunc('month', h.w_start) + interval '1 month' - interval '1 day')::date
          end >= current_date
    order by h.w_start
    limit periods
  ),
  -- open AR, as before
  inflow as (
    select w.w_start,
      coalesce(sum(e.balance) filter (where e.expect_early  between w.w_start and w.w_end), 0)::bigint as early,
      coalesce(sum(e.balance) filter (where e.expect_median between w.w_start and w.w_end), 0)::bigint as expected,
      coalesce(sum(e.balance) filter (where e.expect_late   between w.w_start and w.w_end), 0)::bigint as late
    from wk w cross join v_open_invoice_expectations e
    group by w.w_start
  ),
  -- contracted: future deal months become expected invoices on the billing day,
  -- collected on the client's curve. Months already begun are excluded — their
  -- invoices either exist (open AR above) or are imminent and arrive next sync.
  contracted_src as (
    select f.billable,
      case f.billing_day
        when 'first' then f.month
        else (f.month + interval '1 month' - interval '1 day')::date
      end as invoice_on,
      coalesce(cb.p25_lag,  gb.p25_lag, 30)  as p25,
      coalesce(cb.median_lag, gb.median_lag, 35) as p50,
      coalesce(cb.p90_lag,  gb.p90_lag, 80)  as p90
    from v_deal_month_forecast f
    join clients c on c.id = f.client_id
    left join payment_behaviour cb on cb.scope = 'client' and cb.ref = c.qbo_customer_id
    left join payment_behaviour gb on gb.scope = 'global'
    where f.month > date_trunc('month', current_date)::date
      and f.billable > 0
  ),
  contracted as (
    select w.w_start,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p25 between w.w_start and w.w_end), 0)::bigint as early,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p50 between w.w_start and w.w_end), 0)::bigint as expected,
      coalesce(sum(s.billable) filter (where s.invoice_on + s.p90 between w.w_start and w.w_end), 0)::bigint as late
    from wk w cross join contracted_src s
    group by w.w_start
  ),
  -- agency-funded media leaves on card mid-spend-month
  -- the cost contracted months imply (billable - gp), paid mid spend month —
  -- forecast programmatic media is cash leaving, same timing as agency media
  contracted_cogs as (
    -- due = last day of the spend month + the configured terms (Oct -> Oct 31 + 45d)
    select w.w_start,
      coalesce(sum(greatest(f.billable - f.gp, 0))
        filter (where ((f.month + interval '1 month' - interval '1 day')::date + cogs_due_days)
                between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join (select * from v_deal_month_forecast
                          where billable > gp
                            and month > date_trunc('month', current_date)::date) f
    group by w.w_start
  ),
  agency_out as (
    select w.w_start,
      coalesce(sum(f.agency_media_out)
        filter (where (f.month + 14) between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join (select * from v_deal_month_forecast
                          where agency_media_out > 0
                            and month >= date_trunc('month', current_date)::date) f
    group by w.w_start
  ),
  bills_due as (
    select w.w_start,
      coalesce(sum(b.balance) filter (where greatest(coalesce(b.due_on, current_date), current_date)
                                      between w.w_start and w.w_end), 0)::bigint as due
    from wk w cross join (select * from bills where balance > 0) b
    group by w.w_start
  ),
  -- base salary + statutory burden, on the existing semi-monthly cadence
  -- (15th, month-end) — half of THAT MONTH's bottoms-up total per run,
  -- not a flat GL-trailing-average disconnected from the Forecast chart.
  payroll_runs as (
    select d::date as pay_on, date_trunc('month', d)::date as month from (
      select (date_trunc('month', current_date) + make_interval(months => m) + interval '14 days') as d
      from generate_series(0, (periods / 2) + 2) m
      union all
      select (date_trunc('month', current_date) + make_interval(months => m + 1) - interval '1 day')
      from generate_series(0, (periods / 2) + 2) m
    ) x where d::date >= current_date
  ),
  payroll_wk as (
    select w.w_start,
      coalesce((
        select round(staff_base_labor_forecast_month(p.month) / 2.0)
        from payroll_runs p where p.pay_on between w.w_start and w.w_end
        limit 1
      ), 0)::bigint as amt
    from wk w
  ),
  -- health insurance: one lump on the 1st of the month (H1 always starts on
  -- the 1st), never split
  health_wk as (
    select w.w_start,
      case when extract(day from w.w_start) = 1
           then health_insurance_forecast_month(w.w_start)
           else 0 end::bigint as amt
    from wk w
  ),
  -- each scheduled bonus on its own date — a bonus check happens once, it
  -- doesn't get smeared across the month like the flat categories
  bonus_wk as (
    select w.w_start,
      coalesce(sum(staff_bonus_burdened_cost(b.id))
        filter (where b.pay_date between w.w_start and w.w_end), 0)::bigint as amt
    from wk w cross join staff_bonuses b
    group by w.w_start
  ),
  payroll_runs_out as (
    select pw.w_start, (coalesce(pw.amt,0) + loose_week + coalesce(hw.amt,0) + coalesce(bw.amt,0))::bigint as total
    from payroll_wk pw
    left join health_wk hw on hw.w_start = pw.w_start
    left join bonus_wk bw on bw.w_start = pw.w_start
  )
  select
    w.w_start,
    trim(to_char(w.w_start, 'Mon')) || ' H' ||
      (case when extract(day from w.w_start) = 1 then '1' else '2' end) ||
      ' ' || to_char(w.w_start, 'YY'),
    coalesce(i.early,0), coalesce(i.expected,0), coalesce(i.late,0),
    coalesce(ct.early,0), coalesce(ct.expected,0), coalesce(ct.late,0),
    coalesce(bd.due,0), coalesce(pr.total,0), overhead_week, coalesce(ao.amt,0), coalesce(cc.amt,0),
    (opening + sum(coalesce(i.early,0) + coalesce(ct.early,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.expected,0) + coalesce(ct.expected,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint,
    (opening + sum(coalesce(i.late,0) + coalesce(ct.late,0)
        - coalesce(bd.due,0) - coalesce(pr.total,0) - overhead_week - coalesce(ao.amt,0) - coalesce(cc.amt,0))
        over (order by w.w_start))::bigint
  -- LEFT JOINs with coalesce: any of these CTEs is legitimately empty on a given
  -- day (no open AR, no future deal months, no unpaid bills), and an inner join
  -- would silently return no forecast at all — the worst possible failure shape.
  from wk w
  left join inflow i          on i.w_start  = w.w_start
  left join contracted ct     on ct.w_start = w.w_start
  left join bills_due bd      on bd.w_start = w.w_start
  left join payroll_runs_out pr on pr.w_start = w.w_start
  left join agency_out ao     on ao.w_start = w.w_start
  left join contracted_cogs cc on cc.w_start = w.w_start
  order by w.w_start;
end;
$$ language plpgsql stable;

comment on function cashflow_forecast is
  'Half-month cash position in three bands. out_payroll (071) is no longer '
  'a flat GL-trailing-average: base salary+burden on the existing semi-'
  'monthly cadence uses staff_base_labor_forecast_month for whichever '
  'month each run falls in, loose payroll expenses ride the same flat-per-'
  'period treatment overhead gets, health insurance lands as one lump on '
  'the 1st (health_insurance_forecast_month), and each scheduled bonus '
  '(staff_bonus_burdened_cost) hits on its own date. COGS remains media-'
  'schedule-driven only (026); overhead remains a flat run-rate — that one '
  'really is stable.';
