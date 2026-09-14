-- 111_scope_interactive.sql — the Scoping editor stops recomputing what cannot
-- have changed.
--
-- Three things, none of which changes a number:
--
--   1. Every scenario in a family paid a FULL scope_verdict on every open —
--      and, through preview_scope, on every pause in typing. A family of three
--      scenarios cost 427 ms in the PGlite bed where one cost 106. But
--      scope_verdict_calc reads exactly one thing out of the staffing payload
--      it is handed: `hire`. The candidate ranking (a twelve-month scan of
--      time_entries per call) is for the editor's staffing panel and has no
--      effect on the verdict at all. Split in two — scope_gap_hire, which is
--      everything but the ranking, and scope_staffing, which is
--      scope_gap_hire plus the ranking — and a sibling's verdict becomes
--      scope_verdict_light: byte-identical by construction, because the input
--      it drops is never read. 111_fixture_test asserts that equality directly.
--
--   2. preview_scope built the WHOLE page — siblings, versions, the staff
--      roster, the client list, the settings, the sources — and the editor
--      merged six keys out of it and dropped the rest (app/scoping.html's
--      runPreview: econ, labor, staffing, verdict, existing_deals,
--      prog_margin). Those six are now scope_core, which is what a preview
--      returns and what scope_page builds its own answer on, so there is one
--      copy of the sequencing and the editor's merge is unchanged.
--
--   3. scoping_list shipped the entire pipeline_deals mirror — 375 KB of the
--      436 KB payload in the bed — and app/scoping.html threw most of it away
--      on arrival. The same filter now runs in SQL: promoted, dismissed,
--      already-scoped, off-pipeline, under the probability floor, or finished
--      before 2026. The page keeps its own filter (it then removes nothing),
--      so it still works against a database without this migration.

-- ---------------------------------------------------------------------------
--  1. scope_gap_hire — scope_staffing without the candidate ranking: the
--     department gap, what no one free can cover, and the hire/contractor
--     option. This is everything the VERDICT can see.
-- ---------------------------------------------------------------------------
create or replace function scope_gap_hire(p_scope_id uuid)
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
-- the plannable population — the same people cand_base ranks, without the
-- twelve-month history join that only the ranking reads
plannable as (
  select s.id as staff_id, s.department from staff s
  where s.active and s.tracks_capacity and not s.exclude_hours
),
-- hours no free person in the department can cover, per month
dept_free as (
  select pb.department, c.month, sum(greatest(c.capacity_hours - c.committed_other, 0)) as free_hours
  from plannable pb join cap c on c.staff_id = pb.staff_id
  group by pb.department, c.month
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

comment on function scope_gap_hire(uuid) is
  'The department gap, the hours nobody free can cover, and the hire / '
  'contractor option — scope_staffing (105) without its candidate ranking, '
  'which is the only part that scans a year of time_entries and the only part '
  'the verdict never reads (111). scope_staffing is this plus the ranking; '
  'scope_verdict_light is the verdict from this alone.';

-- ---------------------------------------------------------------------------
--  2. scope_staffing — 105's payload, key for key: this, plus the ranking.
-- ---------------------------------------------------------------------------
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
-- 105: one pass over the last twelve months of counted hours for everyone,
-- and the rate from the per-month rates table — not a burden-stack call per person
te12 as (
  select te.staff_id, te.client_id, te.deal_id, te.hours from time_entries te
  where te.staff_id is not null and te.worked_on >= current_date - interval '12 months'
    and coalesce(te.attribution, '') not in ('excluded', 'timeoff')
),
kind_deals as (select distinct dl.deal_id from deal_lines dl where dl.kind in (select kind from kinds)),
hist as (
  select staff_id,
         sum(hours) filter (where client_id = (select client_id from sc)) as client_hours,
         sum(hours) filter (where deal_id in (select deal_id from kind_deals)) as kind_hours
  from te12 group by staff_id
),
rates0 as materialized (select * from flight, staff_rates_months(f0, f0) where f0 is not null),
cand_base as (
  select s.id as staff_id, s.name, s.department,
         coalesce(h.client_hours, 0) as client_hours,
         coalesce(h.kind_hours, 0) as kind_hours,
         coalesce((select sum(greatest(c.capacity_hours - c.committed_other, 0)) from cap c where c.staff_id = s.id), 0) as free_total,
         (select r.rate from rates0 r where r.staff_id = s.id limit 1) as rate
  from staff s
  left join hist h on h.staff_id = s.id
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
select scope_gap_hire(p_scope_id) || jsonb_build_object(
  'candidates', coalesce((select jsonb_agg(jsonb_build_object(
      'staff_id', c.staff_id, 'name', c.name, 'department', c.department, 'rank', c.rank,
      'client_hours', round(c.client_hours, 1), 'kind_hours', round(c.kind_hours, 1),
      'free', coalesce((select jsonb_object_agg(cp.month::text, round(greatest(cp.capacity_hours - cp.committed_other, 0), 2))
                        from cap cp where cp.staff_id = c.staff_id), '{}'::jsonb))
      order by c.department, c.rank) from cands c), '[]'::jsonb)
);
$$;

comment on function scope_staffing(uuid) is
  'Who should staff this scope: 105''s payload, key for key. 111 takes months / '
  'gap / unstaffable / hire / knobs from scope_gap_hire and adds only the '
  'candidate ranking — client history, then kind history, then free hours, then '
  'cost (rank only) — so nothing that reads just the hire option has to pay for '
  'a year of time_entries.';

-- ---------------------------------------------------------------------------
--  3. scope_verdict_light — the verdict a sibling scenario's KPI strip needs.
--     scope_verdict_calc reads `hire` out of the staffing payload and nothing
--     else, so handing it scope_gap_hire gives the same answer as handing it
--     the full scope_staffing. Not "close enough": the same, and
--     111_fixture_test asserts it scope by scope.
-- ---------------------------------------------------------------------------
create or replace function scope_verdict_light(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
  select scope_verdict_calc(
    p_scope_id,
    coalesce((select jsonb_agg(to_jsonb(m) order by m.month, m.scope_line_id) from scope_months(p_scope_id) m), '[]'::jsonb),
    coalesce((select jsonb_agg(to_jsonb(l) order by l.month) from scope_labor(p_scope_id) l), '[]'::jsonb),
    scope_gap_hire(p_scope_id));
$$;

comment on function scope_verdict_light(uuid) is
  'scope_verdict(id) without the candidate ranking — identical output, because '
  'scope_verdict_calc reads only `hire` from the staffing payload (111). Used '
  'for the sibling scenarios'' KPI strip, where a family of three was paying '
  'three full rankings to draw three headline numbers.';

-- ---------------------------------------------------------------------------
--  4. scope_core — the six keys the editor re-reads when the numbers move.
--     app/scoping.html's runPreview merges exactly these and drops everything
--     else scope_page returns, so a preview builds exactly these.
-- ---------------------------------------------------------------------------
create or replace function scope_core(p_scope_id uuid)
returns jsonb
language plpgsql
stable
as $$
declare v_econ jsonb; v_labor jsonb; v_staffing jsonb;
begin
  select coalesce(jsonb_agg(to_jsonb(m) order by m.month, m.scope_line_id), '[]'::jsonb) into v_econ from scope_months(p_scope_id) m;
  select coalesce(jsonb_agg(to_jsonb(l) order by l.month), '[]'::jsonb) into v_labor from scope_labor(p_scope_id) l;
  v_staffing := scope_staffing(p_scope_id);
  return jsonb_build_object(
    'econ', v_econ,
    'labor', v_labor,
    'staffing', v_staffing,
    'verdict', scope_verdict_calc(p_scope_id, v_econ, v_labor, v_staffing),
    'existing_deals', scope_existing_deals(p_scope_id),
    'prog_margin', scope_prog_margin(p_scope_id));
end;
$$;

comment on function scope_core(uuid) is
  'Everything about a scope that changes when its numbers change: econ, labor, '
  'staffing, verdict, existing_deals, prog_margin (111). scope_page is this '
  'plus the context around it; preview_scope is exactly this, because that is '
  'exactly what the editor merges.';

-- ---------------------------------------------------------------------------
--  5. scope_page — 106's body, two lines different: the six moving keys come
--     from scope_core, and a sibling's KPI comes from scope_verdict_light.
-- ---------------------------------------------------------------------------
create or replace function scope_page(p_scope_id uuid)
returns jsonb
language plpgsql
as $$
declare
  v_family uuid; v_f0 date; v_f1 date;
  v_core jsonb; v_verdict jsonb;
begin
  select family_id into v_family from scopes where id = p_scope_id;
  if v_family is null then return null; end if;
  -- warm the rate memo over everything this page prices: the family's flights
  -- and hour rows (siblings' verdicts price too)
  select min(x.m0), max(x.m1) into v_f0, v_f1 from (
    select sd.flight_start as m0, sd.flight_end as m1 from scope_deals sd join scopes s on s.id = sd.scope_id where s.family_id = v_family
    union all select dm.month, dm.month from scope_dept_months dm join scopes s on s.id = dm.scope_id where s.family_id = v_family
    union all select sm.month, sm.month from scope_staff_months sm join scopes s on s.id = sm.scope_id where s.family_id = v_family) x;
  perform staff_rate_cache_fill(v_f0, v_f1);

  -- 111: the six keys that move when the numbers move, computed once; a
  -- preview asks for exactly this object and nothing around it
  v_core := scope_core(p_scope_id);
  v_verdict := v_core -> 'verdict';

  return scope_state(p_scope_id)
    || v_core
    || jsonb_build_object(
    'versions', coalesce((select jsonb_agg(jsonb_build_object(
        'id', v.id, 'version', v.version, 'reason', v.reason, 'label', v.label, 'saved_by', v.saved_by, 'saved_at', v.saved_at)
        order by v.version desc) from scope_versions v where v.scope_id = p_scope_id), '[]'::jsonb),
    'siblings', coalesce((select jsonb_agg(jsonb_build_object(
        'id', s2.id, 'name', s2.name, 'scenario', s2.scenario, 'status', s2.status, 'version', s2.version,
        'kpis', (v.j -> 'total') || jsonb_build_object('status', v.j ->> 'status'))
        order by s2.created_at) from scopes s2
        -- 111: the open scope reuses its own; a SIBLING gets the light verdict,
        -- which is the same numbers without the candidate ranking it is not
        -- going to show (a family of three was paying three full rankings here)
        cross join lateral (select case when s2.id = p_scope_id then v_verdict else scope_verdict_light(s2.id) end as j) v
        where s2.family_id = v_family), '[]'::jsonb),
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
        'hire_costs', coalesce((select value from settings where key = 'scope_hire_costs'), '{}'::jsonb),
        'min_margin_presets', coalesce((select value from settings where key = 'scope_min_margin_presets'), '[]'::jsonb),   -- 103
        'kind_departments', coalesce((select value from settings where key = 'scope_kind_departments'), '{}'::jsonb),        -- 104
        'always_departments', coalesce((select value from settings where key = 'scope_always_departments'), '[]'::jsonb)),
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
end;
$$;

-- ---------------------------------------------------------------------------
--  6. preview_scope — 107's body, returning scope_core instead of scope_page.
-- ---------------------------------------------------------------------------
create or replace function preview_scope(p_payload jsonb, p_by text)
returns jsonb
language plpgsql
as $$
declare r jsonb; v_id uuid; v_f0 date; v_f1 date; v_detail text;
begin
  if nullif(p_payload ->> 'id', '') is null then
    return jsonb_build_object('ok', false, 'reason', 'a preview needs a saved scope (payload.id)');
  end if;
  -- warm the rate memo over the payload's months first: the sub-transaction
  -- below is rolled back, so anything it inserts would be lost
  select min(t.m0), max(t.m1) into v_f0, v_f1 from (
    select nullif(d ->> 'flight_start', '')::date as m0, nullif(d ->> 'flight_end', '')::date as m1
    from jsonb_array_elements(coalesce(p_payload -> 'deals', '[]'::jsonb)) d
    union all
    select nullif(x ->> 'month', '')::date, nullif(x ->> 'month', '')::date
    from jsonb_array_elements(coalesce(p_payload -> 'dept_months', '[]'::jsonb)) x
    union all
    select nullif(x ->> 'month', '')::date, nullif(x ->> 'month', '')::date
    from jsonb_array_elements(coalesce(p_payload -> 'staff_months', '[]'::jsonb)) x) t;
  perform staff_rate_cache_fill(v_f0, v_f1);

  begin
    r := save_scope(p_payload, p_by, 'preview');
    if not coalesce((r ->> 'ok')::boolean, false) then return r; end if;
    v_id := (r ->> 'scope_id')::uuid;
    -- the page travels out on the exception; the exception undoes the save
    -- 111: scope_core, not scope_page. The editor's runPreview merges exactly
    -- six keys out of this reply and drops the rest, and the rest — the
    -- sibling scenarios, the versions, the staff roster, the client list, the
    -- settings, the sources — cannot have changed because someone typed in a
    -- budget box. Building them on every pause in typing was most of what a
    -- preview cost: 427 ms for a three-scenario family in the bed, because
    -- each sibling's KPI dragged a full candidate ranking behind it.
    -- scope_state as well as scope_core: the editor merges only the six moving
    -- keys, but the reply has always carried the scope's own id and editable
    -- state (db/107_fixture_test checks it), and it is a kilobyte or two.
    raise exception using errcode = 'P0001', message = 'PREVIEW_ROLLBACK',
      detail = (scope_state(v_id) || scope_core(v_id))::text;
  exception when others then
    if sqlerrm = 'PREVIEW_ROLLBACK' then
      get stacked diagnostics v_detail = pg_exception_detail;
      return jsonb_build_object('ok', true, 'page', v_detail::jsonb);
    end if;
    raise;
  end;
end;
$$;

comment on function preview_scope(jsonb, text) is
  'The scope the payload WOULD produce if saved — its state plus econ, labor, '
  'staffing, verdict, existing deals, prog margin — with nothing written: '
  'save_scope + scope_core run in a sub-transaction that a sentinel exception '
  'rolls back (the object rides out in its DETAIL). 111: scope_core, not the '
  'whole scope_page — the siblings, versions, rosters and settings it used to '
  'rebuild on every pause in typing cannot change because someone typed in a '
  'budget box, and the editor drops them anyway. Refuses approved/promoted '
  'scopes exactly as save_scope does.';

-- ---------------------------------------------------------------------------
--  7. scoping_list — the pipeline, already filtered to what the page keeps.
-- ---------------------------------------------------------------------------
create or replace function scoping_list()
returns jsonb
language sql
stable
as $$
select jsonb_build_object(
  'scopes', coalesce((select jsonb_agg(to_jsonb(x) order by x.set_at desc) from
      (select id, family_id, name, scenario, client_id, status, version, set_by, set_at, created_at, proposed_by, proposed_at from scopes) x), '[]'::jsonb),
  -- 111: the Pipeline tab's own filter, run here instead of in the browser.
  -- app/scoping.html kept exactly these rows and dropped the rest on arrival —
  -- the whole mirror was 375 KB of a 436 KB payload. The page still applies
  -- its filter (it now removes nothing), so it works either way.
  'pipeline', coalesce((select jsonb_agg(to_jsonb(x)) from
      (select pd.hubspot_deal_id, pd.name, pd.company, pd.amount, pd.campaign_start, pd.campaign_end,
              pd.close_date, pd.stage, pd.probability, pd.pipeline, pd.is_won, pd.url
       from pipeline_deals pd
       where not exists (select 1 from promotions p where p.hubspot_deal_id = pd.hubspot_deal_id)
         and not exists (select 1 from won_deal_dismissals w where w.hubspot_deal_id = pd.hubspot_deal_id)
         and not exists (select 1 from scope_deals sd where sd.hubspot_deal_id = pd.hubspot_deal_id)
         -- the promotable pipelines, matched the way the page matches them
         -- (trimmed, whitespace collapsed, lower-cased); no list means no filter
         and (not exists (select 1 from settings s, jsonb_array_elements_text(s.value) a
                          where s.key = 'hubspot_promote_pipelines' and jsonb_typeof(s.value) = 'array' and a <> '')
              or exists (select 1 from settings s, jsonb_array_elements_text(s.value) a
                         where s.key = 'hubspot_promote_pipelines' and jsonb_typeof(s.value) = 'array'
                           and lower(btrim(regexp_replace(a, '\s+', ' ', 'g')))
                             = lower(btrim(regexp_replace(coalesce(pd.pipeline, ''), '\s+', ' ', 'g')))))
         -- won deals wait at the promotion door whatever their probability;
         -- open ones need the same floor Sales Forecast forecasts with
         and (pd.is_won
              or round(coalesce(pd.probability, 0) * 100)
                 >= coalesce((select (value #>> '{}')::numeric from settings where key = 'sales_probability_threshold'), 10))
         -- campaigns finished before the platform starts are gone
         and (pd.campaign_end is null or pd.campaign_end >= '2026-01-01')) x), '[]'::jsonb),
  'promotions', coalesce((select jsonb_agg(hubspot_deal_id) from promotions), '[]'::jsonb),
  'dismissals', coalesce((select jsonb_agg(hubspot_deal_id) from won_deal_dismissals), '[]'::jsonb),
  'deals', coalesce((select jsonb_agg(to_jsonb(x)) from
      (select id, name, client_id, status, flight_start, flight_end, hidden, hubspot_deal_id from deals
       where status in ('won', 'active') and not hidden) x), '[]'::jsonb),
  'clients', coalesce((select jsonb_agg(jsonb_build_object('id', id, 'name', name, 'active', active) order by name) from clients where active), '[]'::jsonb),
  'settings', coalesce((select jsonb_object_agg(key, value) from settings
      where key in ('scope_target_profit_per_hour', 'scope_approver_emails', 'hubspot_promote_pipelines', 'sales_probability_threshold')), '{}'::jsonb),
  'scoped', coalesce((select jsonb_agg(jsonb_build_object('hubspot_deal_id', hubspot_deal_id, 'scope_id', scope_id))
      from scope_deals where hubspot_deal_id is not null), '[]'::jsonb),
  'departments', coalesce((select jsonb_agg(distinct department) from staff
      where active and tracks_capacity and department is not null), '[]'::jsonb)
);
$$;
