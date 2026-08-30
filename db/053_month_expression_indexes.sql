-- ============================================================================
--  053 — expression indexes for the date_trunc('month', ...) filters
--  rev_proj_page/forecast_page actually run.
--
--  021 indexed invoices/bills on the raw issued_on column, but rev_proj_page
--  (051) and forecast_page's own inv/cost CTEs (025) filter on
--  date_trunc('month', issued_on)::date between p_from and p_to — a plain
--  btree on issued_on cannot satisfy a predicate wrapped in date_trunc(), so
--  every Team Hours load and every quick-range click was still forcing a
--  full scan of invoices, and of bills through v_cost_lines_classified's
--  bill_lines join (006), with date_trunc evaluated per row before the range
--  filter could prune anything. This is very likely the multi-second load —
--  everything hours_page() touches (time_entries, assignments, comp_periods)
--  was already properly indexed from 001/021.
--
--  Expression indexes matching the exact cast the query uses, same pattern
--  as pipeline_deals_name_idx's lower(name) index (021).
-- ============================================================================

create index if not exists invoices_month_idx on invoices (date_trunc('month', issued_on)::date);
create index if not exists bills_month_idx    on bills    (date_trunc('month', issued_on)::date);

analyze invoices; analyze bills;
