-- ============================================================================
--  078 — promotion happens when a human clicks Approve, not on the next sync.
--
--  060 split the decision from the write: Sales Forecast records a human's
--  choice in promotion_approvals, sync-hubspot.mjs does the mechanical write
--  overnight. The decision half was right; the overnight half was not. A deal
--  approved at 10am did not exist in the Forecast until the next morning, so
--  the person who just approved it could not shape its lines, check its
--  flight, or see it in a client's rollup — the one moment they had the deal
--  in their head. Worse, the write was three separate PostgREST round trips
--  (deals, promotions, deal_lines/deal_line_months) with no transaction
--  around them: a failure between them left a deal with no promotion record,
--  or a promoted deal with half its lines.
--
--  So the whole mechanical write moves here, into one function, in one
--  transaction. Everything it needs was already in the database —
--  pipeline_deals holds the mirror, promotion_approvals holds the decision —
--  so it needs no HubSpot call and no service-role key, and the browser can
--  invoke it directly the moment Approve is clicked.
--
--  Two callers, ONE once-only check:
--    1. the Approve button (app/sales.html), the normal path;
--    2. sync-hubspot.mjs, which now calls this same function for every
--       approval still queued — the safety net for an approval whose RPC
--       never landed (tab closed, network dropped, browser asleep).
--  Both enter through promote_approval(); the "has this HubSpot deal already
--  been through the door?" test exists exactly once, inside it, under an
--  advisory lock that covers check-and-insert together. A deal cannot promote
--  twice even if a human clicks Approve at the exact moment the nightly sync
--  reaches the same row. promotions.hubspot_deal_id (a primary key) and
--  deals.hubspot_deal_id (unique) remain the schema-level backstop.
--
--  Deliberate behaviour change: the write-time re-validation checks the
--  campaign dates only. The old JS promotionBlocker() also refused a deal
--  with no HubSpot company — but the gate's whole point is that a HUMAN picks
--  the client, and the gate UI has always offered "(no company)" deals for
--  approval. A deal a person approved would then sit in the queue forever,
--  held back by a rule the UI does not apply. The dates stay checked because
--  they are the deal's own data and the schema demands them (a won deal must
--  have a flight); HubSpot can change them between approval and write.
--
--  The line-item flighting (LI_MAP + flightFromItems in sync-hubspot.mjs) is
--  ported to SQL below and DELETED from the JS. Two implementations of the
--  same money math is exactly the drift this codebase has been bitten by;
--  there is now one, and db/078_fixture_test.sql runs the JS unit test's
--  cases against it.
-- ============================================================================

-- ---------------------------------------------------------------------------
--  The HubSpot line-item type map. Same table the Sales page reads by eye:
--  a product name maps to (ledger kind, role in that kind). Names arrive
--  prefixed by folder ("Media: Paid Search Media"), so only the segment after
--  the last colon is matched, trimmed and lowercased. Returns null for an
--  unmapped name — that is a decision point, not a default.
-- ---------------------------------------------------------------------------
create or replace function hs_line_item_map(p_name text)
returns text[]
language sql
immutable
as $$
  select m.v from (values
    ('programmatic media',      array['programmatic','budget']),
    ('programmatic buying fee', array['programmatic','fee']),
    ('paid search media',       array['search','budget']),
    ('paid search fee',         array['search','fee']),
    ('paid social media',       array['social','budget']),
    ('paid social fee',         array['social','fee']),
    ('paid search hourly',      array['retainer','flat']),
    ('paid social hourly',      array['retainer','flat']),
    ('creative retainer',       array['retainer','flat']),
    ('creative services',       array['retainer','flat']),
    ('planning',                array['retainer','flat']),
    ('dashboard',               array['retainer','flat'])
  ) as m(k, v)
  where m.k = lower(btrim(regexp_replace(coalesce(p_name, ''), '^.*:', '')));
$$;

comment on function hs_line_item_map(text) is
  'HubSpot line-item product name -> ARRAY[ledger kind, role] (budget|fee|flat), '
  'or null when the name maps to nothing. Matches the segment after the last '
  'colon, case- and whitespace-insensitive. Ported verbatim from LI_MAP in '
  'scripts/sync-hubspot.mjs, which no longer carries a copy.';

-- ---------------------------------------------------------------------------
--  Line items -> forecast lines, for the flight p_start..p_end.
--
--  Returns {lines:[{kind, amount, fee_pct, months:{iso:cents}|null}], reason}.
--  Lines come back ONLY when every item maps: one unmapped product and the
--  answer is no lines plus the reason. A skeleton a human fills in beats a
--  half-invented plan that looks finished.
--
--  Money rules, unchanged from the JS this replaces:
--    - a media budget spreads evenly across the covered months, with the
--      rounding remainder landing on the LAST month so the spread sums to the
--      as-sold total to the cent;
--    - a media fee alongside a budget becomes fee_pct (2dp), not its own line;
--    - a fee with no media has no percentage to be a percentage OF, so it
--      becomes a flat monthly retainer — the honest shape;
--    - retainer-ish items (creative, planning, dashboard, hourly) collapse
--      into one flat monthly amount.
--  Line order follows first appearance in the item list, so two runs over the
--  same deal produce the same rows in the same order.
-- ---------------------------------------------------------------------------
-- STABLE, not IMMUTABLE: the month keys are formatted with to_char(), which
-- Postgres marks stable (DateStyle/lc_time are session settings). Nothing
-- indexes this function, so stable costs nothing and is the honest label.
create or replace function hs_flight_lines(p_items jsonb, p_start date, p_end date)
returns jsonb
language plpgsql
stable
as $$
declare
  v_months  date[];
  v_n       int;
  v_unmapped text;
  v_lines   jsonb := '[]'::jsonb;
  v_months_obj jsonb;
  v_per     bigint;
  v_flat    bigint;
  r         record;
  i         int;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    return jsonb_build_object('lines', '[]'::jsonb, 'reason', 'no line items');
  end if;

  -- the covered months, first-of-month, capped at 48 the way the JS was
  -- (a runaway flight should not write four years of override rows)
  select array_agg(m order by m) into v_months
  from (
    select g::date as m
    from generate_series(date_trunc('month', p_start), date_trunc('month', p_end), interval '1 month') g
    limit 48
  ) s;
  v_n := coalesce(array_length(v_months, 1), 0);
  if v_n = 0 then
    return jsonb_build_object('lines', '[]'::jsonb, 'reason', 'no flight months');
  end if;

  -- one unmapped item and nothing is flighted; name the first one, in item order
  select li->>'name' into v_unmapped
  from jsonb_array_elements(p_items) with ordinality as t(li, ord)
  where hs_line_item_map(li->>'name') is null
  order by ord
  limit 1;
  if found then
    return jsonb_build_object('lines', '[]'::jsonb,
      'reason', 'unmapped line item: ' || coalesce(nullif(v_unmapped, ''), '?'));
  end if;

  for r in
    select (hs_line_item_map(x.name))[1] as kind,
           sum(case when (hs_line_item_map(x.name))[2] = 'budget' then x.cents else 0 end) as budget,
           sum(case when (hs_line_item_map(x.name))[2] = 'fee'    then x.cents else 0 end) as fee,
           sum(case when (hs_line_item_map(x.name))[2] = 'flat'   then x.cents else 0 end) as flat
    from (
      select li->>'name' as name,
             -- a non-numeric amount is worth zero, not an aborted promotion
             case when coalesce(li->>'amount', '') ~ '^\s*-?\d+(\.\d+)?\s*$'
                  then round(btrim(li->>'amount')::numeric * 100)::bigint
                  else 0 end as cents,
             ord
      from jsonb_array_elements(p_items) with ordinality as t(li, ord)
    ) x
    group by 1
    order by min(x.ord)
  loop
    if r.kind = 'retainer' then
      -- everything retainer-ish is one flat monthly figure, whatever role it arrived in
      v_flat := r.flat + r.fee + r.budget;
      if v_flat > 0 then
        v_lines := v_lines || jsonb_build_array(jsonb_build_object(
          'kind', 'retainer', 'amount', round(v_flat::numeric / v_n),
          'fee_pct', 0, 'months', null));
      end if;
    elsif r.budget > 0 then
      v_per := floor(r.budget::numeric / v_n)::bigint;
      v_months_obj := '{}'::jsonb;
      for i in 1 .. v_n loop
        v_months_obj := v_months_obj || jsonb_build_object(
          to_char(v_months[i], 'YYYY-MM-DD'),
          case when i = v_n then r.budget - v_per * (v_n - 1) else v_per end);
      end loop;
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'kind', r.kind, 'amount', 0,
        'fee_pct', case when r.fee > 0 then round(r.fee::numeric / r.budget * 100, 2) else 0 end,
        'months', v_months_obj));
    elsif r.fee > 0 then
      -- a fee with no media: a flat monthly amount is the honest shape
      v_lines := v_lines || jsonb_build_array(jsonb_build_object(
        'kind', 'retainer', 'amount', round(r.fee::numeric / v_n),
        'fee_pct', 0, 'months', null));
    end if;
  end loop;

  if jsonb_array_length(v_lines) = 0 then
    return jsonb_build_object('lines', '[]'::jsonb, 'reason', 'items sum to nothing');
  end if;
  return jsonb_build_object('lines', v_lines, 'reason', null);
end;
$$;

comment on function hs_flight_lines(jsonb, date, date) is
  'HubSpot line items -> {lines, reason} for the promotion door''s automatic '
  'flighting. Lines only when every item maps; budgets spread evenly with the '
  'remainder on the last month so the as-sold total is preserved to the cent. '
  'The single implementation — the JS twin in sync-hubspot.mjs was deleted in '
  '078 rather than left to drift. Cases: db/078_fixture_test.sql.';

-- ---------------------------------------------------------------------------
--  The promotion door itself. Called by the Approve button and, as a retry
--  for anything still queued, by sync-hubspot.mjs.
--
--  Returns jsonb, never raises for an expected outcome — the caller needs to
--  tell "promoted", "already promoted", and "held back, try again later"
--  apart, and only the last one should leave the approval queued:
--    {ok:true,  already:false, deal_id, deal_name, flighted, lines, reason}
--    {ok:true,  already:true,  deal_id, reason}          approval consumed
--    {ok:false, held_back:true, reason}                  approval left queued
--    {ok:false, reason}                                  nothing to do
-- ---------------------------------------------------------------------------
create or replace function promote_approval(p_hubspot_deal_id text)
returns jsonb
language plpgsql
as $$
declare
  a          promotion_approvals%rowtype;
  m          pipeline_deals%rowtype;
  v_deal_id  uuid;
  v_existing uuid;
  v_blocker  text;
  v_fl       jsonb;
  ln         jsonb;
  v_line_id  uuid;
  v_flighted boolean := false;
begin
  if p_hubspot_deal_id is null or btrim(p_hubspot_deal_id) = '' then
    return jsonb_build_object('ok', false, 'reason', 'no hubspot_deal_id given');
  end if;

  -- One promoter at a time per deal. The browser's Approve and the nightly
  -- sync's retry can reach the same id in the same instant; everything below
  -- — the once-only check AND the insert it guards — happens inside this
  -- lock, so the check cannot go stale between reading and writing. Released
  -- automatically at the end of the transaction, however it ends.
  perform pg_advisory_xact_lock(hashtext('promote_approval'), hashtext(p_hubspot_deal_id));

  -- THE once-only check, in one place, for both callers. promotions is
  -- permanent by design (001) and survives deletion of the deal it created,
  -- so it is the real one-way door; deals.hubspot_deal_id is checked too so a
  -- hand-made deal row cannot be duplicated either.
  select deal_id into v_existing from promotions where hubspot_deal_id = p_hubspot_deal_id;
  if found then
    delete from promotion_approvals where hubspot_deal_id = p_hubspot_deal_id;
    return jsonb_build_object('ok', true, 'already', true, 'deal_id', v_existing,
      'reason', 'already promoted');
  end if;
  select id into v_existing from deals where hubspot_deal_id = p_hubspot_deal_id;
  if found then
    delete from promotion_approvals where hubspot_deal_id = p_hubspot_deal_id;
    return jsonb_build_object('ok', true, 'already', true, 'deal_id', v_existing,
      'reason', 'a deal already exists for this HubSpot deal');
  end if;

  select * into a from promotion_approvals where hubspot_deal_id = p_hubspot_deal_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'reason', 'no approval queued for this deal');
  end if;

  select * into m from pipeline_deals where hubspot_deal_id = p_hubspot_deal_id;
  if not found then
    -- the mirror is replaced wholesale every sync; a deal deleted in HubSpot
    -- simply stops existing here. Nothing to promote, and nothing we can
    -- invent — leave the approval for a human to dismiss.
    return jsonb_build_object('ok', false, 'held_back', true,
      'reason', 'no longer in the HubSpot mirror');
  end if;

  -- re-validate at the moment of the write: these were fine when the human
  -- approved, but HubSpot may have changed since. See the header for why the
  -- company check that used to live here is gone.
  v_blocker := case
    when m.campaign_start is null                 then 'no campaign start date'
    when m.campaign_end   is null                 then 'no campaign end date'
    when m.campaign_end < m.campaign_start        then 'campaign ends before it starts'
    else null end;
  if v_blocker is not null then
    return jsonb_build_object('ok', false, 'held_back', true,
      'deal_name', m.name, 'reason', v_blocker);
  end if;

  insert into deals (client_id, name, status, origin, flight_start, flight_end,
                     hubspot_deal_id, jobcode, qbo_project_id, promoted_at, set_by)
  values (a.client_id,
          coalesce(nullif(m.name, ''), 'Unnamed deal'),
          'won', 'hubspot',
          -- exact HubSpot campaign dates, not month-truncated (022 dropped the
          -- first-of-month constraint; v_deal_month_forecast date_truncs for
          -- its own month series)
          m.campaign_start, m.campaign_end,
          m.hubspot_deal_id, m.jobcode, a.qbo_project_id,
          now(), a.approved_by)
  returning id into v_deal_id;

  -- the as-sold record, amount included, forever — the whole mirror row, so
  -- nothing about how this deal looked at the door is lost
  insert into promotions (hubspot_deal_id, deal_id, promoted_by, source_payload)
  values (m.hubspot_deal_id, v_deal_id, a.approved_by, to_jsonb(m));

  v_fl := hs_flight_lines(m.line_items,
                          date_trunc('month', m.campaign_start)::date,
                          date_trunc('month', m.campaign_end)::date);
  for ln in select * from jsonb_array_elements(v_fl->'lines') loop
    insert into deal_lines (deal_id, kind, amount, budget, fee_pct,
                            hours_per_month, rate, billing_day, set_by)
    values (v_deal_id, (ln->>'kind')::line_kind, (ln->>'amount')::bigint, 0,
            (ln->>'fee_pct')::numeric, 0, 0,
            (case when ln->>'kind' = 'retainer' then 'first' else 'last' end)::billing_day,
            -- a machine marker, not the approver: a human decided to promote
            -- this deal, they did not shape these lines. Still unreviewed
            -- until someone blesses them in the Forecast.
            'promotion:line-items')
    returning id into v_line_id;

    if jsonb_typeof(ln->'months') = 'object' then
      insert into deal_line_months (deal_line_id, month, budget, set_by)
      select v_line_id, key::date, (value #>> '{}')::bigint, 'promotion:line-items'
      from jsonb_each(ln->'months');
    end if;
    v_flighted := true;
  end loop;

  delete from promotion_approvals where hubspot_deal_id = p_hubspot_deal_id;

  return jsonb_build_object(
    'ok', true, 'already', false,
    'deal_id', v_deal_id,
    'deal_name', coalesce(nullif(m.name, ''), 'Unnamed deal'),
    'client_id', a.client_id,
    'flighted', v_flighted,
    'lines', jsonb_array_length(v_fl->'lines'),
    'reason', case when v_flighted then null else v_fl->>'reason' end);

exception
  -- 059's optional unique index on deals.qbo_project_id is the one a human
  -- can actually trip at the gate: picking a project another deal already
  -- owns. Report it as held-back rather than handing the browser a 500 —
  -- the subtransaction rolls the whole promotion back, so the approval is
  -- still queued and the fix is to re-approve with a different project.
  when unique_violation then
    return jsonb_build_object('ok', false, 'held_back', true,
      'reason', 'conflicts with an existing row (' || sqlerrm || ')');
end;
$$;

comment on function promote_approval(text) is
  'Promote one approved HubSpot deal: create the deal, record the permanent '
  'promotion with its as-sold payload, flight the line items, consume the '
  'approval — all in one transaction. Called by Sales Forecast''s Approve '
  'button (the normal path) and by sync-hubspot.mjs for anything still queued '
  '(the retry). Both go through the single once-only check inside it, under an '
  'advisory lock, so a deal can never promote twice. Returns jsonb; expected '
  'outcomes are reported in it, not raised.';
