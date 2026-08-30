-- ============================================================================
--  070 — real structure, not placeholders, for two of the four gaps 069
--  papered over with a flat runrate:
--
--  1. Commissions & fees moves back to overhead, for good (Boris's call:
--     it's not a Team-setup-modeled labor cost conceptually, regardless of
--     its payroll-taxable status in reality). Reverts 069's reclassification.
--
--  2. Bonuses get a real schedule: staff_bonuses is one row per planned
--     bonus (staff, date, flat amount), entered on the person's profile in
--     Team setup — a person can have as many as needed. Boris explicitly
--     punted the tax-treatment decision to be figured out and built, so:
--
--       - FICA (Social Security + Medicare), FUTA, SUTA, and workers' comp
--         all apply, same as they do to salary in staff_annual_burdened_cost
--         (052).
--       - Social Security, FUTA, and SUTA are wage-base-capped PER PERSON
--         PER CALENDAR YEAR, combining prorated salary already earned that
--         year plus any earlier-dated bonus that same year — not per
--         payment independently. Someone already past the SS wage base
--         from salary alone owes ~$0 additional SS on a bonus; almost every
--         salaried person clears the ~$7k FUTA/SUTA wage base within the
--         first pay period or two of the year, so most bonuses scheduled
--         after January should show ~$0 FUTA/SUTA. Taxing every bonus as
--         if it were someone's first dollar of the year would meaningfully
--         overstate cost. This is month-level, not pay-period-level —
--         real enough to fix the overstatement without needing a full
--         payroll ledger.
--       - Medicare and workers' comp are NOT wage-base-capped (same as
--         052), so they apply to the full bonus amount directly.
--       - 401k match: defaulted to APPLY (assumes the plan's definition of
--         match-eligible compensation includes bonus pay) — genuinely
--         plan-specific and unverified; flip this if your plan excludes it.
--       - Health insurance and the PEO admin fee do not apply to a bonus —
--         neither is comp-linked.
--     A staff row with no comp_period covering the bonus date, or a
--     contractor, gets the bare scheduled amount with no burden added
--     (contractor: same "no burden" rule 052 already applies to salary).
--
--  Health insurance itself (the 069 placeholder, and its eventual real
--  per-person/tier structure) is untouched here — that's its own migration,
--  once the tier rates exist.
-- ============================================================================

-- ---------------------------------------------- 1. commission -> overhead --

update qbo_accounts
set override_class = 'overhead',
    override_reason = 'Commissions & fees is not a Team-setup-modeled labor cost — reverting 069, migration 070',
    override_by = 'migration:070',
    override_at = now()
where account_type in ('Expense', 'Other Expense')
  and name ilike '%commission%'
  and coalesce(override_class, derived_class) is distinct from 'overhead';

-- ------------------------------------------------------- 2. bonus schedule --

create table staff_bonuses (
  id         uuid primary key default gen_random_uuid(),
  staff_id   uuid not null references staff(id) on delete cascade,
  pay_date   date not null,
  amount     bigint not null,          -- gross scheduled amount, cents — employer burden is added on top, never deducted
  note       text,
  set_by     text,
  created_at timestamptz not null default now()
);
create index staff_bonuses_staff_idx on staff_bonuses (staff_id, pay_date);

alter table staff_bonuses enable row level security;
create policy staff_bonuses_policy on staff_bonuses
  for all to authenticated using (true) with check (true);

comment on table staff_bonuses is
  'A scheduled bonus: one flat gross amount on one date, entered on the '
  'person''s profile in Team setup. staff_bonus_burdened_cost (070) adds '
  'the employer-side tax burden on top. labor_forecast_month only reads '
  'these for future (unmeasured) months — a bonus scheduled in a month '
  'that has already closed is ignored there, since the real GL payment '
  'counts on its own once it actually posts.';

create or replace function staff_bonus_burdened_cost(p_bonus_id uuid)
returns bigint as $$
  with bn as (
    select id, staff_id, pay_date, amount from staff_bonuses where id = p_bonus_id
  ),
  cp as (
    select bn.staff_id, bn.pay_date, bn.amount,
           c.employment_type, c.kind, c.hourly_cost, c.annual_cost, c.weekly_capacity
    from bn
    left join lateral (
      select * from comp_periods
      where comp_periods.staff_id = bn.staff_id
        and comp_periods.starts_on <= bn.pay_date
        and (comp_periods.ends_on is null or comp_periods.ends_on >= bn.pay_date)
      order by comp_periods.starts_on desc
      limit 1
    ) c on true
  ),
  annualized as (
    select *,
      case kind when 'hourly' then hourly_cost * weekly_capacity * 52
                when 'salary' then annual_cost end as annualized_comp
    from cp
  ),
  person as (
    select a.*, s.start_date, s.enrolled_401k, s.work_state
    from annualized a
    left join staff s on s.id = a.staff_id
  ),
  -- year-to-date wages already earned before this bonus: prorated salary
  -- for the months already elapsed this calendar year, plus any earlier-
  -- dated bonus this same year — the room left under each wage base.
  ytd as (
    select p.*,
      coalesce(p.annualized_comp, 0) * (extract(month from p.pay_date)::int - 1) / 12.0
        + coalesce((
            select sum(amount) from staff_bonuses b2
            where b2.staff_id = p.staff_id
              and extract(year from b2.pay_date) = extract(year from p.pay_date)
              and b2.pay_date < p.pay_date
          ), 0) as wages_before
    from person p
  ),
  rates as (
    select
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_ss_rate'), 6.2) / 100 as ss_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_medicare_rate'), 1.45) / 100 as medicare_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'fica_ss_wage_base'), 176100) * 100 as ss_wage_base_c,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'futa_rate'), 0.6) / 100 as futa_rate,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'futa_wage_base'), 7000) * 100 as futa_wage_base_c,
      coalesce((select (value #>> '{}')::numeric from settings where key = 'k401_match_rate'), 0) / 100 as k401_rate
  )
  select case
    when y.annualized_comp is null then y.amount   -- no comp_period to burden against; pay the flat amount rather than vanish it
    when y.employment_type = 'contractor' then y.amount
    else (
      y.amount
      + round(
          least(y.amount, greatest(r.ss_wage_base_c - y.wages_before, 0)) * r.ss_rate
          + y.amount * r.medicare_rate
          + least(y.amount, greatest(r.futa_wage_base_c - y.wages_before, 0)) * r.futa_rate
          + y.amount * coalesce(
              (select wcr.rate from workers_comp_rates wcr where wcr.state = y.work_state),
              coalesce((select (value #>> '{}')::numeric from settings where key = 'workers_comp_rate'), 0)
            ) / 100
          + least(y.amount, greatest(
              coalesce((select sr.wage_base from suta_rates sr where sr.state = y.work_state),
                       coalesce((select (value #>> '{}')::numeric from settings where key = 'suta_wage_base'), 7000)) * 100
              - y.wages_before, 0)) * coalesce(
              (select sr.rate from suta_rates sr where sr.state = y.work_state),
              coalesce((select (value #>> '{}')::numeric from settings where key = 'suta_rate'), 0)
            ) / 100
        )
      + case when y.enrolled_401k
                  and staff_401k_eligibility_date(y.start_date) is not null
                  and y.pay_date >= staff_401k_eligibility_date(y.start_date)
             then round(y.amount * r.k401_rate) else 0 end
    )
  end::bigint
  from ytd y, rates r
$$ language sql stable;

comment on function staff_bonus_burdened_cost is
  'Employer cost of one scheduled bonus (staff_bonuses row), cents: the '
  'gross amount plus FICA/FUTA/SUTA/workers'' comp and (assumed-eligible) '
  '401k match — see migration 070''s header for the wage-base-capping '
  'approach and the assumptions flagged there. No health insurance or PEO '
  'fee added; neither is comp-linked.';

-- --------------------------------------- 3. labor_addendum_runrate narrows --

create or replace function labor_addendum_runrate(months int default 6)
returns bigint as $$
  select coalesce(round(sum(amount)::numeric / greatest(months, 1))::bigint, 0)
  from v_cost_lines_classified
  where class = 'payroll'
    and (
      account_name ilike '%health insurance%'
      or account_name ilike '%payroll expenses%'
    )
    and issued_on >= date_trunc('month', current_date) - make_interval(months => months)
    and issued_on <  date_trunc('month', current_date);
$$ language sql stable;

comment on function labor_addendum_runrate is
  'Trailing average of real GL cost for the labor categories still without '
  'real per-person data: health insurance and loose payroll-expense lines. '
  'Bonuses (070, now scheduled per-person) and Commissions & fees (070, now '
  'overhead) were dropped from this match — see migration 070.';

-- --------------------------------------------- 4. forecast_page rewired ---

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
-- every scheduled bonus landing in a future month, employer-burdened
-- (070) — grouped by the month it's actually scheduled to pay, not
-- smeared flat like the runrate categories.
bonus_forecast as (
  select date_trunc('month', b.pay_date)::date as month,
         sum(staff_bonus_burdened_cost(b.id)) as total
  from staff_bonuses b
  where date_trunc('month', b.pay_date)::date between p_from and p_to
  group by date_trunc('month', b.pay_date)::date
),
-- one row per future month (from "now" through p_to, clamped to p_from..p_to),
-- crossed with every staff row — a staff row contributes $0 for a month its
-- comp_periods don't cover, so no active/date filtering is needed here at all.
-- labor_addendum_runrate (069/070) adds the categories that per-person
-- modeling doesn't cover yet, flat across every future month; bonus_forecast
-- (070) adds each scheduled bonus in the specific month it's actually due.
labor_forecast_month as (
  select gm.month::date as month,
         round(sum(coalesce(staff_annual_labor_cost(s.id, gm.month::date), 0))::numeric / 12)::bigint
           + labor_addendum_runrate()
           + coalesce((select total from bonus_forecast bf where bf.month = gm.month::date), 0) as total
  from generate_series(greatest(p_from, (select m from cur)), p_to, interval '1 month') as gm(month)
  cross join staff s
  group by gm.month
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
  'invoices_month_idx (053). labor_forecast_month (068) is the Team-setup-sourced '
  'bottoms-up Labour projection for the chart''s future months: per-person base '
  'pay + statutory burden, plus labor_addendum_runrate (069/070, health insurance '
  '+ loose payroll) and bonus_forecast (070, scheduled bonuses, employer-burdened, '
  'in the month each is actually due).';
