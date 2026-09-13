-- ============================================================================
--  102 — Commercial terms from a scope.
--
--  A scope already knows everything the fee schedule of a statement of work
--  says: which lines, how each is charged (flat %, marginal bands, whole-spend
--  band, minimum, cap), who funds the media, the rebates, the retainer with its
--  included hours and overage rate, the flight and the payment terms.
--  scope_terms(scope_id) writes that down as plain text, one sentence per fact,
--  from templates in settings scope_terms_templates — EMG's wording today,
--  another agency's tomorrow, edited on Settings › Scoping. The backend margin
--  of a programmatic line is deliberately NEVER printed: it is EMG's, not the
--  client's.
--
--    render_template(tpl, vars)   replaces every {{key}} with vars ->> key
--    fmt_money(cents)             $50,000.00 — always two decimals, thousands
--    fmt_pct(numeric)             12.5 not 12.500; 15 not 15.000
--    scope_terms(scope_id)        {sections:[{key, deal_id, title, text}], text}
--    approve_scope                097 WHOLE + freezes scope_terms into
--                                 scopes.terms_text at approval, so the
--                                 wording as approved is kept even if the
--                                 templates change later
--
--  Fixture: db/102_fixture_test.sql. Page: the Terms button on app/scoping.html.
-- ============================================================================

insert into settings (key, value, set_by) values
  ('scope_terms_templates', '{"intro":"Scope of work for {{client}}: {{deals}}. Flight {{start}} to {{end}}.","deal":"{{deal}} ({{start}} to {{end}})","fee_flat":"{{line}}: management fee of {{pct}}% of monthly media spend.","fee_marginal":"{{line}}: management fee on monthly media spend, tiered: {{bands}}.","fee_marginal_band":"{{pct}}% on spend from {{from}} to {{to}}","fee_marginal_band_last":"{{pct}}% on spend above {{from}}","fee_whole":"{{line}}: management fee on monthly media spend, by band: {{bands}}.","fee_whole_band":"{{pct}}% of all spend when monthly spend is from {{from}} to {{to}}","fee_whole_band_last":"{{pct}}% of all spend when monthly spend is above {{from}}","fee_min":"Minimum monthly fee {{amount}}.","fee_cap":"Monthly fee capped at {{amount}}.","media_client":"Media is paid by the client directly to the platforms.","media_agency":"Media is paid by EMG and re-invoiced to the client at cost.","media_budget":"Planned media {{total}} over the flight.","programmatic_fee_margin":"{{line}}: programmatic media at a {{pct}}% buying fee on media spend; planned media {{total}} over the flight.","programmatic_cpm":"{{line}}: programmatic media billed at the agreed CPMs; planned budget {{total}} over the flight.","rebate_media":"EMG rebates {{pct}}% of {{line}} media spend to the client, invoiced by the client.","rebate_fee":"EMG rebates {{pct}}% of the {{line}} fee to the client, invoiced by the client.","retainer":"{{line}}: monthly retainer of {{amount}}{{hours_clause}}.","hours_included":", including up to {{hours}} hours per month","overage":"; additional hours at {{rate}} per hour","hourly":"{{line}}: {{hours}} hours per month at {{rate}} per hour.","payment_terms":"Invoices are due net {{net_days}} days."}'::jsonb, 'migration-102')
on conflict (key) do nothing;

create or replace function fmt_money(p_cents bigint)
returns text
language sql
immutable
as $$
  select case when p_cents is null then ''
              when p_cents < 0 then '-$' || trim(to_char(-p_cents / 100.0, 'FM999,999,999,990.00'))
              else '$' || trim(to_char(p_cents / 100.0, 'FM999,999,999,990.00')) end;
$$;

create or replace function fmt_pct(p numeric)
returns text
language sql
immutable
as $$
  select case when p is null then ''
              when p = trunc(p) then trunc(p)::text
              else rtrim(rtrim(p::text, '0'), '.') end;
$$;

create or replace function fmt_hours(p numeric)
returns text
language sql
immutable
as $$
  select case when p is null then '' when p = trunc(p) then trunc(p)::text else rtrim(rtrim(round(p, 2)::text, '0'), '.') end;
$$;

create or replace function render_template(p_tpl text, p_vars jsonb)
returns text
language plpgsql
immutable
as $$
declare k text; v text; s text := coalesce(p_tpl, '');
begin
  if p_vars is null or jsonb_typeof(p_vars) <> 'object' then return s; end if;
  for k, v in select key, value from jsonb_each_text(p_vars) loop
    s := replace(s, '{{' || k || '}}', coalesce(v, ''));
  end loop;
  return s;
end;
$$;

comment on function render_template(text, jsonb) is
  'Replaces every {{key}} in the template with the matching value; unknown placeholders stay as typed so a wrong template is visible, not silent.';

-- ---------------------------------------------------------------------------
--  scope_terms: one sentence per commercial fact, per deal, in line order
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

comment on function scope_terms(uuid) is
  'The commercial terms of a scope as plain sentences from settings scope_terms_templates: fee schedule per line (flat / marginal bands / whole-spend band, min, cap, media funding, planned media), rebates, retainers with included hours and overage, hourly lines, flight, payment terms, notes. The programmatic backend margin is never printed.';

-- ---------------------------------------------------------------------------
--  approve_scope: 097 WHOLE + the terms freeze
-- ---------------------------------------------------------------------------
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
  -- 102: freeze the commercial terms as worded at approval
  update scopes set terms_text = scope_terms(p_scope_id) ->> 'text' where id = p_scope_id;
  v_version := scope_snapshot(p_scope_id, 'approve', 'approved by ' || p_by, p_by);
  return jsonb_build_object('ok', true, 'status', 'approved', 'assignments_written', v_n, 'version', v_version);
end;
$$;

comment on function approve_scope(uuid, text) is
  'Approvers only, from proposed: sets approved, freezes scope_terms into scopes.terms_text (102), snapshots a version, and reserves the scope''s NAMED hours in assignments (deal_id null, scope_id set, set_by scope:approve). Placeholders are never written.';
