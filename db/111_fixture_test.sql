-- Fixture test for 111 — NOT a migration, do not ship this file.
-- Run with 001-111 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the SINGLE result set — every line must say PASS
--   3. it ends in ROLLBACK
--
--   1. LIGHT VERDICT — scope_verdict_light = scope_verdict, key for key, on a
--                      scope that needs a hire and one that does not. This is
--                      the claim the whole migration rests on: the candidate
--                      ranking scope_verdict_light skips is never read by
--                      scope_verdict_calc.
--   2. STAFFING      — scope_staffing still carries every key it did, its
--                      hire/gap/unstaffable halves are scope_gap_hire's
--                      exactly, and only it has candidates.
--   3. CORE          — scope_page contains scope_core key for key, and a
--                      preview returns the scope's own state plus those six
--                      and NONE of the seven context keys it used to rebuild
--                      on every pause in typing.
--   4. LIST          — scoping_list's pipeline is exactly what the page's own
--                      filter keeps: one planted row of each kind it drops
--                      (promoted, dismissed, already scoped, off-pipeline,
--                      under the probability floor, finished before 2026) is
--                      gone, and the one good row is there.
--
-- Mutation check — each was applied in the PGlite bed and made its row FAIL:
--   * scope_verdict_calc: read `candidates` as well as `hire`      -> row 1
--   * scope_gap_hire: drop the `having sum(unstaffable) > 0`       -> rows 1, 2
--   * scope_staffing: drop the scope_gap_hire merge                -> row 2
--   * scope_core: leave prog_margin out                            -> row 3
--   * scoping_list: drop the already-scoped exclusion              -> row 4

begin;
insert into settings (key, value) values
  ('scope_target_profit_per_hour', '150'), ('scope_target_utilization_pct', '80'),
  ('scope_min_margin_presets', '[{"name":"Target","pct":35}]'),
  ('scope_comp_bands', '[{"name":"Band A","upto_c":6000},{"name":"Band B"}]'),
  ('scope_hire_costs', '{"Paid Media":{"annual_c":12000000,"contractor_hourly_c":9000}}'),
  ('scope_hire_min_months', '2'), ('scope_hire_fte_share_pct', '50'),
  ('hubspot_promote_pipelines', '["Agency  Sales"]'), ('sales_probability_threshold', '25'),
  ('scope_approver_emails', '["b@x"]')
on conflict (key) do update set value = excluded.value;

create temp table _fx as select date_trunc('month', current_date)::date as cur,
  (date_trunc('month', current_date) + interval '5 months')::date as f1;
insert into clients (id, name, active) values ('11111111-0000-0000-0000-000000000111', '_fx111 Client', true);
insert into staff (id, name, department, active, tracks_capacity, start_date)
select '11111111-0000-0000-0000-0000000a0111'::uuid, '_fx111 A', 'Paid Media', true, true, (cur - 400)::date from _fx;
insert into comp_periods (staff_id, starts_on, kind, annual_cost, weekly_capacity, employment_type)
select '11111111-0000-0000-0000-0000000a0111'::uuid, (cur - 400)::date, 'salary'::comp_kind, 12000000, 40, 'full_time' from _fx;

-- two scenarios in ONE family: a heavy one whose demand no one can cover (so
-- the hire option fires and the verdict's status depends on it) and a light one
create temp table _ids as
select (save_scope(jsonb_build_object(
    'name', '_fx111 heavy', 'client_id', '11111111-0000-0000-0000-000000000111',
    'deals', jsonb_build_array(jsonb_build_object('name', 'd', 'origin_kind', 'new', 'promote_mode', 'new',
        'flight_start', cur, 'flight_end', f1,
        'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 4000000)))),
    'dept_months', (select jsonb_agg(jsonb_build_object('department', 'Paid Media', 'month', gs::date, 'hours', 400))
                    from generate_series(cur, f1, interval '1 month') gs),
    'staff_months', '[]'::jsonb), 'b@x', null) ->> 'scope_id')::uuid as heavy, cur, f1
from _fx;
create temp table _ids2 as
select (save_scope(jsonb_build_object(
    'name', '_fx111 light', 'client_id', '11111111-0000-0000-0000-000000000111',
    'deals', jsonb_build_array(jsonb_build_object('name', 'd', 'origin_kind', 'new', 'promote_mode', 'new',
        'flight_start', cur, 'flight_end', f1,
        'lines', jsonb_build_array(jsonb_build_object('kind', 'retainer', 'amount', 900000)))),
    'dept_months', (select jsonb_agg(jsonb_build_object('department', 'Paid Media', 'month', gs::date, 'hours', 4))
                    from generate_series(cur, f1, interval '1 month') gs),
    'staff_months', '[]'::jsonb), 'b@x', null) ->> 'scope_id')::uuid as light
from _fx;
update scopes set family_id = (select family_id from scopes where id = (select heavy from _ids))
where id = (select light from _ids2);

-- the pipeline: one row that must survive, and one of every kind that must not
insert into pipeline_deals (hubspot_deal_id, name, company, stage, probability, amount, close_date, campaign_start, campaign_end, is_won, pipeline) values
  ('_fx111_keep',      'keep',      'Co', 's', 0.40, 100, current_date, '2026-03-01', '2026-09-30', false, 'agency sales'),
  ('_fx111_keep_won',  'keep won',  'Co', 's', 0.01, 100, current_date, '2026-03-01', '2026-09-30', true,  'Agency Sales'),
  ('_fx111_promoted',  'promoted',  'Co', 's', 0.90, 100, current_date, '2026-03-01', '2026-09-30', false, 'agency sales'),
  ('_fx111_dismissed', 'dismissed', 'Co', 's', 0.90, 100, current_date, '2026-03-01', '2026-09-30', false, 'agency sales'),
  ('_fx111_scoped',    'scoped',    'Co', 's', 0.90, 100, current_date, '2026-03-01', '2026-09-30', false, 'agency sales'),
  ('_fx111_offpipe',   'off',       'Co', 's', 0.90, 100, current_date, '2026-03-01', '2026-09-30', false, 'recruiting'),
  ('_fx111_lowprob',   'low',       'Co', 's', 0.10, 100, current_date, '2026-03-01', '2026-09-30', false, 'agency sales'),
  ('_fx111_old',       'old',       'Co', 's', 0.90, 100, current_date, '2025-01-01', '2025-12-31', false, 'agency sales');
insert into deals (id, client_id, name, status, origin, flight_start, flight_end, hubspot_deal_id)
select '11111111-0000-0000-0000-0000000d0111'::uuid, '11111111-0000-0000-0000-000000000111'::uuid, '_fx111 promoted deal',
       'active'::deal_status, 'hubspot'::deal_origin, cur, f1, '_fx111_promoted' from _fx;
insert into promotions (hubspot_deal_id, deal_id, promoted_by, source_payload)
values ('_fx111_promoted', '11111111-0000-0000-0000-0000000d0111', 'b@x', '{}'::jsonb);
insert into won_deal_dismissals (hubspot_deal_id, dismissed_by) values ('_fx111_dismissed', 'b@x');
insert into scope_deals (scope_id, name, origin_kind, promote_mode, hubspot_deal_id, flight_start, flight_end)
select light, '_fx111 scoped', 'hubspot', 'hubspot', '_fx111_scoped', (select cur from _fx), (select f1 from _fx) from _ids2;

create temp table _pg as select scope_page((select heavy from _ids)) as j;
create temp table _core as select scope_core((select heavy from _ids)) as j;
create temp table _prev as select preview_scope(
  (select to_jsonb(x) from (select (select heavy from _ids) as id, '_fx111 heavy' as name,
     '11111111-0000-0000-0000-000000000111'::uuid as client_id,
     (select jsonb_agg(jsonb_build_object('name','d','origin_kind','new','promote_mode','new',
        'flight_start',cur,'flight_end',f1,'lines',jsonb_build_array(jsonb_build_object('kind','retainer','amount',4000000))))
      from _fx) as deals,
     (select jsonb_agg(jsonb_build_object('department','Paid Media','month',gs::date,'hours',400))
      from _fx, generate_series(cur, f1, interval '1 month') gs) as dept_months,
     '[]'::jsonb as staff_months) x), 'b@x') as j;
create temp table _list as select scoping_list() as j;

with r(n, result) as (
  select 1, case when scope_verdict_light((select heavy from _ids)) = scope_verdict((select heavy from _ids))
                  and scope_verdict_light((select light from _ids2)) = scope_verdict((select light from _ids2))
                  and jsonb_array_length(scope_gap_hire((select heavy from _ids)) -> 'hire') > 0
                  and jsonb_array_length(scope_gap_hire((select light from _ids2)) -> 'hire') = 0
                  and (scope_verdict((select heavy from _ids)) ->> 'status') is not null
    then '1. LIGHT VERDICT identical to the full one on both scenarios, and the heavy one really does trigger a hire (so the hire path is exercised, not skipped): PASS'
    else '1. LIGHT VERDICT: FAIL — heavy light/full ' || (scope_verdict_light((select heavy from _ids)) = scope_verdict((select heavy from _ids)))::text
      || ', light light/full ' || (scope_verdict_light((select light from _ids2)) = scope_verdict((select light from _ids2)))::text
      || ', heavy hire rows ' || jsonb_array_length(scope_gap_hire((select heavy from _ids)) -> 'hire')::text end
  union all
  select 2, case when (select array_agg(k order by k) from jsonb_object_keys(scope_staffing((select heavy from _ids))) k)
                     = array['candidates','gap','hire','knobs','months','unstaffable']
                  and (select array_agg(k order by k) from jsonb_object_keys(scope_gap_hire((select heavy from _ids))) k)
                     = array['gap','hire','knobs','months','unstaffable']
                  and not exists (select 1 from jsonb_object_keys(scope_gap_hire((select heavy from _ids))) k
                                  where scope_gap_hire((select heavy from _ids)) -> k
                                     is distinct from scope_staffing((select heavy from _ids)) -> k)
                  and jsonb_array_length(scope_staffing((select heavy from _ids)) -> 'candidates') > 0
    then '2. STAFFING every key scope_staffing had, its five shared ones byte-identical to scope_gap_hire''s, and candidates only on the full one: PASS'
    else '2. STAFFING: FAIL — staffing keys ' || (select array_agg(k order by k)::text from jsonb_object_keys(scope_staffing((select heavy from _ids))) k)
      || ' gap_hire keys ' || (select array_agg(k order by k)::text from jsonb_object_keys(scope_gap_hire((select heavy from _ids))) k) end
  union all
  select 3, case when (select array_agg(k order by k) from _core, jsonb_object_keys(j) k)
                     = array['econ','existing_deals','labor','prog_margin','staffing','verdict']
                  and not exists (select 1 from _core c, _pg p, jsonb_object_keys(c.j) k where c.j -> k is distinct from p.j -> k)
                  and (select (j ->> 'ok')::boolean from _prev)
                  -- the preview's reply: the scope's own state, the six moving
                  -- keys, and none of the context it used to rebuild
                  and not exists (select 1 from unnest(array['siblings','versions','staff','departments','clients','settings','sources']) k
                                  where (select j -> 'page' from _prev) ? k)
                  and (select count(*) from _pg, jsonb_object_keys(j) k
                       where k in ('siblings','versions','staff','departments','clients','settings','sources')) = 7
                  -- every key but econ, byte for byte. econ rows carry
                  -- scope_line_id, and a preview's save writes new line rows
                  -- (inside the sub-transaction it then rolls back), so those
                  -- ids differ by construction — the money is what must match,
                  -- and 107_fixture_test pins the verdict the same way.
                  and not exists (select 1 from _core c, _prev p, jsonb_object_keys(c.j) k
                                  where k <> 'econ' and c.j -> k is distinct from p.j -> 'page' -> k)
                  and (select sum((e ->> 'gp')::bigint) || '/' || sum((e ->> 'billable')::bigint)
                       from _core, jsonb_array_elements(j -> 'econ') e)
                    = (select sum((e ->> 'gp')::bigint) || '/' || sum((e ->> 'billable')::bigint)
                       from _prev, jsonb_array_elements(j -> 'page' -> 'econ') e)
                  and (select (j -> 'page' ->> 'id')::uuid from _prev) = (select heavy from _ids)

                  and (select count(*) from scope_versions where scope_id = (select heavy from _ids)) = 1
    then '3. CORE scope_page carries every scope_core key unchanged and all seven context keys; a preview returns the six moving ones for the right scope and not one of the seven; and it still wrote nothing (one version, from the save): PASS'
    else '3. CORE: FAIL — core keys ' || (select array_agg(k order by k)::text from _core, jsonb_object_keys(j) k)
      || ' differing: ' || coalesce((select string_agg(k, ',') from _core c, _prev p, jsonb_object_keys(c.j) k
             where k <> 'econ' and c.j -> k is distinct from p.j -> 'page' -> k), 'none')
      || ' context keys still in the preview ' || coalesce((select string_agg(k, ',') from unnest(array['siblings','versions','staff','departments','clients','settings','sources']) k where (select j -> 'page' from _prev) ? k), 'none')
      || ' versions ' || (select count(*)::text from scope_versions where scope_id = (select heavy from _ids)) end
  union all
  select 4, case when (select array_agg(x ->> 'hubspot_deal_id' order by x ->> 'hubspot_deal_id')
                       from _list, jsonb_array_elements(j -> 'pipeline') x
                       where x ->> 'hubspot_deal_id' like '\_fx111%') = array['_fx111_keep', '_fx111_keep_won']
    then '4. LIST the pipeline carries the open deal over the floor and the won one under it, and drops the promoted, the dismissed, the already-scoped, the off-pipeline, the under-floor and the pre-2026 ones: PASS'
    else '4. LIST: FAIL — kept ' || coalesce((select array_agg(x ->> 'hubspot_deal_id' order by x ->> 'hubspot_deal_id')::text
           from _list, jsonb_array_elements(j -> 'pipeline') x where x ->> 'hubspot_deal_id' like '\_fx111%'), 'none') end
)
select result from r order by n;

rollback;
