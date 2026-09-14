-- ============================================================================
--  107 — Live verdict while editing: price the UNSAVED scope, write nothing.
--
--  Boris: "I want it to be interactive." Revenue, GP and rebate already follow
--  every keystroke in the browser (the twin math). Labor cannot — rates never
--  leave SQL (salary privacy) — so the editor now sends the unsaved payload
--  after a short pause and paints the verdict the server returns.
--
--  preview_scope(payload, by): runs save_scope + scope_page INSIDE a
--  sub-transaction and rolls it back by raising a sentinel exception whose
--  DETAIL carries the page. Nothing persists: no rows, no version, no set_at.
--  The rate memo is warmed BEFORE the sub-block so the rollback does not throw
--  the warm-up away.
--
--  Fixture: db/107_fixture_test.sql (the preview prices the edited payload;
--  version, lines and versions are untouched; a later real save agrees).
-- ============================================================================

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
    raise exception using errcode = 'P0001', message = 'PREVIEW_ROLLBACK', detail = scope_page(v_id)::text;
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
  'The scope_page the payload WOULD produce if saved — labor, staffing, verdict, existing deals — with nothing written: save_scope + scope_page run in a sub-transaction that a sentinel exception rolls back (the page rides out in its DETAIL). Refuses approved/promoted scopes exactly as save_scope does. The editor calls it after a pause in typing (107).';
