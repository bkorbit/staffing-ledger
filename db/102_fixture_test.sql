-- Fixture test for 102 — NOT a migration, do not ship this file.
-- Run against a scratch db (or prod, rolled back) with 001-102 applied.
--   1. paste this whole file (it opens its own transaction)
--   2. read the rows of the SINGLE result set at the bottom — every numbered
--      line must say PASS
--   3. it ends in ROLLBACK
--
-- The default templates are used (they are re-inserted here so a customised
-- production set cannot change the expected strings). One scope, one deal,
-- four lines: marginal-band paid search with a $5,000 minimum, EMG-funded,
-- 2% rebate on the fee; programmatic fee 5% + backend 30% with a 2% media
-- rebate; a retainer with 20 included hours and $250/h overage; an hourly line.
--
--   1. FORMAT   — fmt_money / fmt_pct / fmt_hours: $50,000.00, 12.5 (not
--                 12.500), 15 (not 15.000), 12.5h
--   2. SEARCH   — the exact sentence: bands in order with $0.00 to $50,000.00
--                 … above $150,000.00, the minimum, EMG funding, planned media
--                 $140,000.00, and the rebate on the fee
--   3. PROG     — the fee % is printed, the backend margin is NOT
--   4. RETAINER — "$10,000.00, including up to 20 hours per month; additional
--                 hours at $250.00 per hour."
--   5. FREEZE   — approve_scope writes scopes.terms_text = the text at approval;
--                 changing a template afterwards changes scope_terms but not
--                 the frozen text
--
-- Mutation check (PGlite bed) — each must FAIL:
--   * scope_terms: iterate bands in reverse order                    -> row 2
--   * scope_terms: print margin_pct in the programmatic sentence      -> row 3
--   * fmt_pct: return p::text                                          -> row 1, 2
--   * approve_scope: drop the terms freeze                             -> row 5

begin;
create temp table _fx as
select date_trunc('month', current_date)::date as cur, (date_trunc('month', current_date) + interval '1 month')::date as n1;
insert into settings (key, value, set_by) values
  ('scope_approver_emails', '["boss@fx102"]'::jsonb, 'fx102'),
  ('scope_terms_templates', (select value from settings where key = 'scope_terms_templates' and set_by = 'migration-102'), 'fx102')
on conflict (key) do update set value = excluded.value;
-- if a customised set had replaced the defaults, put the defaults back for this run
update settings set value = '{"intro":"Scope of work for {{client}}: {{deals}}. Flight {{start}} to {{end}}.","deal":"{{deal}} ({{start}} to {{end}})","fee_flat":"{{line}}: management fee of {{pct}}% of monthly media spend.","fee_marginal":"{{line}}: management fee on monthly media spend, tiered: {{bands}}.","fee_marginal_band":"{{pct}}% on spend from {{from}} to {{to}}","fee_marginal_band_last":"{{pct}}% on spend above {{from}}","fee_whole":"{{line}}: management fee on monthly media spend, by band: {{bands}}.","fee_whole_band":"{{pct}}% of all spend when monthly spend is from {{from}} to {{to}}","fee_whole_band_last":"{{pct}}% of all spend when monthly spend is above {{from}}","fee_min":"Minimum monthly fee {{amount}}.","fee_cap":"Monthly fee capped at {{amount}}.","media_client":"Media is paid by the client directly to the platforms.","media_agency":"Media is paid by EMG and re-invoiced to the client at cost.","media_budget":"Planned media {{total}} over the flight.","programmatic_fee_margin":"{{line}}: programmatic media at a {{pct}}% buying fee on media spend; planned media {{total}} over the flight.","programmatic_cpm":"{{line}}: programmatic media billed at the agreed CPMs; planned budget {{total}} over the flight.","rebate_media":"EMG rebates {{pct}}% of {{line}} media spend to the client, invoiced by the client.","rebate_fee":"EMG rebates {{pct}}% of the {{line}} fee to the client, invoiced by the client.","retainer":"{{line}}: monthly retainer of {{amount}}{{hours_clause}}.","hours_included":", including up to {{hours}} hours per month","overage":"; additional hours at {{rate}} per hour","hourly":"{{line}}: {{hours}} hours per month at {{rate}} per hour.","payment_terms":"Invoices are due net {{net_days}} days."}'::jsonb
where key = 'scope_terms_templates';

insert into clients (id, name, active) values ('f0f0f0f0-0000-0000-0000-000000000102', 'Acme Travel', true);
create temp table _s as select ((save_scope(jsonb_build_object(
  'name', '_fx102 scope', 'client_id', 'f0f0f0f0-0000-0000-0000-000000000102', 'payment_net_days', 45,
  'deals', jsonb_build_array(jsonb_build_object('name', 'Q4 campaign', 'origin_kind', 'new', 'promote_mode', 'new',
    'flight_start', (select cur from _fx), 'flight_end', (select (n1 + 27)::date from _fx),
    'lines', jsonb_build_array(
      jsonb_build_object('ord', 0, 'kind', 'search', 'fee_pct', 0, 'media_funding', 'agency',
        'structure', jsonb_build_object('fee', jsonb_build_object('mode', 'marginal', 'bands', jsonb_build_array(
            jsonb_build_object('upto', 5000000, 'pct', 15), jsonb_build_object('upto', 15000000, 'pct', 12.5), jsonb_build_object('upto', null, 'pct', 10))),
          'fee_min', 500000, 'rebate', jsonb_build_object('pct', 2, 'basis', 'fee')),
        'months', jsonb_build_object((select cur::text from _fx), jsonb_build_object('budget', 12000000), (select n1::text from _fx), jsonb_build_object('budget', 2000000))),
      jsonb_build_object('ord', 1, 'kind', 'programmatic', 'fee_pct', 5, 'margin_pct', 30, 'budget', 10000000,
        'structure', jsonb_build_object('prog', jsonb_build_object('model', 'fee_margin'), 'rebate', jsonb_build_object('pct', 2, 'basis', 'media'))),
      jsonb_build_object('ord', 2, 'kind', 'retainer', 'label', 'Account management', 'amount', 1000000, 'hours_included', 20, 'overage_rate', 25000),
      jsonb_build_object('ord', 3, 'kind', 'hourly', 'label', 'SEO', 'rate', 20000, 'hours_per_month', 12.5))))
), 'seller@fx102', null)) ->> 'scope_id')::uuid as id;

create temp table _t as select scope_terms((select id from _s)) as t;
create temp table _lines as
select (x ->> 'title') as title, (x ->> 'text') as text, ord
from _t, jsonb_array_elements(t -> 'sections') with ordinality as o(x, ord);

select set_scope_status((select id from _s), 'proposed', 'seller@fx102');
select approve_scope((select id from _s), 'boss@fx102');
create temp table _frozen as select terms_text from scopes where id = (select id from _s);
update settings set value = jsonb_set(value, '{payment_terms}', '"Pay within {{net_days}} days."') where key = 'scope_terms_templates';
create temp table _t2 as select scope_terms((select id from _s)) as t;

with r(n, result) as (
  select 1, case when fmt_money(5000000) = '$50,000.00' and fmt_money(123456789) = '$1,234,567.89' and fmt_money(-500) = '-$5.00'
                  and fmt_pct(12.5) = '12.5' and fmt_pct(15) = '15' and fmt_pct(12.500) = '12.5' and fmt_pct(0.125) = '0.125'
                  and fmt_hours(12.5) = '12.5' and fmt_hours(20) = '20'
    then '1. FORMAT $50,000.00 · 12.5 · 15 · 12.5h: PASS'
    else '1. FORMAT: FAIL — ' || fmt_money(5000000) || ' ' || fmt_pct(12.5) || ' ' || fmt_pct(15) || ' ' || fmt_hours(12.5) end
  union all
  select 2, case when (select text from _lines where title = 'Q4 campaign — Paid search') =
    'Paid search: management fee on monthly media spend, tiered: 15% on spend from $0.00 to $50,000.00; 12.5% on spend from $50,000.00 to $150,000.00; 10% on spend above $150,000.00. Minimum monthly fee $5,000.00. Media is paid by EMG and re-invoiced to the client at cost. Planned media $140,000.00 over the flight. EMG rebates 2% of the paid search fee to the client, invoiced by the client.'
    then '2. SEARCH sentence exact (band order, min, funding, planned media, fee rebate): PASS'
    else '2. SEARCH: FAIL — ' || coalesce((select text from _lines where title = 'Q4 campaign — Paid search'), 'no section') end
  union all
  select 3, case when (select text from _lines where title = 'Q4 campaign — Programmatic') =
    'Programmatic: programmatic media at a 5% buying fee on media spend; planned media $200,000.00 over the flight. EMG rebates 2% of programmatic media spend to the client, invoiced by the client.'
                  and position('30' in (select text from _lines where title = 'Q4 campaign — Programmatic')) = 0
    then '3. PROG fee printed, backend margin never: PASS'
    else '3. PROG: FAIL — ' || coalesce((select text from _lines where title = 'Q4 campaign — Programmatic'), 'no section') end
  union all
  select 4, case when (select text from _lines where title = 'Q4 campaign — Account management') =
    'Account management: monthly retainer of $10,000.00, including up to 20 hours per month; additional hours at $250.00 per hour.'
                  and (select text from _lines where title = 'Q4 campaign — SEO') = 'SEO: 12.5 hours per month at $200.00 per hour.'
                  and (select text from _lines where title = 'Payment') = 'Invoices are due net 45 days.'
                  and (select text from _lines where title = 'Scope') like 'Scope of work for Acme Travel: Q4 campaign (%'
    then '4. RETAINER, HOURLY, PAYMENT and SCOPE sentences exact: PASS'
    else '4. RETAINER: FAIL — ' || coalesce((select string_agg(title || ' => ' || text, ' | ' order by ord) from _lines), 'none') end
  union all
  select 5, case when (select terms_text from _frozen) = (select t ->> 'text' from _t)
                  and (select t ->> 'text' from _t2) like '%Pay within 45 days.%'
                  and (select terms_text from scopes where id = (select id from _s)) not like '%Pay within%'
    then '5. FREEZE terms_text fixed at approval; a later template change moves scope_terms, not the frozen text: PASS'
    else '5. FREEZE: FAIL — frozen ' || coalesce(left((select terms_text from _frozen), 60), 'null') end
)
select result from r order by n;
rollback;
