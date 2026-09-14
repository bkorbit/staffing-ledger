-- What every page actually costs, on the real data. Paste the whole file into
-- the Supabase SQL editor; it returns ONE result set, one row per payload, with
-- the time the database took and the size of the answer it would send.
--
-- It reads and writes nothing (and ends in ROLLBACK). The ranges are the ones
-- each page opens with, so the numbers are what a page load really pays.
--
-- `ms` is database time only. The browser also pays a round trip (roughly
-- 60-150 ms from a laptop), the download of `KB`, and the render. Worth
-- reporting back: anything over ~300 ms, or any payload over ~500 KB.

begin;
create temp table _t (n int generated always as identity, page text, ms numeric, kb numeric);

do $$
declare
  m0 date := date_trunc('month', current_date)::date;
  t0 timestamptz; j jsonb; v_scope uuid; v_deal uuid; v_client uuid;
  -- each page's own opening range
  back2 date := (date_trunc('month', current_date) - interval '2 months')::date;
  fwd3  date := (date_trunc('month', current_date) + interval '3 months')::date;
  back6 date := (date_trunc('month', current_date) - interval '6 months')::date;
  fwd6  date := (date_trunc('month', current_date) + interval '6 months')::date;
  fwd5  date := (date_trunc('month', current_date) + interval '5 months')::date;
  fwd11 date := (date_trunc('month', current_date) + interval '11 months')::date;
  eom   date := (date_trunc('month', current_date) + interval '1 month - 1 day')::date;
  eom3  date := (date_trunc('month', current_date) + interval '4 months - 1 day')::date;
begin
  select id into v_scope from scopes order by set_at desc nulls last limit 1;
  select t.deal_id into v_deal from time_entries t
    where t.deal_id is not null and coalesce(t.attribution, '') not in ('excluded', 'timeoff')
    group by t.deal_id order by sum(t.hours) desc limit 1;
  select d.client_id into v_client from time_entries t join deals d on d.id = t.deal_id
    where coalesce(t.attribution, '') not in ('excluded', 'timeoff')
    group by d.client_id order by sum(t.hours) desc limit 1;

  t0 := clock_timestamp();
  j := hours_page_parts(back2, eom3, array['staff','comp_current','staff_hours_month','staff_hours_deal',
                                           'deal_labor','time_off','deal_week_hours']);
  insert into _t (page, ms, kb) values ('Home · hours_page_parts (7 keys, 6 months)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  j := forecast_page_parts(back2, fwd3, array['plan_month','rev_month','rev_proj','cost_month','runrates']);
  insert into _t (page, ms, kb) values ('Home · forecast_page_parts (5 keys)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  select jsonb_agg(to_jsonb(r)) into j from cashflow_forecast(12) r;
  insert into _t (page, ms, kb) values ('Home · cashflow_forecast(12)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  select jsonb_agg(to_jsonb(p)) into j from pipeline_deals p
    where p.campaign_end is null or p.campaign_end >= '2026-01-01';
  insert into _t (page, ms, kb) values ('Home / Sales · pipeline_deals (campaigns touching 2026)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(coalesce(j::text, '')) / 1024.0));

  t0 := clock_timestamp();
  j := forecast_page(back6, fwd6);
  insert into _t (page, ms, kb) values ('Forecast · forecast_page (every key, 13 months)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  j := hours_page_parts(m0, eom, array['staff','comp_current','staff_hours_month','staff_hours_deal',
        'staff_planned','staff_deal_planned','deal_labor','time_off','measured_before',
        'staff_hours_deal_month','staff_deal_planned_month','deal_forecast','staff_rate_month']);
  insert into _t (page, ms, kb) values ('Team Hours · hours_page_parts (13 keys, this month)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  j := assignments_page(m0, fwd5);
  insert into _t (page, ms, kb) values ('Hour Planning · assignments_page (6 months)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));
  insert into _t (page, ms, kb) values ('   … of which assignments rows', null,
    round(length((j -> 'assignments')::text) / 1024.0));

  t0 := clock_timestamp();
  j := hours_page_parts(back2, eom3, array['staff','staff_hours_deal','staff_deal_planned','deal_labor','deal_planned']);
  insert into _t (page, ms, kb) values ('Project Hours · hours_page_parts (5 keys, 3 months)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  j := unmapped_hours(back2, eom3);
  insert into _t (page, ms, kb) values ('Project Hours · unmapped_hours (3 months)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  j := forecast_page_parts(back2, m0, array['plan_deal','rev_proj','cogs_proj','projects']);
  insert into _t (page, ms, kb) values ('Client Profitability · forecast_page_parts (4 keys)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  j := labor_page(m0, fwd11);
  insert into _t (page, ms, kb) values ('Labor · labor_page (12 months)',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  j := accounts_page();
  insert into _t (page, ms, kb) values ('Settings · accounts_page',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  t0 := clock_timestamp();
  j := scoping_list();
  insert into _t (page, ms, kb) values ('Scoping · scoping_list',
    round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));

  if v_scope is not null then
    t0 := clock_timestamp();
    j := scope_page(v_scope);
    insert into _t (page, ms, kb) values ('Scoping · scope_page (most recently saved scope)',
      round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));
    insert into _t (page, ms, kb) values ('   … scenarios in that family', null,
      (select count(*) from scopes s where s.family_id = (select family_id from scopes where id = v_scope)));
  end if;

  if v_deal is not null then
    t0 := clock_timestamp();
    j := project_detail(v_deal);
    insert into _t (page, ms, kb) values ('Project Hours · project_detail (the deal with the most hours)',
      round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));
  end if;

  if v_client is not null then
    t0 := clock_timestamp();
    j := client_detail(v_client);
    insert into _t (page, ms, kb) values ('Client Profitability · client_detail (the client with the most hours)',
      round(extract(epoch from clock_timestamp() - t0) * 1000), round(length(j::text) / 1024.0));
  end if;
end $$;

select page, ms, kb from _t where ms is not null
union all select page, ms, kb from _t where ms is null
union all
select 'rows — time_entries ' || (select count(*) from time_entries)
    || ' · assignments ' || (select count(*) from assignments)
    || ' · deals ' || (select count(*) from deals)
    || ' · invoice_lines ' || (select count(*) from invoice_lines)
    || ' · bill_lines ' || (select count(*) from bill_lines)
    || ' · pipeline_deals ' || (select count(*) from pipeline_deals)
    || ' · active staff ' || (select count(*) from staff where active)
    || ' · scopes ' || (select count(*) from scopes),
  null, null
order by ms desc nulls last;

rollback;
