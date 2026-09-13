-- ============================================================================
--  097 — Scoping: the money per month, labor as ONE number, staffing
--  suggestions, the verdict, and the page payload.
--
--  scope_months(scope_id)   the scope twin of v_deal_month_forecast, per line
--    per month, with two more columns: fee and rebate. Same `case kind`
--    shape and ONE rounding point per figure: search/social gp = billable =
--    round(line_fee); programmatic gp = round(budget × margin/100 + line_fee),
--    billable = budget + round(line_fee); flat and hourly kinds as the view.
--    gp is PRE-rebate, as it will be in the view (099): the verdict subtracts
--    rebate itself, and measured months already carry the booked rebate in
--    COGS. Spreading (day-weighting, remainder on the last month) is the
--    editor's job when it writes the cells, exactly as the Forecast editor.
--
--  scope_labor(scope_id)    labor cost per month, TOTALS ONLY. Named rows are
--    priced at staff_hourly_cost(staff, month) — one call per distinct
--    (staff, month), MATERIALIZED (094's shape); placeholders at
--    band_rate(department, band, month); demand nobody covers ("unassigned")
--    at the department average, so the verdict never undercounts labor. No
--    per-person or per-department cost leaves this function (Boris: labor is
--    one rolled-up number so nobody can read who earns what). cost_lo /
--    cost_hi price every non-named hour at the department's cheapest and
--    dearest band — the range the staff plan can still move the answer by.
--
--  scope_staffing(scope_id) demand vs supply per department per month,
--    ranked candidates (worked this client → worked this kind → free hours →
--    cost; rank only, never the cost), free hours per candidate per month from
--    staff_capacity minus this scope's own approved rows, and the hire
--    analysis: hours no free person in the department can cover, and — when
--    that exceeds scope_hire_fte_share_pct of a full-time month for at least
--    scope_hire_min_months months — a hire option priced at hire_hourly_cost
--    and contractor_hourly_cost (settings, per department).
--
--  auto_staff_scope(scope_id, by) fills the unassigned gap greedily, FEWEST
--    PEOPLE FIRST: the top candidate takes as much as they are free for in
--    every month before a second person is added (Boris: one person at 40h,
--    not two at 20h). Writes source 'auto' rows; manual rows are never touched;
--    a rerun replaces only the auto layer.
--
--  scope_verdict(scope_id)  per month gp, rebate, labor, pal = gp − rebate −
--    labor, hours, profit per hour; checks (every month positive, overall
--    positive, per-hour ≥ scope_target_profit_per_hour, capacity, client
--    roll-up, unpriced hours); status go | go_with_hire | go_with_contractor |
--    no_go | unclear; the client roll-up (existing deals' measured gp/labor
--    from client_detail for closed months, v_deal_month_forecast gp + planned
--    labor from assignments for open months, plus this scope). staff_unclear
--    flags hours still on placeholders or unassigned.
--
--  scope_page(scope_id)     one round trip for app/scoping.html: everything
--    above plus versions, scenario siblings with their verdict KPIs, the
--    roster (no rates), departments, knobs and the source rows.
--
--  approve_scope / unapprove_scope / set_scope_status — the lifecycle.
--    Approve (approvers only, from proposed) snapshots a version and writes
--    the scope's NAMED hours into assignments (deal_id null, scope_id set,
--    set_by scope:approve). Placeholders never reach assignments.
--
--  quick_check(...)        the list view's 30-second answer: one kind, a
--    monthly budget/fee (or amount, or hours×rate), months, expected hours per
--    month by department → gp, labor at department averages, pal, per hour,
--    status. 098 replaces the typed hours with the benchmark estimate.
--
--  Fixture: db/097_fixture_test.sql. JS twins: app/assets/scope-math.js.
-- ============================================================================

-- ------------------------------------------------------------ scope_months --
create or replace function scope_months(p_scope_id uuid)
returns table (
  scope_deal_id uuid, scope_line_id uuid, kind line_kind, label text, month date,
  media_funding media_funding, budget bigint, amount bigint, hours numeric,
  fee bigint, gp bigint, billable bigint, agency_media_out bigint, pass_through bigint, rebate bigint
) as $$
with lines as (
  select sd.id as scope_deal_id, sl.id as scope_line_id, sl.kind, sl.label, sl.media_funding,
         gs.month::date as month,
         coalesce(slm.amount, sl.amount) as amount,
         coalesce(slm.budget, sl.budget) as budget,
         coalesce(slm.hours,  sl.hours_per_month) as hours,
         sl.fee_pct, sl.rate, sl.structure,
         coalesce(sl.margin_pct,
           (select (value #>> '{}')::numeric from settings where key = 'programmatic_margin_default'), 35) as margin_pct
  from scope_deals sd
  join scope_lines sl on sl.scope_deal_id = sd.id
  cross join lateral generate_series(date_trunc('month', sd.flight_start), date_trunc('month', sd.flight_end), interval '1 month') gs(month)
  left join scope_line_months slm on slm.scope_line_id = sl.id and slm.month = gs.month::date
  where sd.scope_id = p_scope_id and sd.flight_start is not null and sd.flight_end is not null
),
calc as (
  select l.*,
         line_fee(l.budget, l.fee_pct, l.structure) as fee_raw,
         case l.kind
           when 'retainer'     then l.amount::numeric
           when 'custom'       then l.amount::numeric
           when 'creative'     then case when l.label like 'creative:hourly%' then round(l.rate * l.hours) else l.amount end
           when 'hourly'       then round(l.rate * l.hours)
           when 'search'       then round(line_fee(l.budget, l.fee_pct, l.structure))
           when 'social'       then round(line_fee(l.budget, l.fee_pct, l.structure))
           when 'programmatic' then round(l.budget * l.margin_pct / 100 + line_fee(l.budget, l.fee_pct, l.structure))
         end as gp_n
  from lines l
)
select c.scope_deal_id, c.scope_line_id, c.kind, c.label, c.month, c.media_funding, c.budget, c.amount, c.hours,
  -- the fee the client sees: the media fee for media kinds, the whole line for the rest
  case when c.kind in ('search', 'social', 'programmatic') then round(c.fee_raw)::bigint else c.gp_n::bigint end as fee,
  c.gp_n::bigint as gp,
  case c.kind
    when 'programmatic' then c.budget + round(c.fee_raw)::bigint
    else c.gp_n::bigint
  end as billable,
  case when c.kind in ('search', 'social') and c.media_funding = 'agency' then c.budget else 0 end as agency_media_out,
  case when c.kind in ('search', 'social') and c.media_funding = 'agency' then c.budget else 0 end as pass_through,
  round(line_rebate(c.budget,
                    case when c.kind in ('search', 'social', 'programmatic') then c.fee_raw else c.gp_n end,
                    nullif(c.structure #>> '{rebate,pct}', '')::numeric,
                    c.structure #>> '{rebate,basis}'))::bigint as rebate
from calc c;
$$ language sql stable;

comment on function scope_months(uuid) is
  'The scope''s commercial plan as money per line per month — the twin of v_deal_month_forecast (087, 099) with fee and rebate appended. gp is pre-rebate. JS twin: lineMonth in app/assets/scope-math.js.';

-- ------------------------------------------------------------- scope_labor --
create or replace function scope_labor(p_scope_id uuid)
returns table (
  month date, hours numeric, cost bigint,
  named_hours numeric, placeholder_hours numeric, unassigned_hours numeric, unpriced_hours numeric,
  cost_lo bigint, cost_hi bigint
) as $$
with named as (
  select m.staff_id, m.department, m.month, sum(m.hours) as hours
  from scope_staff_months m where m.scope_id = p_scope_id and m.staff_id is not null
  group by m.staff_id, m.department, m.month
),
named_rates as materialized (
  select staff_id, month, staff_hourly_cost(staff_id, month) as rate
  from (select distinct staff_id, month from named) x
),
placeholders as (
  select m.department, m.band, m.month, sum(m.hours) as hours
  from scope_staff_months m where m.scope_id = p_scope_id and m.staff_id is null
  group by m.department, m.band, m.month
),
demand as (
  select department, month, hours from scope_dept_months where scope_id = p_scope_id
),
supplied as (
  select department, month, sum(hours) as hours from (
    select department, month, hours from named
    union all
    select department, month, hours from placeholders) u
  group by department, month
),
unassigned as (
  select d.department, d.month, greatest(d.hours - coalesce(s.hours, 0), 0) as hours
  from demand d left join supplied s on s.department = d.department and s.month = d.month
  where d.hours - coalesce(s.hours, 0) > 0
),
-- one band_rate call per distinct (department, band, month) needed
dept_keys as (
  select department, band, month from placeholders
  union
  select department, null::text, month from unassigned
),
dept_rates as materialized (
  select department, band, month, band_rate(department, band, month) as rate from dept_keys
),
bands as (
  select t.b ->> 'name' as name
  from settings s, jsonb_array_elements(s.value) t(b)
  where s.key = 'scope_comp_bands' and jsonb_typeof(s.value) = 'array'
),
range_keys as (
  select distinct department, month from (
    select department, month from placeholders union all select department, month from unassigned) u
),
band_extremes as materialized (
  select k.department, k.month,
         min(band_rate(k.department, b.name, k.month)) as lo,
         max(band_rate(k.department, b.name, k.month)) as hi
  from range_keys k cross join bands b
  group by k.department, k.month
),
rows_ as (
  select n.month, n.hours, r.rate, 'named' as src, n.department
  from named n join named_rates r on r.staff_id = n.staff_id and r.month = n.month
  union all
  select p.month, p.hours, dr.rate, 'placeholder', p.department
  from placeholders p join dept_rates dr on dr.department = p.department and dr.band is not distinct from p.band and dr.month = p.month
  union all
  select u.month, u.hours, dr.rate, 'unassigned', u.department
  from unassigned u join dept_rates dr on dr.department = u.department and dr.band is null and dr.month = u.month
),
months as (select distinct month from rows_)
select m.month,
  coalesce((select sum(hours) from rows_ r where r.month = m.month), 0)::numeric as hours,
  coalesce((select sum(round(hours * rate)) from rows_ r where r.month = m.month and r.rate is not null), 0)::bigint as cost,
  coalesce((select sum(hours) from rows_ r where r.month = m.month and r.src = 'named'), 0)::numeric as named_hours,
  coalesce((select sum(hours) from rows_ r where r.month = m.month and r.src = 'placeholder'), 0)::numeric as placeholder_hours,
  coalesce((select sum(hours) from rows_ r where r.month = m.month and r.src = 'unassigned'), 0)::numeric as unassigned_hours,
  coalesce((select sum(hours) from rows_ r where r.month = m.month and r.rate is null), 0)::numeric as unpriced_hours,
  -- the range: named hours as priced, every other hour at the department's cheapest / dearest band
  (coalesce((select sum(round(hours * rate)) from rows_ r where r.month = m.month and r.src = 'named' and r.rate is not null), 0)
   + coalesce((select sum(round(r.hours * coalesce(be.lo, r.rate))) from rows_ r
               left join band_extremes be on be.department = r.department and be.month = r.month
               where r.month = m.month and r.src <> 'named' and coalesce(be.lo, r.rate) is not null), 0))::bigint as cost_lo,
  (coalesce((select sum(round(hours * rate)) from rows_ r where r.month = m.month and r.src = 'named' and r.rate is not null), 0)
   + coalesce((select sum(round(r.hours * coalesce(be.hi, r.rate))) from rows_ r
               left join band_extremes be on be.department = r.department and be.month = r.month
               where r.month = m.month and r.src <> 'named' and coalesce(be.hi, r.rate) is not null), 0))::bigint as cost_hi
from months m
order by m.month;
$$ language sql stable;

comment on function scope_labor(uuid) is
  'Labor per month as ONE number: named hours × staff_hourly_cost (materialized per staff/month), placeholder hours × band_rate, uncovered demand × department average. Returns totals only — no per-person or per-department cost ever leaves SQL (salary privacy). cost_lo/cost_hi price the non-named hours at the department''s cheapest/dearest band.';

-- ----------------------------------------------------------- scope_staffing --
create or replace function scope_staffing(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
with sc as (select * from scopes where id = p_scope_id),
flight as (
  select min(flight_start) as f0, max(flight_end) as f1 from scope_deals where scope_id = p_scope_id and flight_start is not null
),
months as (
  select gs::date as month from flight, generate_series(date_trunc('month', f0), date_trunc('month', f1), interval '1 month') gs
  where f0 is not null
),
kinds as (select distinct sl.kind from scope_lines sl join scope_deals sd on sd.id = sl.scope_deal_id where sd.scope_id = p_scope_id),
demand as (select department, month, hours from scope_dept_months where scope_id = p_scope_id),
named as (
  select department, month, sum(hours) as hours from scope_staff_months
  where scope_id = p_scope_id and staff_id is not null group by department, month
),
placeholders as (
  select department, month, sum(hours) as hours from scope_staff_months
  where scope_id = p_scope_id and staff_id is null group by department, month
),
gap as (
  select d.department, d.month, d.hours as demand,
         coalesce(n.hours, 0) as named, coalesce(p.hours, 0) as placeholder,
         greatest(d.hours - coalesce(n.hours, 0) - coalesce(p.hours, 0), 0) as unassigned
  from demand d
  left join named n on n.department = d.department and n.month = d.month
  left join placeholders p on p.department = d.department and p.month = d.month
),
cap as (
  select c.staff_id, c.month, c.capacity_hours,
         c.committed_hours - coalesce((select sum(a.hours) from assignments a
                                       where a.scope_id = p_scope_id and a.staff_id = c.staff_id and a.month = c.month), 0) as committed_other
  from flight, staff_capacity(f0, f1) c
  where f0 is not null
),
cand_base as (
  select s.id as staff_id, s.name, s.department,
         coalesce((select sum(te.hours) from time_entries te
                   where te.staff_id = s.id and te.client_id = (select client_id from sc)
                     and te.worked_on >= current_date - interval '12 months'
                     and coalesce(te.attribution, '') not in ('excluded', 'timeoff')), 0) as client_hours,
         coalesce((select sum(te.hours) from time_entries te
                   join deal_lines dl on dl.deal_id = te.deal_id
                   where te.staff_id = s.id and dl.kind in (select kind from kinds)
                     and te.worked_on >= current_date - interval '12 months'
                     and coalesce(te.attribution, '') not in ('excluded', 'timeoff')), 0) as kind_hours,
         coalesce((select sum(greatest(c.capacity_hours - c.committed_other, 0)) from cap c where c.staff_id = s.id), 0) as free_total,
         staff_hourly_cost(s.id, coalesce((select f0 from flight), current_date)) as rate
  from staff s
  where s.active and s.tracks_capacity and not s.exclude_hours
),
cands as (
  select cb.*, row_number() over (partition by cb.department order by cb.client_hours desc, cb.kind_hours desc, cb.free_total desc, cb.rate asc nulls last, cb.name) as rank
  from cand_base cb
),
-- hours no free person in the department can cover, per month
dept_free as (
  select cb.department, c.month, sum(greatest(c.capacity_hours - c.committed_other, 0)) as free_hours
  from cand_base cb join cap c on c.staff_id = cb.staff_id
  group by cb.department, c.month
),
unstaffable as (
  select g.department, g.month, g.unassigned + g.placeholder as open_hours,
         greatest(g.unassigned + g.placeholder - coalesce(df.free_hours, 0), 0) as unstaffable
  from gap g left join dept_free df on df.department = g.department and df.month = g.month
),
knobs as (
  select coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_hire_fte_share_pct'), 50) as fte_share,
         coalesce((select (value #>> '{}')::int from settings where key = 'scope_hire_min_months'), 2) as min_months,
         coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_utilization_pct'), 80) as util
),
fte as (
  -- a full-time plannable month: 40 h/wk ÷ 5 × business days × utilization
  select m.month, round(40.0 / 5 * (select count(*) from generate_series(m.month, (m.month + interval '1 month - 1 day')::date, interval '1 day') d
                                     where extract(isodow from d) < 6) * (select util from knobs) / 100, 2) as fte_hours
  from months m
),
hire as (
  select u.department,
         sum(u.unstaffable) as hours,
         count(*) filter (where u.unstaffable >= (select fte_share from knobs) / 100 * f.fte_hours) as heavy_months,
         jsonb_object_agg(u.month::text, u.unstaffable) filter (where u.unstaffable > 0) as by_month,
         hire_hourly_cost(u.department) as hire_hourly_c,
         contractor_hourly_cost(u.department) as contractor_hourly_c
  from unstaffable u join fte f on f.month = u.month
  group by u.department
  having sum(u.unstaffable) > 0
)
select jsonb_build_object(
  'months', coalesce((select jsonb_agg(month order by month) from months), '[]'::jsonb),
  'gap', coalesce((select jsonb_agg(jsonb_build_object(
      'department', department, 'month', month, 'demand', demand, 'named', named,
      'placeholder', placeholder, 'unassigned', unassigned) order by department, month) from gap), '[]'::jsonb),
  'candidates', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', c.staff_id, 'name', c.name, 'department', c.department, 'rank', c.rank,
      'client_hours', round(c.client_hours, 1), 'kind_hours', round(c.kind_hours, 1),
      'free', coalesce((select jsonb_object_agg(cp.month::text, round(greatest(cp.capacity_hours - cp.committed_other, 0), 2))
                        from cap cp where cp.staff_id = c.staff_id), '{}'::jsonb))
      order by c.department, c.rank) from cands c), '[]'::jsonb),
  'unstaffable', coalesce((select jsonb_agg(jsonb_build_object(
      'department', department, 'month', month, 'open_hours', open_hours, 'unstaffable', unstaffable)
      order by department, month) from unstaffable where unstaffable > 0), '[]'::jsonb),
  'hire', coalesce((select jsonb_agg(jsonb_build_object(
      'department', h.department, 'hours', h.hours, 'by_month', h.by_month,
      'recommend', h.heavy_months >= (select min_months from knobs),
      'heavy_months', h.heavy_months,
      'hire_hourly_c', h.hire_hourly_c, 'contractor_hourly_c', h.contractor_hourly_c,
      'cost_hire', case when h.hire_hourly_c is null then null else round(h.hours * h.hire_hourly_c)::bigint end,
      'cost_contractor', case when h.contractor_hourly_c is null then null else round(h.hours * h.contractor_hourly_c)::bigint end)
      order by h.department) from hire h), '[]'::jsonb),
  'knobs', (select to_jsonb(k) from knobs k)
);
$$;

comment on function scope_staffing(uuid) is
  'Demand vs supply per department per month, ranked candidates (client history → kind history → free hours → cost; rank only, never the rate), free hours per candidate per flight month (staff_capacity minus this scope''s own approved rows), unstaffable hours and the hire / contractor option per department.';

-- --------------------------------------------------------- auto_staff_scope --
create or replace function auto_staff_scope(p_scope_id uuid, p_by text)
returns jsonb
language plpgsql
as $$
declare
  st jsonb; g record; c record; v_free numeric; v_alloc numeric; v_written int := 0;
  v_gap numeric; v_dept text; m text;
begin
  delete from scope_staff_months where scope_id = p_scope_id and source = 'auto';
  st := scope_staffing(p_scope_id);
  -- per department: candidates in rank order, each takes what they are free
  -- for in EVERY month before the next one is considered (fewest people)
  for v_dept in select distinct (x ->> 'department') from jsonb_array_elements(st -> 'gap') x
                where (x ->> 'unassigned')::numeric > 0 loop
    create temp table if not exists _as_gap (department text, month date, gap numeric) on commit drop;
    delete from _as_gap where department = v_dept;
    insert into _as_gap select v_dept, (x ->> 'month')::date, (x ->> 'unassigned')::numeric
      from jsonb_array_elements(st -> 'gap') x where x ->> 'department' = v_dept and (x ->> 'unassigned')::numeric > 0;
    for c in select (x ->> 'staff_id')::uuid as staff_id, x -> 'free' as free
             from jsonb_array_elements(st -> 'candidates') x
             where x ->> 'department' = v_dept order by (x ->> 'rank')::int loop
      exit when not exists (select 1 from _as_gap where department = v_dept and gap > 0);
      for g in select * from _as_gap where department = v_dept and gap > 0 order by month loop
        v_free := coalesce((c.free ->> g.month::text)::numeric, 0)
                  - coalesce((select sum(hours) from scope_staff_months
                              where scope_id = p_scope_id and staff_id = c.staff_id and month = g.month), 0);
        v_alloc := least(g.gap, greatest(v_free, 0));
        if v_alloc > 0 then
          insert into scope_staff_months (scope_id, staff_id, department, month, hours, source)
          values (p_scope_id, c.staff_id, v_dept, g.month, round(v_alloc, 2), 'auto')
          on conflict (scope_id, staff_id, month, source) where staff_id is not null
          do update set hours = scope_staff_months.hours + excluded.hours;
          update _as_gap set gap = gap - v_alloc where department = v_dept and month = g.month;
          v_written := v_written + 1;
        end if;
      end loop;
    end loop;
  end loop;
  return jsonb_build_object('ok', true, 'rows_written', v_written);
end;
$$;

comment on function auto_staff_scope(uuid, text) is
  'Fills each department''s unassigned demand with named people in scope_staffing rank order, fewest people first (a candidate takes their free hours in every month before the next is used). Writes source auto rows only; manual rows and placeholders stay.';

-- ------------------------------------------------------------ scope_verdict --
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
  select v.month, sum(v.gp)::bigint as gp
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

comment on function scope_verdict(uuid) is
  'Is the scope viable: per month gp, rebate, labor (one number), pal = gp − rebate − labor, profit per hour vs scope_target_profit_per_hour; checks; status go | go_with_hire | go_with_contractor | no_go | unclear; per-person capacity rows for the named plan; the client roll-up (existing deals measured + planned, plus this scope).';

-- --------------------------------------------------------------- scope_page --
create or replace function scope_page(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
select scope_state(p_scope_id)
  || jsonb_build_object(
  'econ', coalesce((select jsonb_agg(to_jsonb(m) order by m.month, m.scope_line_id) from scope_months(p_scope_id) m), '[]'::jsonb),
  'labor', coalesce((select jsonb_agg(to_jsonb(l) order by l.month) from scope_labor(p_scope_id) l), '[]'::jsonb),
  'staffing', scope_staffing(p_scope_id),
  'verdict', scope_verdict(p_scope_id),
  'versions', coalesce((select jsonb_agg(jsonb_build_object(
      'id', v.id, 'version', v.version, 'reason', v.reason, 'label', v.label, 'saved_by', v.saved_by, 'saved_at', v.saved_at)
      order by v.version desc) from scope_versions v where v.scope_id = p_scope_id), '[]'::jsonb),
  'siblings', coalesce((select jsonb_agg(jsonb_build_object(
      'id', s2.id, 'name', s2.name, 'scenario', s2.scenario, 'status', s2.status, 'version', s2.version,
      'kpis', (scope_verdict(s2.id) -> 'total') || jsonb_build_object('status', scope_verdict(s2.id) ->> 'status'))
      order by s2.created_at) from scopes s2
      where s2.family_id = (select family_id from scopes where id = p_scope_id)), '[]'::jsonb),
  'staff', coalesce((select jsonb_agg(jsonb_build_object(
      'id', s.id, 'name', s.name, 'department', s.department, 'active', s.active, 'tracks_capacity', s.tracks_capacity)
      order by s.name) from staff s where s.active and s.tracks_capacity and not s.exclude_hours), '[]'::jsonb),
  'departments', coalesce((select jsonb_agg(distinct s.department) from staff s
      where s.active and s.tracks_capacity and s.department is not null), '[]'::jsonb),
  'clients', coalesce((select jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name) order by c.name) from clients c where c.active), '[]'::jsonb),
  'settings', jsonb_build_object(
      'per_hour', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_profit_per_hour'), 150),
      'utilization_pct', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_utilization_pct'), 80),
      'prog_target_gp_pct', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_prog_target_gp_pct'), 40),
      'cpm_platform_share_pct', coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_cpm_platform_share_pct'), 50),
      'margin_default', coalesce((select (value #>> '{}')::numeric from settings where key = 'programmatic_margin_default'), 35),
      'approvers', coalesce((select value from settings where key = 'scope_approver_emails'), '[]'::jsonb),
      'comp_bands', coalesce((select value from settings where key = 'scope_comp_bands'), '[]'::jsonb),
      'hire_costs', coalesce((select value from settings where key = 'scope_hire_costs'), '{}'::jsonb)),
  'sources', jsonb_build_object(
      'pipeline', coalesce((select jsonb_agg(jsonb_build_object(
          'hubspot_deal_id', pd.hubspot_deal_id, 'name', pd.name, 'company', pd.company, 'amount', pd.amount,
          'campaign_start', pd.campaign_start, 'campaign_end', pd.campaign_end, 'stage', pd.stage, 'url', pd.url))
          from pipeline_deals pd where pd.hubspot_deal_id in
            (select hubspot_deal_id from scope_deals where scope_id = p_scope_id and hubspot_deal_id is not null)), '[]'::jsonb),
      'deals', coalesce((select jsonb_agg(jsonb_build_object(
          'id', d.id, 'name', d.name, 'client_id', d.client_id, 'flight_start', d.flight_start, 'flight_end', d.flight_end, 'status', d.status))
          from deals d where d.id in
            (select source_deal_id from scope_deals where scope_id = p_scope_id and source_deal_id is not null
             union select promoted_deal_id from scope_deals where scope_id = p_scope_id and promoted_deal_id is not null)), '[]'::jsonb))
);
$$;

comment on function scope_page(uuid) is
  'One round trip for app/scoping.html: the editable state (scope_state), econ per line-month, labor totals, staffing, verdict, versions, scenario siblings with KPIs, roster without rates, departments, clients, knobs, source rows.';

-- --------------------------------------------------------------- lifecycle --
create or replace function set_scope_status(p_scope_id uuid, p_status text, p_by text)
returns jsonb
language plpgsql
as $$
declare v_status text;
begin
  select status into v_status from scopes where id = p_scope_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;
  if p_status not in ('draft', 'proposed') then
    return jsonb_build_object('ok', false, 'reason', 'use approve_scope / unapprove_scope / promote_scope for that');
  end if;
  if v_status in ('approved', 'promoted') then
    return jsonb_build_object('ok', false, 'reason', 'an ' || v_status || ' scope must be un-approved first');
  end if;
  update scopes set status = p_status, set_by = p_by, set_at = now() where id = p_scope_id;
  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

create or replace function approve_scope(p_scope_id uuid, p_by text)
returns jsonb
language plpgsql
as $$
declare v_status text; v_n int; v_version int;
begin
  perform pg_advisory_xact_lock(hashtext('save_scope'), hashtext(p_scope_id::text));
  select status into v_status from scopes where id = p_scope_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;
  if not scope_is_approver(p_by) then
    return jsonb_build_object('ok', false, 'reason', 'only an approver (Settings › Scoping) can approve');
  end if;
  if v_status <> 'proposed' then
    return jsonb_build_object('ok', false, 'reason', 'a scope is approved from proposed (it is ' || v_status || ')');
  end if;
  update scopes set status = 'approved', approved_by = p_by, approved_at = now(), set_by = p_by, set_at = now()
  where id = p_scope_id;
  -- reserve the NAMED hours; placeholders have nobody to reserve
  delete from assignments where scope_id = p_scope_id;
  insert into assignments (staff_id, deal_id, scope_id, month, hours, set_by)
  select staff_id, null, p_scope_id, month, sum(hours), 'scope:approve'
  from scope_staff_months where scope_id = p_scope_id and staff_id is not null
  group by staff_id, month having sum(hours) > 0;
  get diagnostics v_n = row_count;
  v_version := scope_snapshot(p_scope_id, 'approve', 'approved by ' || p_by, p_by);
  return jsonb_build_object('ok', true, 'status', 'approved', 'assignments_written', v_n, 'version', v_version);
end;
$$;

create or replace function unapprove_scope(p_scope_id uuid, p_by text)
returns jsonb
language plpgsql
as $$
declare v_status text; v_n int; v_version int;
begin
  perform pg_advisory_xact_lock(hashtext('save_scope'), hashtext(p_scope_id::text));
  select status into v_status from scopes where id = p_scope_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;
  if not scope_is_approver(p_by) then
    return jsonb_build_object('ok', false, 'reason', 'only an approver can un-approve');
  end if;
  if v_status <> 'approved' then
    return jsonb_build_object('ok', false, 'reason', 'only an approved scope can be un-approved (it is ' || v_status || ')');
  end if;
  update scopes set status = 'proposed', approved_by = null, approved_at = null, set_by = p_by, set_at = now()
  where id = p_scope_id;
  delete from assignments where scope_id = p_scope_id;
  get diagnostics v_n = row_count;
  v_version := scope_snapshot(p_scope_id, 'unapprove', 'un-approved by ' || p_by, p_by);
  return jsonb_build_object('ok', true, 'status', 'proposed', 'assignments_deleted', v_n, 'version', v_version);
end;
$$;

comment on function approve_scope(uuid, text) is
  'Approvers only, from proposed: sets approved, snapshots a version, and reserves the scope''s NAMED hours in assignments (deal_id null, scope_id set, set_by scope:approve). Placeholders are never written.';

-- -------------------------------------------------------------- quick_check --
-- One kind, a few numbers, an answer. p_hours is {department: hours per
-- month}; 098 fills it from the benchmarks when the caller passes none.
create or replace function quick_check(p_kind text, p_budget_c bigint, p_fee_pct numeric, p_months int,
                                       p_hours jsonb, p_amount_c bigint default 0, p_margin_pct numeric default null)
returns jsonb
language sql
stable
as $$
with k as (
  select greatest(coalesce(p_months, 1), 1) as n,
         coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_profit_per_hour'), 150) * 100 as target_c,
         coalesce(p_margin_pct, (select (value #>> '{}')::numeric from settings where key = 'programmatic_margin_default'), 35) as margin
),
gp1 as (
  select case p_kind
    when 'search' then round(line_fee(p_budget_c, p_fee_pct, '{}'::jsonb))
    when 'social' then round(line_fee(p_budget_c, p_fee_pct, '{}'::jsonb))
    when 'programmatic' then round(p_budget_c * (select margin from k) / 100 + line_fee(p_budget_c, p_fee_pct, '{}'::jsonb))
    else coalesce(p_amount_c, 0) end as gp_month
),
hrs as (
  select key as department, value::numeric as hours from jsonb_each_text(coalesce(p_hours, '{}'::jsonb))
),
lab as (
  select sum(h.hours) as hours,
         sum(round(h.hours * coalesce(band_rate(h.department, null, date_trunc('month', current_date)::date), 0))) as cost,
         bool_or(band_rate(h.department, null, date_trunc('month', current_date)::date) is null) as unpriced
  from hrs h
)
select jsonb_build_object(
  'months', (select n from k),
  'gp_month', (select gp_month from gp1)::bigint,
  'gp', ((select gp_month from gp1) * (select n from k))::bigint,
  'hours_month', coalesce((select hours from lab), 0),
  'labor_month', coalesce((select cost from lab), 0)::bigint,
  'labor', (coalesce((select cost from lab), 0) * (select n from k))::bigint,
  'pal_month', ((select gp_month from gp1) - coalesce((select cost from lab), 0))::bigint,
  'per_hour_c', case when coalesce((select hours from lab), 0) > 0
                     then round(((select gp_month from gp1) - coalesce((select cost from lab), 0)) / (select hours from lab)) end,
  'target_c', (select target_c from k),
  'status', case
    when coalesce((select hours from lab), 0) = 0 then 'unclear'
    when coalesce((select unpriced from lab), false) then 'unclear'
    when (select gp_month from gp1) - (select cost from lab) < 0 then 'no_go'
    when round(((select gp_month from gp1) - (select cost from lab)) / (select hours from lab)) >= (select target_c from k) then 'go'
    else 'no_go' end
);
$$;

comment on function quick_check(text, bigint, numeric, int, jsonb, bigint, numeric) is
  'The list view''s 30-second answer for one flat line: monthly gp from the shared primitives, labor at department averages for the typed hours per department, pal, profit per hour vs target, status. 098 fills the hours from the benchmarks.';
