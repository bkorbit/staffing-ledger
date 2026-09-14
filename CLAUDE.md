# EMG Staffing Ledger — project brief for Claude

Staffing & profitability platform for EMG (media agency, ~60 clients, ~50 staff).
Boris is the owner-operator; direct, ships fast, verifies with real data.

## Architecture (no build step — deploy = push)
- **App**: static ES-module pages in `app/`, served by GitHub Pages at
  https://bkorbit.github.io/staffing-ledger/app/. No bundler. `app/assets/shell.js`
  is the shared shell (auth, nav, helpers); `app/assets/style.css` the tokens.
  supabase-js is VENDORED at `app/assets/vendor/supabase-js.min.mjs` (2.116.0,
  MIT, rebuild recipe in its banner) — the jsdelivr import cost three serial
  round trips before the first query. Every page head preconnects to Supabase
  and to fonts.gstatic.com, `<link>`s Google Fonts directly (the @import inside
  style.css put the fonts a round trip behind the CSS) and modulepreloads every
  module it imports.
- **DB**: Supabase project `zytmlowigbfchfqcilrr` (the ONLY project — an old one,
  bdtzpeazcjgnsxodwzpz, caused repeated wrong-project confusion; it should be/have
  been deleted). Anon key lives in `app/assets/shell.js`.
- **Migrations**: `db/001…025_*.sql`, run manually in the Supabase SQL editor,
  numbered and immutable once shipped — a fix is a NEW migration (see 023→024).
- **Syncs**: `scripts/sync-qbo.mjs` (Invoices+lines, Bills, Purchases,
  JournalEntries, Accounts, Projects — nightly), `scripts/sync-hubspot.mjs`
  (pipeline mirror full-replace, then a RETRY pass calling `promote_approval()`
  for anything still queued; promotions protect history — a hidden/renamed deal
  is never resurrected). Promotion itself happens in the browser at Approve
  time (078), not overnight — the sync is only the safety net.

## Non-negotiable working habits (each one earned by a shipped bug)
1. **Rewrite whole functions; never regex-splice inside one.** Splices twice broke
   production (picker wired inside a handler; render split stranding a local).
2. **Run `node scripts/check-forecast.mjs` before every commit** (syntax + scope
   audit + retired-key audit). Gate the commit on it (`&&`, not newline).
3. **Migrations are fixture-tested before shipping**: the old pg16 sandbox
   (/tmp/pgdata) is gone and this Mac has no Postgres/Docker/brew, so the test
   bed is PGlite (Postgres-in-WASM under node): `npm i @electric-sql/pglite` in
   a scratch dir, create roles authenticated/anon/service_role + a stub `auth`
   schema (uid/role/jwt), load with `extensions:{pgcrypto}`, apply db/NNN_*.sql
   in order (skip *_fixture_test.sql — the whole 001→088 chain loads clean),
   then run the fixture file and print its last result set. Insert a fixture,
   assert exact cents, rollback. Then MUTATE the function and confirm the test
   fails — a test that cannot fail proves nothing (088 did this). Adversarial fixtures (multi-invoice, mid-month
   dates, explicit overrides) — single-row fixtures have missed real bugs.
4. **Client and server math must agree digit-for-digit.** gpMonth/revMonth in
   `app/forecast.html` mirror `v_deal_month_forecast`. Change one → change both →
   run the SAME fixture on both.
5. **Cache stamps**: `node scripts/stamp-assets.mjs` before every deploy commit —
   it rewrites EVERY `?v=` in ALL app/*.html from the current short sha (not just
   shell.js/style.css: a hand-edited sed only ever touched the filenames someone
   remembered, and there are eight assets now). The stamp once froze for a dozen
   deploys — users got stale code and we debugged ghosts. `forecast.html` itself
   is NOT stamped (known gap; GitHub Pages CDN can serve stale HTML — `?fresh=1`
   busts it manually).
6. **Verify pushes**: after push, `git fetch && rev-parse HEAD == origin/main`.
7. **Supabase returns max 1000 rows per request regardless of client limit.**
   Use the wave-parallel pager (fetchAll in shell.js) for anything unbounded.
8. **Parallelize round trips** (the editor opens in ONE Promise.all wave with
   deal_line_months embedded in the deal_lines select).
9. **A page asks for the keys it reads.** `rpcParts(name, args, [keys])` calls
   db/109's `_parts` sibling; adding a payload key without naming it in the
   caller's list means the page reads `undefined` and silently shows zero. The
   key lists live at the call sites in index/client-profitability/project-hours/
   team-hours.html.
10. **Instant repeat loads are shell-owned.** Two identical reads in flight at
   once are coalesced into one request (Home asks for the same forecast payload
   twice — KPI ribbon and chart panel). shell.js hooks the Supabase
   client's `fetch`: an opted-in page (`boot(id, main, { cache: true })`) paints
   from the last visit's answers and re-runs `main` if a background answer
   differs. So `main` must be safe to run TWICE against the same `#content` — a
   window-level listener registered inside it needs a once-guard (project-hours'
   resize). Writes clear every page's cache; write RPCs are never replayed (the
   allowlist is `READ_RPCS`); a page mid-edit refuses the repaint through
   `opts.canRerender` (Scoping: list view, not dirty) and the stale entry is
   dropped rather than left on screen; `scripts/test/shell-cache.test.mjs` pins
   all of it.

## Domain truths (decided with Boris — do not re-litigate silently)
- **Claims attribution**: a QBO project matched to a deal belongs to that deal's
  client; a client's actuals = its deals' claimed projects ∪ its own QBO parent's
  UNCLAIMED remainder. This lets two platform clients split one QBO parent
  (On Location WC vs On Location Events).
- **Measured = month fully over.** The in-progress month runs entirely on
  forecast (chart, company rows). QB partial actuals never masquerade as a month.
  Per-project actuals obey it too since 092: `rev_proj`/`cogs_proj`/`rev_proj_page`
  count months `< current` while `bill_future` counts `>= current`, so a deal's
  Value = billed through last month + planned from this month, never both for
  the in-progress month (Disney Visa Retention showed 150k for a 70k retainer:
  the 1 Sep invoice AND the September plan). `rev_month` still carries the
  current month; the chart reads it only for measured months.
- **Contra revenue** (migration 025): EMG books search/social media pass-through
  against income-type contra accounts. Measured revenue = invoices MINUS
  income-class cost lines, netted per month AND per project. The old "~$20k/mo
  residual = refunds/credit memos" was mostly WRONG: most of that band was
  customer deposits, fixed by 079/080. Verified 8 Sep 2026 on August: gross
  1,177,471.50 − contra 467,865.34 − deposits 156,082.68 = **553,523.48**
  against QuickBooks' Total Income of 554,546.25, a residual of 1,022.77
  (0.18%). THAT is refunds/credit memos (entities NOT synced, by explicit
  decision — rare, ~1%, syncing them would destabilize AR aging and
  payment-behaviour curves). Re-check with
  `scripts/diagnose-august-deposits.sql`, which prints the account-by-account
  verdict and the whole reconciliation in one result set.
- **Rebilled search/social media is not revenue, either way** (087). A
  search/social line set to `media_funding='agency'` (EMG pays the platforms,
  invoices the client back) forecasts its FEE as revenue and carries the media
  as `pass_through`: invoiced and collected as cash, charged to the card as
  cash, netted out of the measured months by the contra accounts above, never a
  sale. It used to sit inside `billable`, so a forecast month claimed revenue
  the closed month then removed. **Programmatic is the deliberate exception** —
  its media bills through as real gross revenue (Boris, explicitly). The client
  twins are `revMonth`/`passMonth` in `app/forecast.html`.
- **Flights carry exact dates** (022; schema month-checks dropped). Covered
  months = date_trunc both ends. **Day-weighting is media-only** (024): the Total
  Budget spread for search/social/programmatic allocates by covered days (over
  the whole flight for search/social, the open months for programmatic);
  retainers/creative-retainer bill FULL months regardless of days; hours spread
  evenly. Explicit per-month overrides are human numbers — never scaled.
- **Freeze-on-close**: closed months get explicit deal_line_months rows at the
  as-opened value on save; forecast accuracy is measured, never rewritten.
  **Except search and social** (Boris, 10 Sep 2026, rolling back "never
  forecast into the past" for these two): their box is the WHOLE campaign
  budget, spread by covered days over every flight month, closed months
  included, and save rewrites every flight month. A campaign is sold as one
  number and that is the number to type. Programmatic, hours and manual flat
  lines still spread over open months and freeze the closed ones
  (`wholeFlightL`/`spanM` in the editor's draw()).
- **line kinds**: retainer, search, social, programmatic, hourly, creative
  (creative's structure in label: 'creative:retainer'|'creative:hourly'),
  legacy 'custom' reads but is not offered.
- **Brand kit** (tokens in style.css): paper #ebebeb, brand #0a493c, #48a278,
  #19a789, accent gold #fabf4d (the NET LINE — most important), logo #3bc9ac.
  Functional red/amber keep their alert meanings. Chart text is black; legend is
  bottom, clickable (localStorage 'fc_hidden'), y-axis rescales to visible.
- Deals hide (deals.hidden), projects hide (qbo_projects.hidden) — human-owned
  flags, sync never writes them, money still rolls up via parent. Unhide via SQL.
- **A platform rename of a deal sticks** (089, `deals.name_locked`, same shape as
  `flight_locked`). The HubSpot sync used to copy pipeline_deals.name back over
  it every run. Now the editor sets the lock, the `deals_name_lock` trigger sets
  it for any rename not stamped `hubspot-…` + fresh set_at (bare SQL renames
  included) and drops a hubspot-stamped rename of a locked row, and the sync
  skips locked rows. Every page reads `deals.name`, so the new name shows
  everywhere. Hand a name back to HubSpot: `set name_locked = false`.
- Fixed costs: edited on Settings, subtracted from projected net only.
- **'Other' is never forecast** (093, Boris 10 Sep 2026). The class (accounts
  with no recognisable type) holds one-off / incremental lines; measured months
  show what was booked, forward months carry 0. forecast_page has no
  runrates.other any more; both charts' rowFor (forecast.html, index.html) agree.
- **EBITDA switch on the NET line** (093). The Forecast chart's legend bar has a
  Net / EBITDA toggle (localStorage 'fc_netmode'; the KPI headline follows it).
  EBITDA month = net + add-back: cost lines on accounts `account_ebitda_addback()`
  says yes to — QuickBooks type Other Expense / Other Income (below the operating
  line), or a depreciation / amortization / interest / income-tax subtype or name
  (`\m…\M` word boundaries: Pinterest is not interest) — overhead and other
  classes ONLY, never labour or COGS by rule. `qbo_accounts.ebitda_addback`
  (null/true/false) overrides it, edited in "How costs are counted", human-owned,
  the sync never writes it. Forward months add back the flagged share of the
  overhead run-rate (`addback_trail`), nothing else — labour comes from Team,
  COGS from the plan, other is not forecast. Interest EARNED is negative in the
  view and so lowers EBITDA. Not on the Home chart (net only).
- **Solidigm is one deal, by exception** (Boris, 10 Sep 2026). QB project 426
  (24forc3009250) belongs to "FMS - Solidigm - Programmatic - 8/27/25 - 9/30/25"
  — hours AND invoices; "FMS - Solidigm - Programmatic - Incremental" claims no
  project. Two deals on one QB project make sync-qbtime.mjs stamp every hour
  on ONE of them (its lookup is a Map keyed by qbo_project_id, last row wins);
  Boris chose to fix the claim, not to add per-date routing. Applied by
  `scripts/fix-solidigm-regular-deal.sql`; `scripts/diagnose-deal-missing-hours.sql`
  finds the same shape for any other deal.
- Forecast axis: bounds snap to $250k, gridlines every $500k ($1M if >13 lines).

## Current migration head: 112. Key views/functions
The number in brackets is the migration holding the CURRENT definition — a fix
is always a new migration, so grep for the highest one before reading an old body.

- **109 is a speed-only migration**: every function it touches is asserted
  byte-identical to the definition it replaced (109_fixture_test, plus all 27
  older fixtures re-run unchanged). It added three primitives and one split:
  `staff_day_rates(from, to, deal_ids)` — staff_hourly_cost per person-DAY, ONE
  burden-stack call per (person, comp period, 401k, health-insurance) cohort,
  which is exact because those three are the only things the breakdown reads the
  date for; read by hours_page, project_detail and client_detail, so a deal's
  labor is the same number on every page by construction.
  `staff_cost_on_dates(dates[])` / `staff_base_labor_forecast_dates(dates[])` —
  the same cohort trick per as-of DATE (a date array, not a month range:
  labor_forecast_breakdown's series starts on today, not the 1st), replacing the
  per-month calls in forecast_page / labor_forecast_breakdown / cashflow_forecast
  (which was calling it per HALF-month). `line_fee` split into an inlinable
  expression plus `line_fee_bands`: a SQL function whose body has a WITH clause
  is NEVER inlined, so every row of v_deal_month_forecast paid ~38us — keep
  line_fee free of WITH, FROM and subqueries or the whole app slows down again.
  And `forecast_page_parts` / `hours_page_parts` (p_parts text[]): null is the
  whole payload, a list builds only those keys AND skips their work, since an
  un-taken CASE branch never evaluates its subquery. The two-argument
  forecast_page / hours_page stay as one-line wrappers — 076_fixture_test
  recreates that exact signature, and a defaulted third argument on the same
  name would make forecast_page(a, b) ambiguous.
- **111 made the Scoping editor interactive again.** `scope_verdict_calc` reads
  exactly one thing out of the staffing payload it is handed — `hire` — and the
  candidate ranking (a 12-month time_entries scan per call) is for the editor's
  staffing panel only. So scope_staffing splits: `scope_gap_hire` is everything
  but the ranking, `scope_staffing` is that plus the ranking, and
  `scope_verdict_light` (gap_hire only) is byte-identical to `scope_verdict` —
  111_fixture_test asserts it scope by scope, and the mutation that makes the
  verdict read `candidates` fails it. Sibling scenarios' KPI strips use the
  light one: a three-scenario family was paying three full rankings per open AND
  per keystroke burst (427 ms in the bed). `scope_core` is the six keys the
  editor actually merges from a preview (econ, labor, staffing, verdict,
  existing_deals, prog_margin — see runPreview in app/scoping.html); scope_page
  is scope_state + scope_core + context, and `preview_scope` returns
  scope_state + scope_core instead of the whole page (436 → 124 ms). Keep
  scope_verdict_calc away from any staffing key but `hire`, or the light path
  silently stops being identical. `scoping_list` also filters the pipeline
  mirror server-side now (the page's own filter, reproduced in SQL — 437 → 176 KB);
  the page keeps its filter, so it works either way.
- **112 opened the Benchmarks to more platforms and showed the hours** (Boris,
  14 Sep 2026: "match the logged hours to the campaign data from the platform,
  not add stuff manually"). `benchmark_uploads.platform` is a shape check
  (`^[a-z0-9_]{2,40}$`), not a list — the registry is `PLATFORMS` in
  `app/assets/parsers/index.js` (google_ads, meta, reddit, linkedin, dsp,
  viant, cm360; `files`, `group` = the team that usually runs it, `parser` =
  the family a platform shares — Viant reads through the DSP parser) plus
  Settings › Scoping's team defaults (112 added viant → Programmatic, reddit /
  linkedin → Paid Media, cm360 → AdOps, existing keys untouched). New parsers
  `social.js` (Reddit: campaign → ad group → ad; LinkedIn: campaign GROUP →
  campaign → creative, mapped to active_campaigns / ad_sets / ads_live) and
  `cm360.js` (Adswerve trafficking: `placements` is the AdOps driver, also
  `sites`); matchers are exclusive (Placement = CM360, Campaign group / Total
  spent = LinkedIn, Ad group name + Campaign name = Reddit, Ad set name = Meta)
  and `PARSERS` order puts the exclusive shapes first for un-hinted files —
  `scripts/test/scope-parsers.test.mjs` pins every one. The column aliases are
  the platforms' documented headers, NOT yet checked against a real export:
  the first real Reddit / LinkedIn / Viant / CM360 file Boris sends pins them.
  The typed-signal section (meetings / reports / creatives) is gone from the
  bench view; old uploads of those platforms still read. `benchmark_deal_hours
  (deal)` = one deal's counted hours per department per month (090/091 rule,
  v_benchmark_observed's department rule — 112_fixture_test asserts the two
  agree), `closed` flags the running month; the bench view shows it under the
  uploads as "Hours logged on this campaign" so the reader sees what the
  exports are matched to. Hours and headcount only, never a cost.
- **110 moved two roll-ups off the browser**: `hours_page_parts` gained
  `deal_week_hours` (hours per ISO week per deal — Home was fetching every
  time_entries row in its range, ~14k over six months in fourteen paged
  requests, to bucket them in JS; `date_trunc('week')` is Monday-based exactly
  as Home's `weekStart()` is). It reproduces Home's query EXACTLY, which means
  it does NOT apply 090's attribution filter — that chart counts excluded hours
  every other number on the page leaves out, flagged for Boris, not changed.
  And `v_deal_month_gp` = v_deal_month_forecast summed per month, for Home's and
  Sales Forecast's committed-GP line (they were paging the whole ledger to make
  two dozen numbers). Both pages keep their own accumulation, so the JS shape
  did not change.
- `v_deal_month_forecast` [100] — the commercial plan as money. Day-weighted
  media spread from 024; 058 stopped hidden deals leaking into the plan; 087
  split `pass_through` (rebilled search/social media: cash, never revenue) out
  of `billable`. 100: search/social/programmatic fees go through
  `line_fee(budget, fee_pct, deal_lines.structure)` — `{}` is flat and
  byte-identical to 087 (100_fixture_test proves it against 087's body) —
  and `fee`, `rebate` are APPENDED (rebate = `deal_lines.rebate_pct` of media
  or fee: COGS, never billable; `gp` stays PRE-rebate, `rebate` is the last
  column now — 087_fixture_test row 7 pins that). Revenue wants `billable`;
  cash wants `billable + pass_through`; profit wants `gp − rebate`. JS twins:
  forecast.html gpMonth/revMonth/rebateMonth via scope-math.js `lineFee`,
  forward COGS = billable − gp + rebate in forecast.html and index.html rowFor,
  client-profitability blend subtracts `plan_deal.rebate_future`.
- `v_cost_lines_classified` [093] — bill/purchase/journal lines with cost_class
  (cogs/payroll/overhead/other/income/excluded); overrides via
  qbo_accounts.override_class. 056 fixed Other Income and labor sub-accounts
  against the real QB P&L; 093 appended account_type, account_sub_type and
  ebitda_addback per line (nothing before them moved).
- `account_ebitda_addback(type, sub_type, name, class, override)` /
  `v_account_class` [093] — the EBITDA add-back rule, ONE copy, and the
  chart-of-accounts view that carries its answer (`ebitda_addback_auto`,
  `ebitda_addback_effective`) so the Forecast page's accounts panel never
  re-implements it in JS.
- `forecast_page(p_from,p_to)` / `forecast_page_parts(p_from,p_to,p_parts)` [109/100] — whole Forecast page in one jsonb.
  100 added `plan_month.rebate`, `plan_deal.rebate_all/rebate_future` (093's
  body otherwise verbatim); `project_detail`/`client_detail` [100] gained
  `rebate_plan` per month the same way.
  025 added contra revenue; 068-071 wired in bottoms-up labor; 076 made it scan
  v_cost_lines_classified ONCE instead of ~15-20 times (it was the page's load
  cost, not a behaviour change — 076_fixture_test.sql proves byte-identical output);
  079/080 stopped balance-sheet invoice lines (customer deposits) counting as
  revenue, which needs a full QBO re-sync to stamp invoice_lines.account_id.
  092 made rev_proj/cogs_proj closed-months-only (the current month was in both
  the actual and the forecast half of the table's Value column). 093 dropped
  runrates.other and added addback_month + runrates.addback for the EBITDA
  line; 093_fixture_test proves everything else byte-identical to 092.
- `cashflow_forecast(...)` [109/087] — half-month periods (016), programmatic COGS
  terms knob (017), EB-shrunk per-client payment curves, overdue clamps, the
  same real labor numbers the Forecast uses (071), an opening position from
  `v_cash_accounts` [086] rather than QuickBooks' Bank type, and since 087 a
  contracted inflow of `billable + pass_through` plus a programmatic-only
  `out_contracted_cogs` (its `billable > gp` filter had been subtracting
  agency-funded search/social media from cash a second time).
- `labor_page` / `labor_forecast_breakdown` [109/077] / `staff_burdened_cost_breakdown` [077]
  — the Labor page, sourced entirely from Team setup, deliberately NOT tied to
  logged or planned hours.
- `staff_annual_burdened_cost` / `staff_annual_labor_cost` [077], `staff_hourly_cost`
  [041], `v_staff_total_cost` [073] — the burden stack: FICA/FUTA (040), 401k +
  health (041, grandfathered 044), workers' comp by state (042/045), SUTA (046),
  SDI (048), PEO admin fee (050, excluded from the hourly rate by 052).
- `staff_base_labor_forecast_month` [075], `health_insurance_forecast_month` [072],
  `payroll_loose_runrate` [074], `labor_addendum_runrate` [070],
  `staff_bonus_burdened_cost` [070] — the forward labor cost pieces.
- **QuickBooks Time → ledger is lossless** (090, `scripts/sync-qbtime.mjs`): every
  timesheet hour lands in `time_entries` with `qbtime_jobcode_id`, `jobcode_name`
  and `attribution` (deal|mapped|internal|uncoded|unmatched|unresolved|excluded|
  unknown_user|timeoff — 090 header). `qbtime_jobcode_map` is the human-owned
  answer per QBT jobcode id (deal|internal|timeoff|exclude), read FIRST by the
  sync, never written by it; `staff.exclude_hours` replaced the hardcoded
  exclusion list. `unmapped_hours(p_from,p_to)` [090] feeds Project Hours'
  "Unmapped hours" panel, where a human resolves each group (writes the map,
  relabels existing rows). hours_page/project_detail/client_detail skip
  'excluded' and 'timeoff' rows. The sync detects an unapplied 090 and runs in
  its pre-090 shape; it upserts then sweeps stale rows, so there is no blank
  window mid-run. `workflow_dispatch` input `trace` follows one client end to
  end in the log.
- `hours_page` [110/109/108], `rev_proj_page` [092], `accounts_page` [084],
  `v_cash_accounts` [086]. 108 APPENDED to hours_page (090's body verbatim,
  108_fixture_test + the bed's identity check prove the old keys unchanged):
  `measured_before` (the server's current month), `staff_hours_deal_month`,
  `staff_deal_planned_month`, `deal_forecast` (v_deal_month_forecast
  billable/gp, months ≥ current), `staff_rate_month` (staff_rates_months,
  months ≥ current).
- **Team Hours profit runs on forecast from the current month on** (108,
  Boris 13 Sep 2026): closed months split measured revenue (rev_proj_page)
  over the hours logged on each deal in them; the current month and later
  split the deal's FORECAST revenue over each person's hours BASIS per month
  — assigned hours while logged is under the assignment, logged hours once
  over — and cost the unworked remainder of the assignment at
  staff_hourly_cost(person, month). Bases sum to the deal's denominator, so
  attributed revenue adds up to the forecast exactly. ONE copy:
  `profitModel` in `app/team-hours.html` (unit test lives in the scratchpad
  bed, numbers = 108_fixture_test's); a pre-108 payload falls back to the old
  whole-range rule.
- `project_detail(deal_id)` [109/094] — one opened project on Project Hours: hours
  per ISO week per department (staff.department first, the entry's own QB Time
  department as fallback) and revenue/GP actual vs plan per month. The actual
  side restates forecast_page's rev_proj/cogs_proj per month for ONE project —
  same CTEs, same 080 fail-open rules — and 088_fixture_test asserts they agree
  to the cent. Per-person hours are NOT here; hours_page's staff_hours_deal /
  staff_deal_planned already carry them.
- `client_detail(client_id)` [109/094] — project_detail unioned across a client's
  deals for Client Profitability's open-client charts: hours per week per
  department over all deals; revenue/GP actual per DISTINCT claimed QB project
  (two deals on one project count it once), plan per deal. The unclaimed
  remainder is excluded, matching the page's client total. Both pages draw
  the charts from `app/assets/detail-charts.js` — one copy, imported with the
  same `?v=` stamp; it must NOT import shell.js (a second module instance
  would create a second Supabase client).
  090: every month before the current one is MEASURED in both RPCs (0 when
  nothing happened; null only for months not yet closed — a null was read as
  "not measured" and broke the chart's line across an empty month), and
  client_detail adds `weeks_by_deal` + `deals` so the client chart stacks by
  project (Boris's call) while Project Hours stacks its one project by
  department.
  091: both count exactly the time entries hours_page counts — `attribution`
  not in ('excluded','timeoff') (090_qbtime_hours_provenance, a PARALLEL
  session's migration that shares the number 090 with
  090_detail_zero_months_and_weeks_by_deal; both load, filenames differ).
  094: every month row also carries `labor_actual` (the counted hours priced
  exactly as hours_page's deal_labor — staff_hourly_cost per distinct
  staff/day, MATERIALIZED) and `pal_actual` = gp − labor, both null until the
  month closes; a month with hours and no money gets a row. The shared
  `revGpChart` draws pal_actual as the GOLD line (measured only — assignments
  carry no cost, so no plan twin) and skips it on a pre-094 payload;
  `revStat` adds "after labor". 094_fixture_test asserts the cents against
  staff_hourly_cost and against hours_page's deal_labor for the same deal.
  Two sessions worked this tree on 8 Sep 2026: `git add -A` swept the other
  session's untracked 090 into commit 1a1005f — stage explicit paths when
  another session may be active.
- **Hour Planning** (095, `app/hour-planning.html`) — the ONLY writer of
  `assignments` (staff × deal × month planned hours; hours_page has read it
  since 034). `assignments_page(p_from,p_to)` is its one payload, hours only —
  never a cost or rate. `staff_capacity(p_from,p_to)` = weekly_capacity/5 ×
  business days employed × `scope_target_utilization_pct` (Team Hours' rule,
  clipped to start/end dates); `app/assets/capacity.js` is the one copy of the
  red/amber classification, shared with Scoping (must not import shell.js).
  `seed_assignments(lookback, by)` writes a day-one baseline from
  `assignments_seed_basis` (counted hours over the trailing N whole months ÷ N,
  live unhidden deals still flighting, active non-excluded staff), rows stamped
  `set_by 'seed:trailing-actuals'`; a rerun replaces the seed layer and NEVER
  touches a human row; `clear_seed_assignments()` deletes only seed rows.
  Controls live on Settings › Scoping. A cell set to 0 deletes its row.
  Scoping (096+) writes approved scopes' named hours here too (`deal_id` null,
  `scope_id` set, `set_by 'scope:approve'`; promotion relinks `deal_id`).
- **Scoping** (096/097, `app/scoping.html`) — is a deal viable before it exists.
  Tables: `scopes` (family_id = scenarios, status draft→proposed→approved→
  promoted, version = snapshot count), `scope_deals` (several future deals per
  scope; origin hubspot|deal|new; promote_mode hubspot|new|extend), `scope_lines`
  (+ `structure` jsonb: fee bands marginal|whole with min/cap, rebate {pct,
  basis media|fee}, prog {model fee_margin|cpm}), `scope_line_months`,
  `scope_dept_months` (DEMAND per department), `scope_staff_months` (SUPPLY:
  named or placeholder = department × comp band; source manual|auto),
  `scope_versions` (append-only). Primitives, ONE copy each, twinned in
  `app/assets/scope-math.js` (tested by `scripts/test/scope-math.test.mjs` on
  097_fixture_test's numbers): `line_fee` (UNROUNDED; flat = budget×pct/100 so
  the 099 view stays byte-identical; bands on EACH MONTH's spend, boundary
  inclusive; min then cap), `line_rebate`, `prog_suggest_margin` = target×(100+
  fee)/100 − fee (GP measured on revenue). CPM = margin_pct 100 − platform
  share, fee 0. `scope_months` = the scope twin of v_deal_month_forecast (+ fee,
  rebate; gp is PRE-rebate). `scope_labor` returns TOTALS ONLY — named ×
  staff_hourly_cost, placeholders × `band_rate`, uncovered demand × department
  average; no per-person or per-department cost ever leaves SQL (Boris: salary
  privacy). `scope_staffing` ranks candidates client history → kind history →
  free hours → cost (rank only) and computes the hire/contractor option
  (`scope_hire_costs` per department, `hire_hourly_cost` = loaded annual ÷ 2080);
  `auto_staff_scope` fills gaps fewest-people-first. `scope_verdict`: pal = gp −
  rebate − labor, per-hour vs `scope_target_profit_per_hour`, capacity, client
  roll-up (client_detail measured + v_deal_month_forecast/assignments planned),
  status go|go_with_hire|go_with_contractor|no_go|unclear. `scope_page` = one
  round trip. `save_scope` (atomic, refuses approved/promoted), `create_scope`
  (hubspot via hs_flight_lines | deal | new | client | scenario), approve/
  unapprove (approvers from `scope_approver_emails`, enforced by the
  `scopes_status_guard` trigger too), `quick_check`. Promotion = 100 (pending).
- **Product catalog** (098): `products` (name, kind, role budget|fee|flat|amount,
  department, `setup_hours` / `monthly_hours` jsonb by department) +
  `product_aliases` (source hubspot|qbo, external_name, product_id, `excluded`).
  `hs_line_item_map` reads the hubspot aliases (STABLE now; both sides lose the
  folder prefix); `hs_flight_lines` [098] drops EXCLUDED items silently, an
  UNMAPPED one still blocks (078). Edited on Settings › Scoping; the unmatched
  HubSpot names seen in the mirror are listed there as the to-do.
- **Benchmarks** (099, bench mode in `app/scoping.html#bench`): enrol a live deal
  (`benchmark_deals`), assign platforms to TEAMS, upload exports parsed in the
  browser (`app/assets/parsers/*` — Google Ads daily + change history, Meta
  daily + activity, DSP; spend in CENTS) into `benchmark_uploads` +
  `benchmark_upload_months` (re-upload of the same deal+platform+team replaces).
  `v_benchmark_observed` = drivers per (deal, department, closed month) + the
  department's counted hours (090/091 rule) + deal_kinds + client. Never store
  hours; never count the running month. `benchmark_coefficients(kind, dept,
  client)` = per driver Σhours/Σdriver (8 dp — spend is cents) + regression
  stats, CLIENT-SPECIFIC when the client has ≥ 2 rows. `benchmark_models` =
  NNLS fit (`fitModel` in scope-math.js, ≥ `scope_model_min_observations`
  rows) saved via `save_benchmark_model`; `estimate_dept_hours` prefers it,
  else the MEDIAN of the single-driver estimates. `scope_estimate_hours` fills
  `scope_dept_months` (source benchmark|catalog, manual rows never touched) from
  each media line month's `drivers` (spend auto-added from the budget cell at
  save) + catalog products on lines (`structure.products`). `quick_check` [099]
  estimates from spend when no hours are typed. Tests:
  `scripts/test/scope-parsers.test.mjs`.
- `snapshot_forecast`, `v_forecast_accuracy`, `v_invoice_settlement_calibration`
  [067] — measuring the model against itself.
- `promote_approval(hubspot_deal_id)` [101] — the promotion door: deal +
  promotion + flighted lines in ONE transaction, called by Sales Forecast's
  Approve button (the normal path), by `promote_scope`, and by sync-hubspot.mjs
  as a retry for anything still queued. All go through the single once-only
  check inside it, under an advisory lock, so a deal can never promote twice.
  101: when an APPROVED scope deal exists for the HubSpot id, the deal takes
  the SCOPE's flight dates (`flight_locked`) and lines (structure + rebate)
  instead of `hs_flight_lines`, the scope deal is marked promoted and its
  reserved hours relink; result carries `scope_id`. Its helpers
  `hs_flight_lines` [098] / `hs_line_item_map` [098] are the ONLY copy of the
  line-item flighting math — the JS twin in sync-hubspot.mjs was deleted, not
  left to drift.
- `promote_scope(scope_id, by, projects)` [101] — approvers only, scope
  approved, ALL OR NOTHING over the scope's deals: `hubspot` → upsert
  `promotion_approvals` then `promote_approval` (lock order promote_scope →
  promote_approval); `new` → manual won deal, flight_locked, scope_id; `extend`
  → source deal grows to the scope's dates, its existing lines get explicit
  ZERO month rows from this month on (closed months untouched), the scope's
  lines are added from this month with their closed months pinned at 0. Then
  `relink_scope_assignments` (scope reservations → first promoted deal,
  merging duplicates) and `finish_scope_promotion` (status promoted + version).
  `p_projects` = {scope_deal_id: qbo_project_id}. 101_fixture_test row 1 is the
  handoff identity: every `v_deal_month_forecast` row of the new deal equals
  `scope_months`.
- `scope_terms(scope_id)` [102] — the commercial terms as plain sentences from
  `scope_terms_templates` ({{placeholders}}, edited on Settings › Scoping):
  fee schedule per line (flat / marginal / whole bands, min, cap, funding,
  planned media), rebates, retainers with included hours + overage, hourly,
  payment terms, notes. The programmatic BACKEND MARGIN is never printed.
  `approve_scope` [102] freezes the text into `scopes.terms_text`. Helpers
  `render_template`, `fmt_money` ($50,000.00), `fmt_pct` (12.5 not 12.500).
- **Scoping speed + delete** (106). Every scoping action is one round trip and,
  in the PGlite bed on a 55-person roster, under 100 ms (scope_page 1228 → 58 ms).
  `staff_rate_cache` memoises `staff_hourly_cost(person, month 1st)`:
  `staff_rate_cache_fill(f0, f1)` is VOLATILE and lives in the volatile entry
  points (`scope_page`, `approvals_queue`, `quick_check`, `scope_act`) because
  PostgREST runs STABLE functions read-only; `staff_rates_months` /
  `cached_hourly_cost` read it and fall back live, so a cold memo is only slow,
  never wrong; triggers on comp_periods / staff (that person), burden settings
  keys / workers_comp_rates / suta_rates (everything) empty it. `scope_page`
  computes scope_months / scope_labor / scope_staffing ONCE and hands them to
  `scope_verdict_calc(id, econ, labor, staffing)` (`scope_verdict(id)` wraps it);
  the hire re-pricing takes department averages from one rates pass, not a call
  per department-month. `client_detail` / `project_detail` are consulted only
  when the window reaches a CLOSED month (guarded with CASE — a WHERE on a
  "constant" was not short-circuited inside the function) — so a re-scope of a
  live deal whose flight already started is the one path still paying for the
  history roll-up (~0.9 s in the bed; the fix would be a day-level rate memo
  inside 094's detail RPCs). `scope_act(action, id, by, args)` runs create /
  save / propose / draft / approve / unapprove / auto_staff / estimate /
  promote / delete and returns `page` = the fresh scope_page; `scoping_list()`
  replaced the list view's eight requests. `delete_scope(id, by)`: draft /
  proposed by anyone, approved by an approver (reserved assignments go too),
  promoted never (deals.scope_id points back). The page passes a created
  scope's page across the hashchange (`PRE`) so create / new scenario open
  without a second trip. Timing bench: scratchpad `pgbed/bench.mjs`.
- **Live verdict while editing** (107, Boris: "I want it to be interactive").
  Money follows every keystroke from the twin math (`drawVerdict` redraws the
  Monthly verdict chart + pills from `lineMonth` per month, labor from the last
  server payload). Labor / staffing / verdict need SQL, so `markDirty` debounces
  650 ms and calls `preview_scope(payload, by)`: save_scope + scope_page inside
  a sub-transaction that a sentinel exception (`PREVIEW_ROLLBACK`, page in its
  DETAIL) rolls back — nothing written, no version; the memo is warmed before
  the sub-block. The reply repaints the editor with `rerenderKeepingFocus`
  (focused field + caret + scroll restored; a stale reply is dropped when the
  user typed again). Save still writes the version. Never make the preview
  autosave — Boris chose a version per deliberate Save.
  Hours cells (demand, people, placeholders) update the state and their row
  total IN PLACE on `input` — never re-render while a field is focused (it
  dropped the cursor and half-typed digits); a preview that lands mid-typing
  repaints only the ribbon (`stripCells`) and the Monthly verdict
  (`verdictPanelInner`), the grids catch up on focusout (`pendingRender`).
  The demand grid's first column is "every month" (`data-dmall`) — one number
  fills the row. The ribbon carries Profit per hour vs target; the client
  roll-up table is gone from the UI (Boris: no insight) — `client_ok` still
  gates the verdict and shows in the verdict notes.
- **Deal-level terms** (103, Boris after the first walk-through): the REBATE is
  a deal term (`scopes.rebate_pct/rebate_basis`, media → media lines only, fee →
  every line; a line's own `structure.rebate` still wins but the UI no longer
  offers it) — `scope_months` [103] and `promote_scope_lines` [103] resolve it
  identically so the handoff identity holds. The MINIMUM fee is COMPUTED, never
  typed: `scope_verdict` [103] months carry `fee` and `min_fee` = labor ÷ (1 −
  preset margin) (`scope_min_margin_presets`: Break even 0 / Slight margin 15 /
  Target 35, `scopes.min_margin_preset`), totals carry `min_fee_max` and
  `fee_shortfall`; informative, not a gate; `scope_terms` [103] prints the
  highest month as the minimum monthly fee and one scope-level rebate sentence.
  `set_scope_status` [103] stamps `proposed_by/at`; `approvals_queue()` feeds
  the Approvals tab; `scope_existing_deals(scope_id)` = the client's live deals
  overlapping the scope's months (GP/labor measured + planned, hours, PAL) for
  the editor's "already running" panel. Page: Quick check and Approvals are
  tabs, the HubSpot tab is "Pipeline" with Sales Forecast's population minus
  deals already scoped, the verdict is pinned at the top, one gutter system.
- **Programmatic backend margin is a deal OUTPUT** (104): `scope_prog_margin(scope_id)`
  = the one margin across the scope's fee+margin programmatic lines (CPM lines
  and lines with an explicit `margin_pct` excluded), budget-weighted over the
  flight, that lands `scope_prog_target_gp_pct` on revenue — for one line equals
  `prog_suggest_margin`. `scope_months` [104] uses it as the fallback for a null
  `margin_pct`; `promote_scope_lines` [104] writes it onto the promoted lines.
  JS twin `progDealMargin` (scope-math.js); the card no longer has a margin box,
  Deal terms shows the output. Settings `scope_kind_departments` /
  `scope_always_departments` fill the hours grid as lines are added. The
  Pipeline tab honours `sales_probability_threshold` like Sales Forecast.
- **Rates once per person-month** (105, after a statement timeout on the first
  real load): `staff_rates_months(p_from,p_to)` = every plannable person ×
  month with `staff_hourly_cost` and comp band, ONE burden-stack call each,
  MATERIALIZED where used. `scope_labor` [105] prices named / band / department
  / company from it (band_rate's ladder, same cents — 097/103/104 fixtures
  re-run); `scope_staffing` [105] ranks from one pass over 12 months of hours;
  `scope_verdict` [105] re-prices hires via `dept_avg_rate`; `scope_page` and
  `approvals_queue` compute each verdict once. Never call `band_rate` /
  `staff_hourly_cost` inside a per-row expression on the scoping side.
- `match_deals_to_projects()` [010/037] — residual deal↔QBO-project fill-gaps
  pass; never guesses, never clobbers a human's match.

## Open threads (ask Boris before assuming)
- Reopened SB/NCAA 2026 deals need real exact flight dates + picker matching.
- $10–32k/mo contra rides on unsynced entity types (Deposit/CreditMemo/
  VendorCredit — awaiting his QB Transaction-Detail-by-Account check). Decision
  so far: DO NOT sync refunds/credit memos.
- April 2026 has a −$795k below-the-line one-off ("Non Operating Loss" account,
  classified overhead → already in our chart). override_class to 'excluded' if
  Boris wants it out of the operating trend.
- **A browser smoke test of every page is still open** — 095-110 have been
  proved in the PGlite bed and by unit tests, never in a real browser against
  prod. 109, 110 and 111 must be applied in the SQL editor; until 109 is, the pages
  make one failing `_parts` call each and fall back to the whole payload, and
  until 110 is, Home falls back to fetching raw time entries for its weekly
  chart (that fallback can be deleted once it is applied).
- **Home's weekly-by-project chart counts hours nothing else counts** (110's
  `deal_week_hours` preserves it): excluded people and excluded jobcodes with a
  deal_id. Ask Boris whether to apply 090's attribution filter there.
- Nightly schedule for sync-hubspot.yml; QB Time sync rewrite; People /
  Departments pages are placeholders. **Scoping tool in progress** (plan in
  `~/.claude/plans/i-want-to-start-iridescent-sonnet.md`, 13 Sep 2026): Phase 1
  Hour Planning shipped (095); Phase 2 scope tables + editor + verdict shipped
  (096/097); Phase 3 product catalog + benchmarks shipped (098/099); Phase 4a
  forecast handoff shipped (100); Phase 4b promotion door shipped (101); Phase
  5 terms shipped (102). Still open: the cashflow leg of a rebate
  (`cashflow_forecast` has no `out_rebate` yet — a rebate leaves cash when the
  client invoices EMG; decide the timing knob with Boris before adding it),
  and a browser smoke test of every page once 095–102 are applied in prod. Decisions locked with Boris there — labor
  cost is ONE rolled-up number (salary privacy), rebate is COGS not billable,
  fee bands are monthly, Paid Media pools search + social, scope dates win at
  promotion, excluded catalog items skip silently.
- Scoping's remaining cost is `scope_page` on a family with several scenarios
  (316 ms in the bed for three, down from 575): each sibling still computes its
  own econ + labor + gap_hire for the KPI strip. Memoising a verdict per
  (scope_id, version) would finish it, at the usual staleness risk — not taken.
- Cashflow refinements deferred: retire COGS run-rate at high shaped coverage;
  invoiced deal-months exiting the contracted tier.
- SECURITY: a GitHub PAT was embedded in the old sandbox's git remote — must be
  revoked now that local git auth exists. Old Supabase project deletion.

## Where the deep history lives
The platform was built across long Claude.ai sessions; design rationale beyond
this file is in those transcripts. When something here seems arbitrary, it
almost certainly is not — ask Boris rather than reverting it.
