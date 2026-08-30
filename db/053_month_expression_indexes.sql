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
--  issued_on is a plain `date`. date_trunc('month', <date>) resolves against
--  date_trunc's timestamptz overload, which Postgres marks STABLE (it reads
--  the session's TimeZone), so it's flatly rejected in an index expression
--  ("functions in index expression must be marked IMMUTABLE") — a date has
--  no time-of-day or zone to begin with, so that overload was never buying
--  anything but blocking the index. Forcing the timestamp (no zone) overload
--  with an explicit ::timestamp cast is IMMUTABLE and, because a date has no
--  zone-dependent instant to shift, produces the exact same calendar month
--  regardless of session TimeZone — 055 rewrites v_cost_lines_classified,
--  forecast_page, and rev_proj_page's own date_trunc calls to match this
--  exact expression so the planner can actually use these indexes; that
--  migration also removes a latent (dormant, never actually observed) bug
--  class where two sessions with different TimeZone settings could have
--  bucketed the same invoice into different months.
--
--  Expression indexes matching the exact cast the query uses, same pattern
--  as pipeline_deals_name_idx's lower(name) index (021).
-- ============================================================================

create index if not exists invoices_month_idx on invoices ((date_trunc('month', issued_on::timestamp)::date));
create index if not exists bills_month_idx    on bills    ((date_trunc('month', issued_on::timestamp)::date));

analyze invoices; analyze bills;
