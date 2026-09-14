-- ============================================================================
-- 108 — Team Hours: profit for the current and future months runs on FORECAST
--       revenue (Boris, 13 Sep 2026)
--
--  Team Hours' profit column joined a person's logged hours against measured
--  revenue per QuickBooks project (rev_proj_page, closed months only since
--  092). For the in-progress month and any future month that is $0 revenue
--  against real cost — a meaningless number. The rule now:
--
--    measured months (before the current one): as before — the closed months'
--      measured revenue split across the hours logged in them.
--    the current month and later: the deal's FORECAST revenue
--      (v_deal_month_forecast.billable — revenue, never pass_through) split
--      across an hours basis per person: their ASSIGNED hours while their
--      logged hours are under the assignment, their LOGGED hours to date once
--      they are over it. Cost follows the same basis: what has been logged at
--      its real day rate, plus the unworked remainder of the assignment at
--      staff_hourly_cost(person, month).
--
--  The page does that arithmetic (it already owns the per-person split), but
--  hours_page aggregated everything over the whole range, so a range that
--  straddles the month boundary (This Quarter) could not tell a closed month's
--  hours from the running month's. This migration APPENDS the per-month
--  pieces to hours_page's payload — everything before them is 090's body
--  verbatim (108_fixture_test proves the old keys unchanged, key by key):
--
--    measured_before          the server's current month — the page reads the
--                             boundary from here, never from the browser clock
--    staff_hours_deal_month   staff × deal × month: hours, cost (the labor CTE)
--    staff_deal_planned_month staff × deal × month: planned hours (assignments)
--    deal_forecast            deal × month ≥ current: billable, gp (the plan)
--    staff_rate_month         staff × month ≥ current: staff_hourly_cost —
--                             staff_rates_months (105), so a person the
--                             scoping side would not price is not priced here
--
--  hours_page's own months are the range as given (p_from … p_to); the plan
--  and rates are read for whole months from date_trunc(p_from) to
--  date_trunc(p_to), the same window `planned` already used.
-- ============================================================================

create or replace function hours_page(p_from date, p_to date)
returns jsonb as $$
with te as (
  -- 090: excluded people / excluded jobcodes and time-off-pending rows are
  -- kept in the table (zero data loss) but never priced or counted here.
  select * from time_entries
  where worked_on between p_from and p_to
    and coalesce(attribution, '') not in ('excluded', 'timeoff')
),
staff_days as (
  select distinct staff_id, worked_on from te
),
hi_setting as (
  select coalesce((select (value #>> '{}')::date from settings
                   where key = 'health_insurance_start_date'), '2099-01-01'::date) as hi_start
),
-- Per (staff, day): which comp_periods row covers it, and this staff's
-- answer to the two threshold comparisons on that day. Three columns that
-- fully determine staff_hourly_cost()'s output for that day (see header).
cohorts as (
  select
    sd.staff_id, sd.worked_on,
    cov.starts_on as period_key,
    (s.enrolled_401k
       and staff_401k_eligibility_date(s.start_date) is not null
       and sd.worked_on >= staff_401k_eligibility_date(s.start_date)) as k401_key,
    (s.enrolled_health_insurance and sd.worked_on >= hi_setting.hi_start) as hi_key
  from staff_days sd
  join staff s on s.id = sd.staff_id
  cross join hi_setting
  left join lateral (
    select cp.starts_on
    from comp_periods cp
    where cp.staff_id = sd.staff_id
      and cp.starts_on <= sd.worked_on
      and (cp.ends_on is null or cp.ends_on >= sd.worked_on)
    order by cp.starts_on desc
    limit 1
  ) cov on true
),
-- One staff_hourly_cost() call per distinct cohort — MATERIALIZED so the
-- planner can't flatten this and push the call back down to per-row (062
-- hit exactly this trap with the plain per-day version).
cohort_rates as materialized (
  select staff_id, period_key, k401_key, hi_key,
         staff_hourly_cost(staff_id, min(worked_on)) as rate
  from cohorts
  group by staff_id, period_key, k401_key, hi_key
),
day_rates as (
  select c.staff_id, c.worked_on, cr.rate
  from cohorts c
  join cohort_rates cr
    on cr.staff_id = c.staff_id
   and cr.period_key is not distinct from c.period_key
   and cr.k401_key = c.k401_key
   and cr.hi_key = c.hi_key
),
labor as (
  select te.deal_id, te.staff_id, date_trunc('month', te.worked_on)::date as month,
         te.hours, te.hours * day_rates.rate as cost
  from te
  join day_rates on day_rates.staff_id = te.staff_id and day_rates.worked_on = te.worked_on
),
planned as (
  select deal_id, staff_id, month, hours as planned_hours
  from assignments
  where month between date_trunc('month', p_from) and date_trunc('month', p_to)
),
-- 108: the forecast side, whole months from the current one on
cur as (select date_trunc('month', current_date)::date as m)
select jsonb_build_object(
  'staff', coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active,
      'start_date', s.start_date, 'end_date', s.end_date, 'tracks_capacity', s.tracks_capacity,
      'has_recent_hours', exists(select 1 from time_entries te2 where te2.staff_id = s.id)))
      from staff s), '[]'::jsonb),
  'comp_current', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', s.id, 'kind', cp.kind, 'annual_cost', cp.annual_cost,
      'hourly_cost', cp.hourly_cost, 'weekly_capacity', coalesce(cp.weekly_capacity, 40),
      'starts_on', cp.starts_on))
      from staff s left join comp_periods cp on cp.staff_id = s.id and cp.ends_on is null), '[]'::jsonb),
  'staff_hours_month', coalesce((select jsonb_agg(t) from (
      select staff_id, month, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor group by staff_id, month) t), '[]'::jsonb),
  'staff_hours_deal', coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by staff_id, deal_id) t), '[]'::jsonb),
  'staff_planned', coalesce((select jsonb_agg(t) from (
      select staff_id, sum(planned_hours)::numeric as planned_hours
      from planned group by staff_id) t), '[]'::jsonb),
  'staff_deal_planned', coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by staff_id, deal_id) t), '[]'::jsonb),
  'deal_labor', coalesce((select jsonb_agg(t) from (
      select deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by deal_id) t), '[]'::jsonb),
  'deal_planned', coalesce((select jsonb_agg(t) from (
      select deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by deal_id) t), '[]'::jsonb),
  'time_off', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'starts_on', starts_on, 'ends_on', ends_on, 'kind', kind, 'hours', hours))
      from time_off where ends_on >= p_from and starts_on <= p_to), '[]'::jsonb),
  -- 108: appended — nothing above this line moved
  'measured_before', (select m from cur),
  'staff_hours_deal_month', coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, month, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by staff_id, deal_id, month) t), '[]'::jsonb),
  'staff_deal_planned_month', coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, month, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by staff_id, deal_id, month) t), '[]'::jsonb),
  'deal_forecast', coalesce((select jsonb_agg(t) from (
      select f.deal_id, f.month, sum(f.billable)::bigint as billable, sum(f.gp)::bigint as gp
      from v_deal_month_forecast f
      where f.month between date_trunc('month', p_from) and date_trunc('month', p_to)
        and f.month >= (select m from cur)
      group by f.deal_id, f.month) t), '[]'::jsonb),
  'staff_rate_month', coalesce((select jsonb_agg(t) from (
      select r.staff_id, r.month, r.rate
      from staff_rates_months(greatest(date_trunc('month', p_from)::date, (select m from cur)),
                              date_trunc('month', p_to)::date) r
      where r.rate is not null) t), '[]'::jsonb)
);
$$ language sql stable;

comment on function hours_page is
  'Team Hours / Project Hours payload for one date range. 090''s body verbatim, plus (108) the per-month pieces Team Hours needs to price the current and future months on forecast revenue: measured_before (the server''s current month), staff_hours_deal_month, staff_deal_planned_month, deal_forecast (v_deal_month_forecast billable/gp, months >= current), staff_rate_month (staff_rates_months, months >= current). Excluded / timeoff time entries are never counted (090).';
