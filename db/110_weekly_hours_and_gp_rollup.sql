-- 110_weekly_hours_and_gp_rollup.sql — two payloads the browser was assembling
-- out of raw rows.
--
-- Home fetched every time_entries row in its range (~14,000 over six months:
-- fourteen paged requests in three serial waves, ~1.5 MB) and bucketed them by
-- ISO week in JavaScript. Home AND Sales Forecast each fetched every row of
-- v_deal_month_forecast (~4,200: five paged requests) to add up one gross-profit
-- number per month. Both are one GROUP BY, and neither is a number changing:
-- date_trunc('week') is Monday-based exactly as Home's weekStart() is, and
-- summing an already-summed month again is a no-op, so the pages' own roll-up
-- code is left in place and simply has less to do.
--
-- hours_page_parts gains ONE key, appended the way 108 appended its five;
-- nothing above it moves, and 110_fixture_test asserts every older key
-- unchanged against 109.

create or replace function hours_page_parts(p_from date, p_to date, p_parts text[] default null)
returns jsonb as $$
with te as (
  -- 090: excluded people / excluded jobcodes and time-off-pending rows are
  -- kept in the table (zero data loss) but never priced or counted here.
  -- 109: four named columns rather than select *, so the 50k-row scan the
  -- twelve-month ranges do carries what it needs and nothing else.
  select staff_id, deal_id, worked_on, hours from time_entries
  where worked_on between p_from and p_to
    and coalesce(attribution, '') not in ('excluded', 'timeoff')
),
-- 109: the cohort rule (one staff_hourly_cost() per person / comp period /
-- 401k / health-insurance, never per person-day) now lives in
-- staff_day_rates, which project_detail and client_detail read too.
day_rates as (
  select staff_id, worked_on, rate from staff_day_rates(p_from, p_to)
),
labor as (
  -- 109: priced once, at the finest grain every key below is a roll-up of.
  -- The four hours keys used to be four independent passes over every
  -- priced row; they now roll up this one. Rows with no deal stay in (a
  -- person's staff_hours_month counts their internal hours, deal_labor does
  -- not), and the sums stay NUMERIC here — each key casts to bigint itself,
  -- exactly once, so a sum of sums is the same cents as a sum of the raw
  -- rows rather than a sum of roundings.
  select te.staff_id, te.deal_id, date_trunc('month', te.worked_on)::date as month,
         sum(te.hours) as hours, sum(te.hours * day_rates.rate) as cost
  from te
  join day_rates on day_rates.staff_id = te.staff_id and day_rates.worked_on = te.worked_on
  group by te.staff_id, te.deal_id, date_trunc('month', te.worked_on)::date
),
planned as (
  select deal_id, staff_id, month, hours as planned_hours
  from assignments
  where month between date_trunc('month', p_from) and date_trunc('month', p_to)
),
-- 108: the forecast side, whole months from the current one on
cur as (select date_trunc('month', current_date)::date as m)
select jsonb_build_object(
  'staff', case when p_parts is null or 'staff' = any (p_parts) then coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active,
      'start_date', s.start_date, 'end_date', s.end_date, 'tracks_capacity', s.tracks_capacity,
      -- 109: same answer as the per-person exists() this replaces, resolved in
      -- one pass over time_entries instead of a subplan per person
      'has_recent_hours', h.staff_id is not null))
      from staff s
      left join (select distinct staff_id from time_entries where staff_id is not null) h
        on h.staff_id = s.id), '[]'::jsonb) end,
  'comp_current', case when p_parts is null or 'comp_current' = any (p_parts) then coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', s.id, 'kind', cp.kind, 'annual_cost', cp.annual_cost,
      'hourly_cost', cp.hourly_cost, 'weekly_capacity', coalesce(cp.weekly_capacity, 40),
      'starts_on', cp.starts_on))
      from staff s left join comp_periods cp on cp.staff_id = s.id and cp.ends_on is null), '[]'::jsonb) end,
  'staff_hours_month', case when p_parts is null or 'staff_hours_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, month, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor group by staff_id, month) t), '[]'::jsonb) end,
  'staff_hours_deal', case when p_parts is null or 'staff_hours_deal' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by staff_id, deal_id) t), '[]'::jsonb) end,
  'staff_planned', case when p_parts is null or 'staff_planned' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, sum(planned_hours)::numeric as planned_hours
      from planned group by staff_id) t), '[]'::jsonb) end,
  'staff_deal_planned', case when p_parts is null or 'staff_deal_planned' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by staff_id, deal_id) t), '[]'::jsonb) end,
  'deal_labor', case when p_parts is null or 'deal_labor' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select deal_id, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by deal_id) t), '[]'::jsonb) end,
  'deal_planned', case when p_parts is null or 'deal_planned' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select deal_id, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by deal_id) t), '[]'::jsonb) end,
  'time_off', case when p_parts is null or 'time_off' = any (p_parts) then coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', staff_id, 'starts_on', starts_on, 'ends_on', ends_on, 'kind', kind, 'hours', hours))
      from time_off where ends_on >= p_from and starts_on <= p_to), '[]'::jsonb) end,
  -- 108: appended — nothing above this line moved
  'measured_before', case when p_parts is null or 'measured_before' = any (p_parts) then to_jsonb((select m from cur)) end,
  'staff_hours_deal_month', case when p_parts is null or 'staff_hours_deal_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, month, sum(hours)::numeric as hours, sum(cost)::bigint as cost
      from labor where deal_id is not null group by staff_id, deal_id, month) t), '[]'::jsonb) end,
  'staff_deal_planned_month', case when p_parts is null or 'staff_deal_planned_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select staff_id, deal_id, month, sum(planned_hours)::numeric as planned_hours
      from planned where deal_id is not null group by staff_id, deal_id, month) t), '[]'::jsonb) end,
  'deal_forecast', case when p_parts is null or 'deal_forecast' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select f.deal_id, f.month, sum(f.billable)::bigint as billable, sum(f.gp)::bigint as gp
      from v_deal_month_forecast f
      where f.month between date_trunc('month', p_from) and date_trunc('month', p_to)
        and f.month >= (select m from cur)
      group by f.deal_id, f.month) t), '[]'::jsonb) end,
  'staff_rate_month', case when p_parts is null or 'staff_rate_month' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select r.staff_id, r.month, r.rate
      from staff_rates_months(greatest(date_trunc('month', p_from)::date, (select m from cur)),
                              date_trunc('month', p_to)::date) r
      where r.rate is not null) t), '[]'::jsonb) end,
  -- 110, APPENDED: hours per ISO week per deal, for Home's weekly-by-project
  -- chart. Home was fetching the RAW time_entries rows for its range and
  -- bucketing them in the browser — ~14,000 rows over a six-month range, which
  -- is fourteen paged requests in three serial waves and about a megabyte and
  -- a half, to draw roughly five hundred numbers.
  --
  -- It reproduces that query EXACTLY, which means it does NOT apply 090's
  -- attribution filter: Home's fetch never had one, so this chart counts hours
  -- on excluded people and jobcodes that every other number on the page (and
  -- every other page) leaves out. That is a real inconsistency and it is left
  -- exactly as it was — 110 is a speed migration, and which hours a chart
  -- counts is Boris's call, not a rewrite's.
  'deal_week_hours', case when p_parts is null or 'deal_week_hours' = any (p_parts) then coalesce((select jsonb_agg(t) from (
      select date_trunc('week', worked_on)::date as week, deal_id, sum(hours)::numeric as hours
      from time_entries
      where worked_on between p_from and p_to and deal_id is not null
      group by 1, 2) t), '[]'::jsonb) end
)
-- keys the caller did not ask for are removed outright, not left as nulls: a
-- page checking `H.deal_forecast` for a pre-108 payload must not see one.
- (select coalesce(array_agg(k), '{}'::text[])
   from unnest(array['staff','comp_current','staff_hours_month','staff_hours_deal','staff_planned',
                     'staff_deal_planned','deal_labor','deal_planned','time_off','measured_before',
                     'staff_hours_deal_month','staff_deal_planned_month','deal_forecast','staff_rate_month',
                     'deal_week_hours']) k
   where p_parts is not null and not (k = any (p_parts)));
$$ language sql stable;

comment on function hours_page_parts(date, date, text[]) is
  'Every page''s hours payload (108''s keys, plus 110''s deal_week_hours). '
  'p_parts names the keys wanted — null is the whole payload; a list builds '
  'only those and an un-taken CASE branch never runs its subquery, so the work '
  'is skipped with the bytes. Rates come from staff_day_rates(), the one copy '
  'of the cohort rule, shared with project_detail/client_detail.';

-- ---------------------------------------------------------------------------
--  The committed gross profit per month, already added up.
--
--  Home and Sales Forecast both build `LEDGER` — one number per month — by
--  fetching every deal-line-month in the whole ledger and summing in the
--  browser. The view is the same sum; the pages keep their own per-month
--  accumulation (summing one row per month is the same answer) so neither has
--  to change shape to use it.
-- ---------------------------------------------------------------------------
create or replace view v_deal_month_gp as
  select month, sum(gp)::bigint as gp, sum(billable)::bigint as billable
  from v_deal_month_forecast
  group by month;

-- Every other view here relies on Supabase's default privileges for objects
-- created in public; this one says it out loud, because a view the browser
-- cannot read is a blank Home page rather than a slow one.
grant select on v_deal_month_gp to authenticated, service_role;

comment on view v_deal_month_gp is
  'v_deal_month_forecast summed to one row per month (110) — the committed GP '
  'line on Home''s and Sales Forecast''s pipeline charts. ~40 rows instead of '
  'every deal-line-month in the ledger, which had outgrown Supabase''s 1000-row '
  'cap and was arriving in five paged requests to make two dozen numbers.';
