-- ============================================================================
--  104 — The programmatic backend margin is a deal output, and the hours grid
--  knows which teams a line brings.
--
--  Boris, second walk-through: the backend margin is not typed per line — it
--  is the instruction to the programmatic team for the WHOLE deal: the one
--  margin that, across all the scope's programmatic (fee + margin) lines with
--  their own fees and budgets, lands the target GP on revenue
--  (scope_prog_target_gp_pct, 096). scope_prog_margin(scope_id) solves it:
--
--     Σ b_i (m + f_i)/100  =  t/100 · Σ b_i (1 + f_i/100)
--     m = ( t · Σ b_i (1 + f_i/100) − Σ b_i f_i ) / Σ b_i        (3 dp, floored at 0)
--
--  which for one line is exactly prog_suggest_margin(f, t). CPM lines carry
--  their own margin_pct (100 − platform share) and lines with an explicit
--  margin_pct (legacy rows) are priced by it — neither is in the sum. The
--  editor no longer offers a per-line margin. promote_scope_lines writes the computed margin onto the
--  promoted deal_lines (which have no deal-level fallback) so the Forecast
--  prices the deal exactly as the scope did.
--
--  Two settings the editor reads to fill the hours grid as lines are added:
--    scope_kind_departments   {kind: [department, …]} — a search line brings
--                             Paid Media and AdOps, programmatic brings
--                             Programmatic and AdOps, creative brings Creative
--    scope_always_departments [department, …] — on every scope, whatever the
--                             lines (account management / planning)
--
--  Fixture: db/104_fixture_test.sql (+ re-run 097, 101, 103). JS twin:
--  progDealMargin in app/assets/scope-math.js.
-- ============================================================================

insert into settings (key, value, set_by) values
  ('scope_kind_departments',
   '{"search":["Paid Media","AdOps"],"social":["Paid Media","AdOps"],"programmatic":["Programmatic","AdOps"],"creative":["Creative"],"retainer":["Planning & Strategy"],"hourly":[]}'::jsonb,
   'migration-104'),
  ('scope_always_departments', '["Planning & Strategy"]'::jsonb, 'migration-104')
on conflict (key) do nothing;

create or replace function scope_prog_margin(p_scope_id uuid)
returns numeric
language sql
stable
as $$
with t as (
  select coalesce((select (value #>> '{}')::numeric from settings where key = 'scope_prog_target_gp_pct'), 40) as target
),
lines as (
  -- every programmatic fee+margin line month: budget and fee %, CPM lines excluded
  select coalesce(slm.budget, sl.budget) as b, sl.fee_pct as f
  from scope_deals sd
  join scope_lines sl on sl.scope_deal_id = sd.id
  cross join lateral generate_series(date_trunc('month', sd.flight_start), date_trunc('month', sd.flight_end), interval '1 month') gs(month)
  left join scope_line_months slm on slm.scope_line_id = sl.id and slm.month = gs.month::date
  where sd.scope_id = p_scope_id and sd.flight_start is not null and sd.flight_end is not null
    and sl.kind = 'programmatic' and coalesce(sl.structure #>> '{prog,model}', 'fee_margin') <> 'cpm'
    and sl.margin_pct is null   -- a line with its own margin is priced by it, not by the deal margin
)
select case when coalesce(sum(b), 0) = 0 then null
            else round(greatest((t.target * sum(b * (1 + f / 100)) - sum(b * f)) / sum(b), 0), 3) end
from lines, t
group by t.target;
$$;

comment on function scope_prog_margin(uuid) is
  'The deal''s backend margin (an OUTPUT): the one margin across the scope''s programmatic fee+margin lines, budget-weighted over the flight, that makes GP / revenue = scope_prog_target_gp_pct. Null when the scope has no such line. For one line equals prog_suggest_margin(fee, target). JS twin: progDealMargin.';

-- ---------------------------------------------------------------------------
--  scope_months (103) — the computed margin as the fallback
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
         -- 104: the backend margin is a DEAL output — one margin across the scope's
         -- programmatic lines that lands the target GP on revenue; a line's own
         -- margin_pct (CPM lines, legacy rows) still wins
         coalesce(sl.margin_pct, scope_prog_margin(p_scope_id),
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
--  promote_scope_lines (103) — the computed margin lands on the deal_lines
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
    values (p_deal_id, r.kind, r.label, r.amount, r.budget, r.fee_pct,
            -- 104: deal_lines has no deal-level fallback, so the computed backend margin lands on the line
            case when r.kind = 'programmatic' then coalesce(r.margin_pct, scope_prog_margin(v_scope)) else r.margin_pct end,
            r.rate, r.hours_per_month,
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

-- ---------------------------------------------------------------------------
--  scope_page (103) — + prog_margin, the department settings
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
  'prog_margin', scope_prog_margin(p_scope_id),          -- 104: the deal's backend margin (output)
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
$$;
