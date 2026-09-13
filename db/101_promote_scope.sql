-- ============================================================================
--  101 — The promotion door for scopes.
--
--  An approved scope becomes real deals, in one transaction, through the same
--  once-only door HubSpot deals already use:
--
--    promote_approval(hubspot_deal_id)  078 reproduced WHOLE with one marked
--      branch: when an APPROVED scope deal exists for that HubSpot id, the new
--      deal takes the SCOPE's flight dates (flight_locked, so the sync never
--      writes HubSpot's back — Boris: the scope is the reviewed truth) and the
--      scope's lines (structure and rebate included, 100) instead of
--      hs_flight_lines; the scope deal is marked promoted and the scope's
--      reserved hours relink to the deal. No scope → 078's path, verbatim.
--      Same advisory lock, same once-only check, so a deal still cannot
--      promote twice, and the nightly sync's retry gets scope lines for free.
--
--    promote_scope(scope_id, by, projects)  approvers only, scope approved.
--      Walks the scope's deals in order, ALL OR NOTHING (a failure raises and
--      the exception handler returns {ok:false, reason, results} with
--      nothing written):
--        hubspot   upserts promotion_approvals (client from the scope, QBO
--                  project from p_projects[scope_deal_id] or the scope deal)
--                  and calls promote_approval — lock order promote_scope →
--                  promote_approval, never the other way, so no deadlock;
--        new       inserts a manual deal (won, exact flight, flight_locked,
--                  scope_id) and its lines for every flight month;
--        extend    the source deal grows to the scope deal's dates, its
--                  existing lines are ended from THIS month on (explicit zero
--                  month rows — closed months stay exactly as frozen), and the
--                  scope's lines are added for this month forward, their own
--                  closed months pinned at zero so a flat amount cannot leak
--                  into the past. Boris: the user chooses new vs extend.
--      Then the scope's reserved hours (assignments with scope_id, deal_id
--      null) relink to the first promoted deal (merging with any existing row
--      for the same person and month), and once every scope deal is promoted
--      the scope is marked promoted and a version snapshot is taken.
--
--    promote_scope_lines / relink_scope_assignments / finish_scope_promotion
--      the helpers both doors share.
--
--  Fixture: db/101_fixture_test.sql (+ re-run 078 and 097).
-- ============================================================================

-- ---------------------------------------------------------------------------
--  promote_scope_lines: scope deal → deal_lines + deal_line_months
-- ---------------------------------------------------------------------------
create or replace function promote_scope_lines(p_deal_id uuid, p_scope_deal_id uuid, p_by text, p_from_month date default null)
returns int
language plpgsql
as $$
declare r record; v_line uuid; v_n int := 0; v_scope uuid;
begin
  select scope_id into v_scope from scope_deals where id = p_scope_deal_id;
  for r in select sl.* from scope_lines sl where sl.scope_deal_id = p_scope_deal_id order by sl.ord, sl.set_at loop
    insert into deal_lines (deal_id, kind, label, amount, budget, fee_pct, margin_pct, rate, hours_per_month,
                            billing_day, media_funding, structure, rebate_pct, rebate_basis, scope_id, set_by)
    values (p_deal_id, r.kind, r.label, r.amount, r.budget, r.fee_pct, r.margin_pct, r.rate, r.hours_per_month,
            r.billing_day, r.media_funding, coalesce(r.structure, '{}'::jsonb),
            nullif(r.structure #>> '{rebate,pct}', '')::numeric,
            case when nullif(r.structure #>> '{rebate,pct}', '') is not null then coalesce(r.structure #>> '{rebate,basis}', 'media') end,
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

comment on function promote_scope_lines(uuid, uuid, text, date) is
  'Copies a scope deal''s lines (structure, rebate as columns, scope_id, set_by promotion:scope) and their month cells onto a deal; p_from_month limits the cells to months from that date on (extend mode).';

-- ---------------------------------------------------------------------------
--  relink_scope_assignments: the approved scope's reservations become the
--  deal's plan; a row that already exists for that person and month is merged
-- ---------------------------------------------------------------------------
create or replace function relink_scope_assignments(p_scope_id uuid, p_deal_id uuid)
returns int
language plpgsql
as $$
declare r record; v_n int := 0;
begin
  for r in select * from assignments where scope_id = p_scope_id and deal_id is null loop
    if exists (select 1 from assignments x where x.staff_id = r.staff_id and x.deal_id = p_deal_id and x.month = r.month) then
      update assignments set hours = hours + r.hours, scope_id = p_scope_id, set_by = 'scope:promote', set_at = now()
      where staff_id = r.staff_id and deal_id = p_deal_id and month = r.month;
      delete from assignments where id = r.id;
    else
      update assignments set deal_id = p_deal_id, set_by = 'scope:promote', set_at = now() where id = r.id;
    end if;
    v_n := v_n + 1;
  end loop;
  return v_n;
end;
$$;

create or replace function finish_scope_promotion(p_scope_id uuid, p_by text)
returns boolean
language plpgsql
as $$
begin
  if exists (select 1 from scope_deals where scope_id = p_scope_id and promoted_deal_id is null) then
    return false;
  end if;
  update scopes set status = 'promoted', promoted_at = now(), set_by = p_by, set_at = now()
  where id = p_scope_id and status = 'approved';
  if found then perform scope_snapshot(p_scope_id, 'promote', 'promoted by ' || coalesce(p_by, '?'), p_by); end if;
  return true;
end;
$$;

-- ---------------------------------------------------------------------------
--  promote_approval: 078 WHOLE + the `101` scope branch
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
  v_sd       record;            -- 101: the approved scope deal for this HubSpot id, if any
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

  -- 101: an APPROVED scope for this HubSpot deal supplies the lines and the
  -- flight dates (the scope is the reviewed commercial truth; HubSpot's dates
  -- are the seller's first guess) — the deal is then flight_locked so the sync
  -- never writes HubSpot's dates back over them. No approved scope → 078's
  -- hs_flight_lines path, verbatim, below.
  select sd.id, sd.scope_id, sd.flight_start, sd.flight_end, sd.name
    into v_sd
  from scope_deals sd
  join scopes s on s.id = sd.scope_id
  where sd.hubspot_deal_id = p_hubspot_deal_id
    and s.status = 'approved' and sd.promoted_deal_id is null
    and sd.flight_start is not null and sd.flight_end is not null
  order by s.approved_at desc nulls last, s.set_at desc
  limit 1;

  insert into deals (client_id, name, status, origin, flight_start, flight_end,
                     hubspot_deal_id, jobcode, qbo_project_id, promoted_at, set_by,
                     flight_locked, scope_id)
  values (a.client_id,
          coalesce(nullif(m.name, ''), 'Unnamed deal'),
          'won', 'hubspot',
          -- exact HubSpot campaign dates, not month-truncated (022 dropped the
          -- first-of-month constraint; v_deal_month_forecast date_truncs for
          -- its own month series) — or the approved scope's dates (101)
          coalesce(v_sd.flight_start, m.campaign_start), coalesce(v_sd.flight_end, m.campaign_end),
          m.hubspot_deal_id, m.jobcode, a.qbo_project_id,
          now(), a.approved_by,
          v_sd.id is not null, v_sd.scope_id)
  returning id into v_deal_id;

  -- the as-sold record, amount included, forever — the whole mirror row, so
  -- nothing about how this deal looked at the door is lost
  insert into promotions (hubspot_deal_id, deal_id, promoted_by, source_payload)
  values (m.hubspot_deal_id, v_deal_id, a.approved_by, to_jsonb(m));

  if v_sd.id is not null then
    -- 101: the scope's lines, structure and rebates included; the scope deal
    -- is marked promoted and the scope's reserved hours relink to this deal
    v_fl := jsonb_build_object('lines', (select coalesce(jsonb_agg(1), '[]'::jsonb) from scope_lines sl where sl.scope_deal_id = v_sd.id), 'reason', null);
    perform promote_scope_lines(v_deal_id, v_sd.id, a.approved_by, null);
    update scope_deals set promoted_deal_id = v_deal_id where id = v_sd.id;
    perform relink_scope_assignments(v_sd.scope_id, v_deal_id);
    perform finish_scope_promotion(v_sd.scope_id, a.approved_by);
    v_flighted := jsonb_array_length(v_fl->'lines') > 0;
  else
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
  end if;   -- 101

  delete from promotion_approvals where hubspot_deal_id = p_hubspot_deal_id;

  return jsonb_build_object(
    'ok', true, 'already', false,
    'deal_id', v_deal_id,
    'deal_name', coalesce(nullif(m.name, ''), 'Unnamed deal'),
    'client_id', a.client_id,
    'flighted', v_flighted,
    'lines', jsonb_array_length(v_fl->'lines'),
    'scope_id', v_sd.scope_id,                       -- 101
    'scope_deal_id', v_sd.id,
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
  'Promote one approved HubSpot deal: create the deal, record the permanent promotion with its as-sold payload, flight the lines, consume the approval — all in one transaction, under an advisory lock with the single once-only check (078). 101: when an approved scope deal exists for the HubSpot id, the scope''s flight dates (flight_locked) and lines are used instead of hs_flight_lines, the scope deal is marked promoted, its reserved hours relink, and the result carries scope_id. Called by Sales Forecast''s Approve button, by promote_scope, and by sync-hubspot.mjs as the retry.';

-- ---------------------------------------------------------------------------
--  promote_scope: every deal of an approved scope, all or nothing
-- ---------------------------------------------------------------------------
create or replace function promote_scope(p_scope_id uuid, p_by text, p_projects jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
as $$
declare
  sc scopes%rowtype; sd record; r jsonb; v_results jsonb := '[]'::jsonb; v_deal uuid; v_first uuid;
  v_qbo text; v_cur date := date_trunc('month', current_date)::date; v_src deals%rowtype; v_reason text;
begin
  if not scope_is_approver(p_by) then
    return jsonb_build_object('ok', false, 'reason', 'only an approver (Settings › Scoping) can promote');
  end if;
  perform pg_advisory_xact_lock(hashtext('promote_scope'), hashtext(p_scope_id::text));
  select * into sc from scopes where id = p_scope_id for update;
  if not found then return jsonb_build_object('ok', false, 'reason', 'scope not found'); end if;
  if sc.status <> 'approved' then
    return jsonb_build_object('ok', false, 'reason', 'a scope is promoted from approved (it is ' || sc.status || ')');
  end if;

  for sd in select * from scope_deals where scope_id = p_scope_id and promoted_deal_id is null order by ord, id loop
    v_deal := null; v_reason := null;
    if sd.flight_start is null or sd.flight_end is null then
      raise exception 'SCOPE_ABORT:%:%', sd.id, 'no flight dates on ' || sd.name;
    end if;

    if sd.promote_mode = 'hubspot' then
      v_qbo := coalesce(nullif(p_projects ->> sd.id::text, ''), sd.qbo_project_id);
      if sd.hubspot_deal_id is null then raise exception 'SCOPE_ABORT:%:%', sd.id, 'no HubSpot deal on ' || sd.name; end if;
      if sc.client_id is null then raise exception 'SCOPE_ABORT:%:%', sd.id, 'the scope has no client'; end if;
      if v_qbo is null then raise exception 'SCOPE_ABORT:%:%', sd.id, 'pick the QuickBooks project for ' || sd.name; end if;
      insert into promotion_approvals (hubspot_deal_id, client_id, qbo_project_id, approved_by)
      values (sd.hubspot_deal_id, sc.client_id, v_qbo, p_by)
      on conflict (hubspot_deal_id) do update set client_id = excluded.client_id, qbo_project_id = excluded.qbo_project_id,
        approved_by = excluded.approved_by, approved_at = now();
      r := promote_approval(sd.hubspot_deal_id);
      if not coalesce((r ->> 'ok')::boolean, false) then
        raise exception 'SCOPE_ABORT:%:%', sd.id, coalesce(r ->> 'reason', 'promotion held back');
      end if;
      if coalesce((r ->> 'already')::boolean, false) then
        raise exception 'SCOPE_ABORT:%:%', sd.id, 'HubSpot deal already promoted without this scope (' || coalesce(r ->> 'reason', '') || ')';
      end if;
      v_deal := (r ->> 'deal_id')::uuid;

    elsif sd.promote_mode = 'extend' then
      select * into v_src from deals where id = sd.source_deal_id for update;
      if not found then raise exception 'SCOPE_ABORT:%:%', sd.id, 'the source deal of ' || sd.name || ' no longer exists'; end if;
      update deals set
        flight_start = least(flight_start, sd.flight_start),
        flight_end = greatest(flight_end, sd.flight_end),
        flight_locked = true, scope_id = p_scope_id, set_by = p_by, set_at = now()
      where id = v_src.id;
      -- end the existing lines from this month on: an explicit zero cell per
      -- open month (closed months keep exactly what they had)
      insert into deal_line_months (deal_line_id, month, budget, amount, hours, set_by)
      select dl.id, gs::date, 0, 0, 0, 'promotion:scope-extend'
      from deal_lines dl
      cross join lateral generate_series(greatest(v_cur, date_trunc('month', least(v_src.flight_start, sd.flight_start))),
                                         date_trunc('month', greatest(v_src.flight_end, sd.flight_end)), interval '1 month') gs
      where dl.deal_id = v_src.id
      on conflict (deal_line_id, month) do update set budget = 0, amount = 0, hours = 0, set_by = 'promotion:scope-extend', set_at = now();
      -- the scope's lines from this month forward …
      perform promote_scope_lines(v_src.id, sd.id, p_by, v_cur);
      -- … pinned at zero in the deal's closed months, so a flat amount cannot
      -- project backwards into months already measured
      insert into deal_line_months (deal_line_id, month, budget, amount, hours, set_by)
      select dl.id, gs::date, 0, 0, 0, 'promotion:scope-extend-closed'
      from deal_lines dl
      cross join lateral generate_series(date_trunc('month', least(v_src.flight_start, sd.flight_start)),
                                         date_trunc('month', greatest(v_src.flight_end, sd.flight_end)), interval '1 month') gs
      where dl.deal_id = v_src.id and dl.scope_id = p_scope_id and dl.set_by = 'promotion:scope' and gs::date < v_cur
      on conflict (deal_line_id, month) do nothing;
      v_deal := v_src.id;

    else  -- new
      if sc.client_id is null then raise exception 'SCOPE_ABORT:%:%', sd.id, 'the scope has no client'; end if;
      v_qbo := coalesce(nullif(p_projects ->> sd.id::text, ''), sd.qbo_project_id);
      insert into deals (client_id, name, status, origin, flight_start, flight_end, qbo_project_id, promoted_at, set_by, flight_locked, scope_id)
      values (sc.client_id, sd.name, 'won', 'manual', sd.flight_start, sd.flight_end, v_qbo, now(), p_by, true, p_scope_id)
      returning id into v_deal;
      perform promote_scope_lines(v_deal, sd.id, p_by, null);
    end if;

    update scope_deals set promoted_deal_id = v_deal, qbo_project_id = coalesce(v_qbo, qbo_project_id) where id = sd.id;
    if v_first is null then v_first := v_deal; end if;
    v_results := v_results || jsonb_build_object('scope_deal_id', sd.id, 'name', sd.name, 'mode', sd.promote_mode, 'deal_id', v_deal, 'ok', true);
  end loop;

  if v_first is not null then perform relink_scope_assignments(p_scope_id, v_first); end if;
  perform finish_scope_promotion(p_scope_id, p_by);

  return jsonb_build_object('ok', true, 'results', v_results,
    'scope_status', (select status from scopes where id = p_scope_id),
    'deal_ids', (select coalesce(jsonb_agg(promoted_deal_id), '[]'::jsonb) from scope_deals where scope_id = p_scope_id and promoted_deal_id is not null));
exception
  when raise_exception then
    if sqlerrm like 'SCOPE_ABORT:%' then
      return jsonb_build_object('ok', false, 'scope_deal_id', split_part(sqlerrm, ':', 2),
        'reason', substr(sqlerrm, length('SCOPE_ABORT:') + 38), 'results', v_results);
    end if;
    raise;
  when unique_violation then
    return jsonb_build_object('ok', false, 'reason', 'conflicts with an existing row (' || sqlerrm || ')', 'results', v_results);
end;
$$;

comment on function promote_scope(uuid, text, jsonb) is
  'Approvers only: promote every not-yet-promoted deal of an APPROVED scope, all or nothing — hubspot deals through promote_approval (approval upserted first), new deals as manual won deals, extend deals by ending the source deal''s lines from this month and adding the scope''s. Relinks the scope''s reserved hours to the first promoted deal; marks the scope promoted when every deal is. p_projects = {scope_deal_id: qbo_project_id}.';
