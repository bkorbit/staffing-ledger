-- ============================================================================
--  103 — Deal-level terms, the minimum fee as a computed output, the approvals
--  queue, and the client's existing deals in the scope's window.
--
--  Boris, 13 Sep 2026, after the first walk-through:
--
--  * A rebate belongs to the DEAL, not to a channel. scopes.rebate_pct /
--    rebate_basis (media | fee) apply to every applicable line — basis media
--    to search / social / programmatic budgets, basis fee to every line's
--    fee — unless a line carries its own (kept as data; not offered in the
--    UI any more). scope_months and promote_scope_lines both resolve it the
--    same way, so the promoted deal_lines carry the same per-line rebate the
--    scope priced (101_fixture's handoff identity still holds).
--  * The MINIMUM is not typed, it is calculated: the fee that covers the
--    month's labor — unassigned hours at department average included, the
--    same labor total the verdict uses — at a margin chosen from presets in
--    settings scope_min_margin_presets (Break even 0 %, Slight margin 15 %,
--    Target 35 %; editable). min_fee = labor ÷ (1 − margin). Per month in
--    scope_verdict, next to the fee actually planned, with the shortfall;
--    the highest month becomes the contractual minimum monthly fee in the
--    terms. Informative, not a gate on the verdict.
--  * Approvals need a place: set_scope_status stamps proposed_by /
--    proposed_at, approvals_queue() lists what waits with its verdict.
--  * "Add a deal" gives way to the client's EXISTING deals whose flights
--    overlap the scope's: scope_existing_deals(scope_id) — per deal, GP and
--    labor measured to date and planned forward inside the window, hours,
--    profit after labor — so the editor shows what the scope lands next to.
--
--  Fixture: db/103_fixture_test.sql (+ re-run 097, 101, 102).
-- ============================================================================

alter table scopes add column if not exists rebate_pct numeric(6,3);
alter table scopes add column if not exists rebate_basis text;
alter table scopes drop constraint if exists scopes_rebate_basis_check;
alter table scopes add constraint scopes_rebate_basis_check check (rebate_basis is null or rebate_basis in ('media', 'fee'));
alter table scopes add column if not exists min_margin_preset text;
alter table scopes add column if not exists proposed_by text;
alter table scopes add column if not exists proposed_at timestamptz;

insert into settings (key, value, set_by) values
  ('scope_min_margin_presets', '[{"name":"Break even","pct":0},{"name":"Slight margin","pct":15},{"name":"Target","pct":35}]'::jsonb, 'migration-103')
on conflict (key) do nothing;

-- the two scope-level sentences the terms gain
update settings set value = value
  || jsonb_build_object('rebate_media_deal', 'EMG rebates {{pct}}% of media spend to the client, invoiced by the client.',
                        'rebate_fee_deal', 'EMG rebates {{pct}}% of all fees to the client, invoiced by the client.',
                        'min_fee_deal', 'Minimum monthly fee {{amount}}.')
where key = 'scope_terms_templates'
  and not (value ? 'min_fee_deal');

comment on column scopes.rebate_pct is
  'Deal-level rebate EMG pays back to the client (103): % of rebate_basis — media (search/social/programmatic budgets) or fee (every line). A line''s own structure.rebate overrides it. COGS, never billable.';
comment on column scopes.min_margin_preset is
  'Name of the settings scope_min_margin_presets entry used for the computed minimum fee (labor ÷ (1 − margin)). Null = Slight margin.';

-- ---------------------------------------------------------------------------
--  scope_state / save_scope (096) — the new scope fields
-- ---------------------------------------------------------------------------
create or replace function scope_state(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
select jsonb_build_object(
  'id', s.id, 'family_id', s.family_id, 'name', s.name, 'scenario', s.scenario,
  'client_id', s.client_id, 'status', s.status, 'version', s.version,
  'approved_by', s.approved_by, 'approved_at', s.approved_at, 'promoted_at', s.promoted_at,
  'payment_net_days', s.payment_net_days, 'notes', s.notes, 'terms_text', s.terms_text,
  -- 103: deal-level commercial terms and the proposer stamp
  'rebate_pct', s.rebate_pct, 'rebate_basis', s.rebate_basis, 'min_margin_preset', s.min_margin_preset,
  'proposed_by', s.proposed_by, 'proposed_at', s.proposed_at,
  'set_by', s.set_by, 'set_at', s.set_at, 'created_at', s.created_at,
  'deals', coalesce((select jsonb_agg(jsonb_build_object(
      'id', sd.id, 'ord', sd.ord, 'name', sd.name, 'origin_kind', sd.origin_kind,
      'hubspot_deal_id', sd.hubspot_deal_id, 'source_deal_id', sd.source_deal_id,
      'flight_start', sd.flight_start, 'flight_end', sd.flight_end,
      'promote_mode', sd.promote_mode, 'qbo_project_id', sd.qbo_project_id,
      'promoted_deal_id', sd.promoted_deal_id,
      'lines', coalesce((select jsonb_agg(jsonb_build_object(
          'id', sl.id, 'ord', sl.ord, 'kind', sl.kind, 'label', sl.label,
          'amount', sl.amount, 'budget', sl.budget, 'fee_pct', sl.fee_pct, 'margin_pct', sl.margin_pct,
          'rate', sl.rate, 'hours_per_month', sl.hours_per_month,
          'hours_included', sl.hours_included, 'overage_rate', sl.overage_rate,
          'media_funding', sl.media_funding, 'billing_day', sl.billing_day, 'structure', sl.structure,
          'months', coalesce((select jsonb_object_agg(slm.month::text, jsonb_build_object(
              'budget', slm.budget, 'amount', slm.amount, 'hours', slm.hours, 'drivers', slm.drivers))
              from scope_line_months slm where slm.scope_line_id = sl.id), '{}'::jsonb))
          order by sl.ord, sl.set_at) from scope_lines sl where sl.scope_deal_id = sd.id), '[]'::jsonb))
      order by sd.ord) from scope_deals sd where sd.scope_id = s.id), '[]'::jsonb),
  'dept_months', coalesce((select jsonb_agg(jsonb_build_object(
      'department', d.department, 'month', d.month, 'hours', d.hours, 'source', d.source)
      order by d.department, d.month) from scope_dept_months d where d.scope_id = s.id), '[]'::jsonb),
  'staff_months', coalesce((select jsonb_agg(jsonb_build_object(
      'id', m.id, 'staff_id', m.staff_id, 'department', m.department, 'band', m.band,
      'month', m.month, 'hours', m.hours, 'source', m.source)
      order by m.department, m.staff_id nulls last, m.month) from scope_staff_months m where m.scope_id = s.id), '[]'::jsonb)
) from scopes s where s.id = p_scope_id;
$$;

create or replace function save_scope(p_payload jsonb, p_by text, p_label text default null)
returns jsonb
language plpgsql
as $$
declare
  v_id uuid; v_status text; v_deal jsonb; v_line jsonb; v_deal_id uuid; v_line_id uuid;
  v_structure jsonb; v_margin numeric; v_fee numeric; v_share numeric; v_version int;
  k text; v jsonb; v_row jsonb;
begin
  v_id := nullif(p_payload ->> 'id', '')::uuid;
  if v_id is null then
    insert into scopes (name, scenario, client_id, payment_net_days, notes, set_by,
                        rebate_pct, rebate_basis, min_margin_preset)   -- 103
    values (coalesce(nullif(p_payload ->> 'name', ''), 'New scope'),
            coalesce(nullif(p_payload ->> 'scenario', ''), 'Base'),
            nullif(p_payload ->> 'client_id', '')::uuid,
            coalesce((p_payload ->> 'payment_net_days')::int, 30),
            p_payload ->> 'notes', p_by,
            nullif(p_payload ->> 'rebate_pct', '')::numeric, nullif(p_payload ->> 'rebate_basis', ''),
            nullif(p_payload ->> 'min_margin_preset', ''))
    returning id into v_id;
  else
    perform pg_advisory_xact_lock(hashtext('save_scope'), hashtext(v_id::text));
    select status into v_status from scopes where id = v_id for update;
    if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;
    if v_status in ('approved', 'promoted') then
      return jsonb_build_object('ok', false, 'reason', 'an ' || v_status || ' scope is read-only — un-approve it first');
    end if;
    update scopes set
      name = coalesce(nullif(p_payload ->> 'name', ''), name),
      scenario = coalesce(nullif(p_payload ->> 'scenario', ''), scenario),
      client_id = case when p_payload ? 'client_id' then nullif(p_payload ->> 'client_id', '')::uuid else client_id end,
      payment_net_days = coalesce((p_payload ->> 'payment_net_days')::int, payment_net_days),
      notes = case when p_payload ? 'notes' then p_payload ->> 'notes' else notes end,
      -- 103
      rebate_pct = case when p_payload ? 'rebate_pct' then nullif(p_payload ->> 'rebate_pct', '')::numeric else rebate_pct end,
      rebate_basis = case when p_payload ? 'rebate_basis' then nullif(p_payload ->> 'rebate_basis', '') else rebate_basis end,
      min_margin_preset = case when p_payload ? 'min_margin_preset' then nullif(p_payload ->> 'min_margin_preset', '') else min_margin_preset end,
      set_by = p_by, set_at = now()
    where id = v_id;
    delete from scope_deals where scope_id = v_id;
    delete from scope_dept_months where scope_id = v_id;
    delete from scope_staff_months where scope_id = v_id;
  end if;

  for v_deal in select * from jsonb_array_elements(coalesce(p_payload -> 'deals', '[]'::jsonb)) loop
    insert into scope_deals (id, scope_id, ord, name, origin_kind, hubspot_deal_id, source_deal_id,
                             flight_start, flight_end, promote_mode, qbo_project_id, promoted_deal_id)
    values (coalesce(nullif(v_deal ->> 'id', '')::uuid, gen_random_uuid()), v_id,
            coalesce((v_deal ->> 'ord')::int, 0),
            coalesce(nullif(v_deal ->> 'name', ''), 'Deal'),
            coalesce(v_deal ->> 'origin_kind', 'new'),
            nullif(v_deal ->> 'hubspot_deal_id', ''),
            nullif(v_deal ->> 'source_deal_id', '')::uuid,
            nullif(v_deal ->> 'flight_start', '')::date,
            nullif(v_deal ->> 'flight_end', '')::date,
            coalesce(v_deal ->> 'promote_mode', case when v_deal ->> 'origin_kind' = 'hubspot' then 'hubspot'
                                                     when v_deal ->> 'origin_kind' = 'deal' then 'extend' else 'new' end),
            nullif(v_deal ->> 'qbo_project_id', ''),
            nullif(v_deal ->> 'promoted_deal_id', '')::uuid)
    returning id into v_deal_id;

    for v_line in select * from jsonb_array_elements(coalesce(v_deal -> 'lines', '[]'::jsonb)) loop
      v_structure := coalesce(v_line -> 'structure', '{}'::jsonb);
      if jsonb_typeof(v_structure) <> 'object' then v_structure := '{}'::jsonb; end if;
      v_margin := nullif(v_line ->> 'margin_pct', '')::numeric;
      v_fee := coalesce(nullif(v_line ->> 'fee_pct', '')::numeric, 0);
      -- CPM billing is margin-only: margin_pct = 100 − platform share, fee 0,
      -- so the shared view math (gp = budget × margin, billable = budget) prices it
      if v_line ->> 'kind' = 'programmatic' and v_structure #>> '{prog,model}' = 'cpm' then
        v_share := coalesce(nullif(v_structure #>> '{prog,platform_share_pct}', '')::numeric,
                            (select (value #>> '{}')::numeric from settings where key = 'scope_cpm_platform_share_pct'), 50);
        v_margin := 100 - v_share;
        v_fee := 0;
      end if;
      insert into scope_lines (id, scope_deal_id, ord, kind, label, amount, budget, fee_pct, margin_pct, rate,
                               hours_per_month, hours_included, overage_rate, media_funding, billing_day, structure, set_by)
      values (coalesce(nullif(v_line ->> 'id', '')::uuid, gen_random_uuid()), v_deal_id,
              coalesce((v_line ->> 'ord')::int, 0),
              (v_line ->> 'kind')::line_kind,
              nullif(v_line ->> 'label', ''),
              coalesce((v_line ->> 'amount')::bigint, 0),
              coalesce((v_line ->> 'budget')::bigint, 0),
              v_fee, v_margin,
              coalesce((v_line ->> 'rate')::bigint, 0),
              coalesce((v_line ->> 'hours_per_month')::numeric, 0),
              nullif(v_line ->> 'hours_included', '')::numeric,
              nullif(v_line ->> 'overage_rate', '')::bigint,
              coalesce(nullif(v_line ->> 'media_funding', ''), 'client')::media_funding,
              coalesce(nullif(v_line ->> 'billing_day', ''),
                       case when v_line ->> 'kind' in ('retainer', 'creative', 'custom') then 'first' else 'last' end)::billing_day,
              v_structure, p_by)
      returning id into v_line_id;

      if jsonb_typeof(v_line -> 'months') = 'object' then
        for k, v in select * from jsonb_each(v_line -> 'months') loop
          insert into scope_line_months (scope_line_id, month, budget, amount, hours, drivers)
          values (v_line_id, k::date,
                  nullif(v ->> 'budget', '')::bigint, nullif(v ->> 'amount', '')::bigint,
                  nullif(v ->> 'hours', '')::numeric,
                  case when jsonb_typeof(v -> 'drivers') = 'object' then v -> 'drivers' end);
        end loop;
      end if;
    end loop;
  end loop;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload -> 'dept_months', '[]'::jsonb)) loop
    insert into scope_dept_months (scope_id, department, month, hours, source)
    values (v_id, v_row ->> 'department', (v_row ->> 'month')::date,
            coalesce((v_row ->> 'hours')::numeric, 0), coalesce(v_row ->> 'source', 'manual'))
    on conflict (scope_id, department, month) do update set hours = excluded.hours, source = excluded.source;
  end loop;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload -> 'staff_months', '[]'::jsonb)) loop
    if coalesce((v_row ->> 'hours')::numeric, 0) <= 0 then continue; end if;
    insert into scope_staff_months (scope_id, staff_id, department, band, month, hours, source)
    values (v_id, nullif(v_row ->> 'staff_id', '')::uuid, v_row ->> 'department',
            nullif(v_row ->> 'band', ''), (v_row ->> 'month')::date,
            (v_row ->> 'hours')::numeric, coalesce(v_row ->> 'source', 'manual'));
  end loop;

  v_version := scope_snapshot(v_id, 'save', p_label, p_by);
  return jsonb_build_object('ok', true, 'scope_id', v_id, 'version', v_version);
exception when others then
  return jsonb_build_object('ok', false, 'reason', sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------------
--  set_scope_status (097) — the proposer stamp
-- ---------------------------------------------------------------------------
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
  update scopes set status = p_status, set_by = p_by, set_at = now(),
    -- 103: who put it in the approvals queue, and when; cleared on the way back to draft
    proposed_by = case when p_status = 'proposed' then p_by else null end,
    proposed_at = case when p_status = 'proposed' then now() else null end
  where id = p_scope_id;
  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- ---------------------------------------------------------------------------
--  scope_months (097) — the scope-level rebate
-- ---------------------------------------------------------------------------
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
  -- 103: a line's own rebate wins; otherwise the SCOPE's rebate applies to
  -- every line it fits — basis media only to media lines, basis fee to all
  round(line_rebate(c.budget,
                    case when c.kind in ('search', 'social', 'programmatic') then c.fee_raw else c.gp_n end,
                    coalesce(nullif(c.structure #>> '{rebate,pct}', '')::numeric,
                             case when sc.rebate_basis = 'media' and c.kind not in ('search', 'social', 'programmatic') then 0
                                  else sc.rebate_pct end),
                    coalesce(c.structure #>> '{rebate,basis}', sc.rebate_basis)))::bigint as rebate
from calc c
cross join (select rebate_pct, rebate_basis from scopes where id = p_scope_id) sc;
$$ language sql stable;

-- ---------------------------------------------------------------------------
--  scope_verdict (100) — the minimum fee per month
-- ---------------------------------------------------------------------------
create or replace function scope_verdict(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
with sc as (select * from scopes where id = p_scope_id),
knobs as (
  select coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_profit_per_hour'), 150) * 100 as target_c,
         coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_target_utilization_pct'), 80) as util,
         -- 103: the minimum-fee margin — the scope's preset, else the first preset
         coalesce((select (p ->> 'pct')::numeric from settings s, jsonb_array_elements(s.value) p
                   where s.key = 'scope_min_margin_presets' and p ->> 'name' = (select min_margin_preset from sc)),
                  (select (p ->> 'pct')::numeric from settings s, jsonb_array_elements(s.value) p
                   where s.key = 'scope_min_margin_presets' and p ->> 'name' = 'Slight margin'),
                  0) as min_margin_pct
),
econ as (
  select month, sum(gp) as gp, sum(rebate) as rebate, sum(billable) as billable, sum(pass_through) as pass_through,
         sum(fee) as fee   -- 103: what the client is charged, the number a minimum compares to
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
         coalesce(e.gp, 0) - coalesce(e.rebate, 0) - coalesce(l.cost, 0) as pal,
         -- 103: the fee that covers this month's labor (unassigned hours included) at the preset margin
         coalesce(e.fee, 0)::bigint as fee,
         case when (select min_margin_pct from knobs) >= 100 then null
              else round(coalesce(l.cost, 0) / (1 - (select min_margin_pct from knobs) / 100))::bigint end as min_fee
  from months m left join econ e on e.month = m.month left join lab l on l.month = m.month
),
tot as (
  select sum(gp) as gp, sum(rebate) as rebate, sum(billable) as billable, sum(hours) as hours, sum(labor) as labor,
         sum(labor_lo) as labor_lo, sum(labor_hi) as labor_hi, sum(pal) as pal, sum(open_hours) as open_hours, sum(unpriced_hours) as unpriced_hours,
         sum(fee) as fee, sum(min_fee) as min_fee, max(min_fee) as min_fee_max,            -- 103
         sum(greatest(min_fee - fee, 0)) as fee_shortfall
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
    (select hours from tot) > 0 as has_hours,
    (select bool_and(fee >= coalesce(min_fee, 0)) from per) as min_fee_ok   -- 103: informative, not a gate
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
      'fee', fee, 'min_fee', min_fee,   -- 103
      'open_hours', open_hours, 'unpriced_hours', unpriced_hours) order by month) from per), '[]'::jsonb),
  'total', (select jsonb_build_object(
      'gp', gp, 'rebate', rebate, 'billable', billable, 'hours', hours, 'labor', labor,
      'labor_lo', labor_lo, 'labor_hi', labor_hi, 'pal', pal,
      'per_hour_c', case when hours > 0 then round(pal / hours) end,
      'fee', fee, 'min_fee', min_fee, 'min_fee_max', min_fee_max, 'fee_shortfall', fee_shortfall,   -- 103
      'open_hours', open_hours, 'unpriced_hours', unpriced_hours) from tot),
  'targets', (select jsonb_build_object('per_hour_c', target_c, 'utilization_pct', util, 'min_margin_pct', min_margin_pct,
                                        'min_margin_preset', (select min_margin_preset from sc)) from knobs),
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
  'Is the scope viable: per month gp, rebate, labor (one number), pal = gp − rebate − labor, profit per hour vs target; checks; status; capacity rows; client roll-up. 103: fee (what the client is charged) and min_fee = labor ÷ (1 − preset margin) per month, totals with min_fee_max and fee_shortfall, checks.min_fee_ok (informative).';

-- ---------------------------------------------------------------------------
--  scope_existing_deals: the client''s live deals overlapping the scope''s window
-- ---------------------------------------------------------------------------
create or replace function scope_existing_deals(p_scope_id uuid)
returns jsonb
language sql
stable
as $$
with sc as (select * from scopes where id = p_scope_id),
win as (
  select date_trunc('month', min(flight_start))::date as m0, date_trunc('month', max(flight_end))::date as m1
  from scope_deals where scope_id = p_scope_id and flight_start is not null and flight_end is not null
),
cur as (select date_trunc('month', current_date)::date as m),
d as (
  select d.* from deals d, sc, win
  where d.client_id = sc.client_id and d.status in ('won', 'active') and not d.hidden
    and win.m0 is not null
    and date_trunc('month', d.flight_start)::date <= win.m1 and date_trunc('month', d.flight_end)::date >= win.m0
    and d.id not in (select source_deal_id from scope_deals where scope_id = p_scope_id and source_deal_id is not null)
),
pd as (
  select d.id as deal_id, (x ->> 'month')::date as month,
         (x ->> 'gp_actual')::bigint as gp_actual, (x ->> 'labor_actual')::bigint as labor_actual
  from d, jsonb_array_elements(project_detail(d.id) -> 'months') x
),
plan as (
  select v.deal_id, v.month, sum(v.gp - v.rebate) as gp from v_deal_month_forecast v where v.deal_id in (select id from d) group by v.deal_id, v.month
),
asg_keys as (select distinct a.staff_id, a.month from assignments a where a.deal_id in (select id from d)),
rates as materialized (select staff_id, month, staff_hourly_cost(staff_id, month) as rate from asg_keys),
asg as (
  select a.deal_id, a.month, sum(a.hours) as hours, sum(round(a.hours * r.rate)) as labor
  from assignments a join rates r on r.staff_id = a.staff_id and r.month = a.month
  where a.deal_id in (select id from d) group by a.deal_id, a.month
),
te as (
  select t.deal_id, date_trunc('month', t.worked_on)::date as month, sum(t.hours) as hours
  from time_entries t where t.deal_id in (select id from d) and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
  group by t.deal_id, date_trunc('month', t.worked_on)
),
rows_ as (
  select d.id, d.name, d.flight_start, d.flight_end, d.qbo_project_id,
    coalesce((select sum(gp_actual) from pd, win, cur where pd.deal_id = d.id and pd.month between win.m0 and win.m1 and pd.month < cur.m), 0)::bigint as gp_measured,
    coalesce((select sum(gp) from plan, win, cur where plan.deal_id = d.id and plan.month between win.m0 and win.m1 and plan.month >= cur.m), 0)::bigint as gp_plan,
    coalesce((select sum(labor_actual) from pd, win, cur where pd.deal_id = d.id and pd.month between win.m0 and win.m1 and pd.month < cur.m), 0)::bigint as labor_measured,
    coalesce((select sum(labor) from asg, win, cur where asg.deal_id = d.id and asg.month between win.m0 and win.m1 and asg.month >= cur.m), 0)::bigint as labor_plan,
    coalesce((select sum(hours) from te, win, cur where te.deal_id = d.id and te.month between win.m0 and win.m1 and te.month < cur.m), 0)::numeric as hours_measured,
    coalesce((select sum(hours) from asg, win, cur where asg.deal_id = d.id and asg.month between win.m0 and win.m1 and asg.month >= cur.m), 0)::numeric as hours_plan
  from d
)
select coalesce((select jsonb_agg(jsonb_build_object(
  'id', id, 'name', name, 'flight_start', flight_start, 'flight_end', flight_end, 'qbo_project_id', qbo_project_id,
  'gp_measured', gp_measured, 'gp_plan', gp_plan, 'labor_measured', labor_measured, 'labor_plan', labor_plan,
  'hours_measured', hours_measured, 'hours_plan', hours_plan,
  'pal', gp_measured + gp_plan - labor_measured - labor_plan) order by flight_start, name) from rows_), '[]'::jsonb);
$$;

comment on function scope_existing_deals(uuid) is
  'The client''s live deals whose flights overlap the scope''s months (the source deal of an extend re-scope excluded): per deal GP and labor measured to date (project_detail) and planned forward (v_deal_month_forecast gp − rebate; assignments × staff_hourly_cost) inside the window, hours, profit after labor. Labor is a total per deal — never per person.';

-- ---------------------------------------------------------------------------
--  approvals_queue: what waits for an approver
-- ---------------------------------------------------------------------------
create or replace function approvals_queue()
returns jsonb
language sql
stable
as $$
select coalesce((select jsonb_agg(jsonb_build_object(
  'id', s.id, 'name', s.name, 'scenario', s.scenario, 'client_id', s.client_id, 'client_name', c.name,
  'proposed_by', s.proposed_by, 'proposed_at', s.proposed_at, 'version', s.version,
  'deals', (select coalesce(jsonb_agg(jsonb_build_object('name', sd.name, 'flight_start', sd.flight_start, 'flight_end', sd.flight_end, 'promote_mode', sd.promote_mode) order by sd.ord), '[]'::jsonb) from scope_deals sd where sd.scope_id = s.id),
  'kpis', (scope_verdict(s.id) -> 'total') || jsonb_build_object('status', scope_verdict(s.id) ->> 'status'))
  order by s.proposed_at nulls last, s.set_at)
  from scopes s left join clients c on c.id = s.client_id
  where s.status = 'proposed'), '[]'::jsonb);
$$;

comment on function approvals_queue() is
  'Every proposed scope with who proposed it, when, its deals and its verdict KPIs — the Approvals tab.';

-- ---------------------------------------------------------------------------
--  scope_page (097) — + existing_deals, min-margin presets
-- ---------------------------------------------------------------------------
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
  'existing_deals', scope_existing_deals(p_scope_id),   -- 103
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
      'hire_costs', coalesce((select value from settings where key = 'scope_hire_costs'), '{}'::jsonb),
      'min_margin_presets', coalesce((select value from settings where key = 'scope_min_margin_presets'), '[]'::jsonb)),   -- 103
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

-- ---------------------------------------------------------------------------
--  scope_terms (102) — scope-level rebate sentence, minimum monthly fee
-- ---------------------------------------------------------------------------
create or replace function scope_terms(p_scope_id uuid)
returns jsonb
language plpgsql
stable
as $$
declare
  sc scopes%rowtype; sd record; sl record; t jsonb; v_client text;
  v_sections jsonb := '[]'::jsonb; v_text text := ''; v_line text; v_bands text; v_lo bigint; b jsonb; i int; n int;
  v_total bigint; v_hours_clause text; v_deals text; v_start date; v_end date; v_mode text; v_sent text;
  tpl text;
begin
  select * into sc from scopes where id = p_scope_id;
  if not found then return jsonb_build_object('sections', '[]'::jsonb, 'text', ''); end if;
  select coalesce((select value from settings where key = 'scope_terms_templates'), '{}'::jsonb) into t;
  select name into v_client from clients where id = sc.client_id;

  select string_agg(render_template(t ->> 'deal', jsonb_build_object('deal', d.name, 'start', to_char(d.flight_start, 'DD Mon YYYY'), 'end', to_char(d.flight_end, 'DD Mon YYYY'))), '; ' order by d.ord),
         min(d.flight_start), max(d.flight_end)
    into v_deals, v_start, v_end
  from scope_deals d where d.scope_id = p_scope_id;

  v_sent := render_template(t ->> 'intro', jsonb_build_object('client', coalesce(v_client, 'the client'), 'deals', coalesce(v_deals, ''),
              'start', coalesce(to_char(v_start, 'DD Mon YYYY'), '?'), 'end', coalesce(to_char(v_end, 'DD Mon YYYY'), '?')));
  v_sections := v_sections || jsonb_build_object('key', 'intro', 'deal_id', null, 'title', 'Scope', 'text', v_sent);
  v_text := v_sent;

  for sd in select * from scope_deals where scope_id = p_scope_id order by ord, id loop
    for sl in select * from scope_lines where scope_deal_id = sd.id order by ord, set_at loop
      v_line := case sl.kind
        when 'search' then 'Paid search' when 'social' then 'Paid social' when 'programmatic' then 'Programmatic'
        when 'retainer' then coalesce(nullif(sl.label, ''), 'Retainer')
        when 'hourly' then coalesce(nullif(sl.label, ''), 'Hourly services')
        when 'creative' then 'Creative' else initcap(sl.kind::text) end;
      select coalesce(sum(coalesce(slm.budget, 0)), 0) into v_total from scope_line_months slm where slm.scope_line_id = sl.id;
      if v_total = 0 and sl.budget > 0 and sd.flight_start is not null and sd.flight_end is not null then
        v_total := sl.budget * (select count(*) from generate_series(date_trunc('month', sd.flight_start), date_trunc('month', sd.flight_end), interval '1 month'));
      end if;
      v_sent := '';

      if sl.kind in ('search', 'social') then
        v_mode := coalesce(sl.structure #>> '{fee,mode}', 'flat');
        if v_mode = 'flat' then
          v_sent := render_template(t ->> 'fee_flat', jsonb_build_object('line', v_line, 'pct', fmt_pct(sl.fee_pct)));
        else
          v_bands := ''; v_lo := 0;
          n := jsonb_array_length(sl.structure #> '{fee,bands}');
          for i in 0 .. n - 1 loop
            b := sl.structure #> '{fee,bands}' -> i;
            tpl := case when i = n - 1 or (b ->> 'upto') is null
                        then t ->> (case v_mode when 'marginal' then 'fee_marginal_band_last' else 'fee_whole_band_last' end)
                        else t ->> (case v_mode when 'marginal' then 'fee_marginal_band' else 'fee_whole_band' end) end;
            v_bands := v_bands || case when i > 0 then '; ' else '' end
              || render_template(tpl, jsonb_build_object('pct', fmt_pct((b ->> 'pct')::numeric), 'from', fmt_money(v_lo),
                   'to', fmt_money(nullif(b ->> 'upto', '')::bigint)));
            v_lo := coalesce(nullif(b ->> 'upto', '')::bigint, v_lo);
          end loop;
          v_sent := render_template(t ->> (case v_mode when 'marginal' then 'fee_marginal' else 'fee_whole' end),
                      jsonb_build_object('line', v_line, 'bands', v_bands));
        end if;
        if nullif(sl.structure ->> 'fee_min', '') is not null then
          v_sent := v_sent || ' ' || render_template(t ->> 'fee_min', jsonb_build_object('amount', fmt_money((sl.structure ->> 'fee_min')::bigint)));
        end if;
        if nullif(sl.structure ->> 'fee_cap', '') is not null then
          v_sent := v_sent || ' ' || render_template(t ->> 'fee_cap', jsonb_build_object('amount', fmt_money((sl.structure ->> 'fee_cap')::bigint)));
        end if;
        v_sent := v_sent || ' ' || render_template(t ->> (case when sl.media_funding = 'agency' then 'media_agency' else 'media_client' end), '{}'::jsonb);
        if v_total > 0 then v_sent := v_sent || ' ' || render_template(t ->> 'media_budget', jsonb_build_object('total', fmt_money(v_total))); end if;

      elsif sl.kind = 'programmatic' then
        if sl.structure #>> '{prog,model}' = 'cpm' then
          v_sent := render_template(t ->> 'programmatic_cpm', jsonb_build_object('line', v_line, 'total', fmt_money(v_total)));
        else
          v_sent := render_template(t ->> 'programmatic_fee_margin', jsonb_build_object('line', v_line, 'pct', fmt_pct(sl.fee_pct), 'total', fmt_money(v_total)));
        end if;

      elsif sl.kind = 'hourly' or (sl.kind = 'creative' and sl.label like 'creative:hourly%') then
        v_sent := render_template(t ->> 'hourly', jsonb_build_object('line', v_line, 'hours', fmt_hours(sl.hours_per_month), 'rate', fmt_money(sl.rate)));

      else
        v_hours_clause := '';
        if sl.hours_included is not null and sl.hours_included > 0 then
          v_hours_clause := render_template(t ->> 'hours_included', jsonb_build_object('hours', fmt_hours(sl.hours_included)));
          if sl.overage_rate is not null and sl.overage_rate > 0 then
            v_hours_clause := v_hours_clause || render_template(t ->> 'overage', jsonb_build_object('rate', fmt_money(sl.overage_rate)));
          end if;
        end if;
        v_sent := render_template(t ->> 'retainer', jsonb_build_object('line', v_line, 'amount', fmt_money(sl.amount), 'hours_clause', v_hours_clause));
      end if;

      if nullif(sl.structure #>> '{rebate,pct}', '') is not null and (sl.structure #>> '{rebate,pct}')::numeric > 0 then
        v_sent := v_sent || ' ' || render_template(t ->> (case when sl.structure #>> '{rebate,basis}' = 'fee' then 'rebate_fee' else 'rebate_media' end),
                    jsonb_build_object('line', lower(v_line), 'pct', fmt_pct((sl.structure #>> '{rebate,pct}')::numeric)));
      end if;

      v_sections := v_sections || jsonb_build_object('key', 'line', 'deal_id', sd.id, 'line_id', sl.id, 'title', sd.name || ' — ' || v_line, 'text', v_sent);
      v_text := v_text || E'\n\n' || v_sent;
    end loop;
  end loop;

  -- 103: the scope-level rebate, said once; the minimum monthly fee = the
  -- highest month's labor-covering minimum at the chosen margin
  if sc.rebate_pct is not null and sc.rebate_pct > 0 then
    v_sent := render_template(t ->> (case when sc.rebate_basis = 'fee' then 'rebate_fee_deal' else 'rebate_media_deal' end),
                jsonb_build_object('pct', fmt_pct(sc.rebate_pct)));
    v_sections := v_sections || jsonb_build_object('key', 'rebate', 'deal_id', null, 'title', 'Rebate', 'text', v_sent);
    v_text := v_text || E'\n\n' || v_sent;
  end if;
  v_total := (scope_verdict(p_scope_id) -> 'total' ->> 'min_fee_max')::bigint;
  if v_total is not null and v_total > 0 then
    v_sent := render_template(t ->> 'min_fee_deal', jsonb_build_object('amount', fmt_money(v_total)));
    v_sections := v_sections || jsonb_build_object('key', 'minimum', 'deal_id', null, 'title', 'Minimum fee', 'text', v_sent);
    v_text := v_text || E'\n\n' || v_sent;
  end if;
  v_sent := render_template(t ->> 'payment_terms', jsonb_build_object('net_days', coalesce(sc.payment_net_days, 30)::text));
  v_sections := v_sections || jsonb_build_object('key', 'payment', 'deal_id', null, 'title', 'Payment', 'text', v_sent);
  v_text := v_text || E'\n\n' || v_sent;
  if sc.notes is not null and btrim(sc.notes) <> '' then
    v_sections := v_sections || jsonb_build_object('key', 'notes', 'deal_id', null, 'title', 'Notes', 'text', sc.notes);
    v_text := v_text || E'\n\n' || sc.notes;
  end if;
  return jsonb_build_object('sections', v_sections, 'text', v_text);
end;
$$;

-- ---------------------------------------------------------------------------
--  promote_scope_lines (101) — the scope-level rebate lands on the lines
-- ---------------------------------------------------------------------------
create or replace function promote_scope_lines(p_deal_id uuid, p_scope_deal_id uuid, p_by text, p_from_month date default null)
returns int
language plpgsql
as $$
declare r record; v_line uuid; v_n int := 0; v_scope uuid; v_rpct numeric; v_rbasis text;
begin
  select sd.scope_id, s.rebate_pct, s.rebate_basis into v_scope, v_rpct, v_rbasis
  from scope_deals sd join scopes s on s.id = sd.scope_id where sd.id = p_scope_deal_id;   -- 103
  for r in select sl.* from scope_lines sl where sl.scope_deal_id = p_scope_deal_id order by sl.ord, sl.set_at loop
    insert into deal_lines (deal_id, kind, label, amount, budget, fee_pct, margin_pct, rate, hours_per_month,
                            billing_day, media_funding, structure, rebate_pct, rebate_basis, scope_id, set_by)
    values (p_deal_id, r.kind, r.label, r.amount, r.budget, r.fee_pct, r.margin_pct, r.rate, r.hours_per_month,
            r.billing_day, r.media_funding, coalesce(r.structure, '{}'::jsonb),
            -- 103: the line's own rebate, else the scope's where it applies
            coalesce(nullif(r.structure #>> '{rebate,pct}', '')::numeric,
                     case when v_rbasis = 'media' and r.kind not in ('search', 'social', 'programmatic') then null else v_rpct end),
            case when nullif(r.structure #>> '{rebate,pct}', '') is not null then coalesce(r.structure #>> '{rebate,basis}', 'media')
                 when v_rpct is not null and not (v_rbasis = 'media' and r.kind not in ('search', 'social', 'programmatic')) then coalesce(v_rbasis, 'media') end,
            v_scope, 'promotion:scope')
    returning id into v_line;
    insert into deal_line_months (deal_line_id, month, budget, amount, hours, set_by)
    select v_line, slm.month, slm.budget, slm.amount, slm.hours, 'promotion:scope'
    from scope_line_months slm
    where slm.scope_line_id = r.id
      and (slm.budget is not null or slm.amount is not null or slm.hours is not null)
      and (p_from_month is null or slm.month >= p_from_month);
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;
