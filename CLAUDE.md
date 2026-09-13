# EMG Staffing Ledger — project brief for Claude

Staffing & profitability platform for EMG (media agency, ~60 clients, ~50 staff).
Boris is the owner-operator; direct, ships fast, verifies with real data.

## Architecture (no build step — deploy = push)
- **App**: static ES-module pages in `app/`, served by GitHub Pages at
  https://bkorbit.github.io/staffing-ledger/app/. No bundler. `app/assets/shell.js`
  is the shared shell (auth, nav, helpers); `app/assets/style.css` the tokens.
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
5. **Cache stamps**: every deploy re-stamps `?v=<short-sha>` on shell.js/style.css
   in ALL app/*.html. The stamp once froze for a dozen deploys — users got stale
   code and we debugged ghosts. `forecast.html` itself is NOT stamped (known gap;
   GitHub Pages CDN can serve stale HTML — `?fresh=1` busts it manually).
6. **Verify pushes**: after push, `git fetch && rev-parse HEAD == origin/main`.
7. **Supabase returns max 1000 rows per request regardless of client limit.**
   Use the wave-parallel pager (fetchAll in shell.js) for anything unbounded.
8. **Parallelize round trips** (the editor opens in ONE Promise.all wave with
   deal_line_months embedded in the deal_lines select).

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

## Current migration head: 101. Key views/functions
The number in brackets is the migration holding the CURRENT definition — a fix
is always a new migration, so grep for the highest one before reading an old body.

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
- `forecast_page(p_from,p_to)` [100] — whole Forecast page in one jsonb.
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
- `cashflow_forecast(...)` [087] — half-month periods (016), programmatic COGS
  terms knob (017), EB-shrunk per-client payment curves, overdue clamps, the
  same real labor numbers the Forecast uses (071), an opening position from
  `v_cash_accounts` [086] rather than QuickBooks' Bank type, and since 087 a
  contracted inflow of `billable + pass_through` plus a programmatic-only
  `out_contracted_cogs` (its `billable > gp` filter had been subtracting
  agency-funded search/social media from cash a second time).
- `labor_page` / `labor_forecast_breakdown` / `staff_burdened_cost_breakdown` [077]
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
- `hours_page` [090], `rev_proj_page` [092], `accounts_page` [084],
  `v_cash_accounts` [086].
- `project_detail(deal_id)` [094] — one opened project on Project Hours: hours
  per ISO week per department (staff.department first, the entry's own QB Time
  department as fallback) and revenue/GP actual vs plan per month. The actual
  side restates forecast_page's rev_proj/cogs_proj per month for ONE project —
  same CTEs, same 080 fail-open rules — and 088_fixture_test asserts they agree
  to the cent. Per-person hours are NOT here; hours_page's staff_hours_deal /
  staff_deal_planned already carry them.
- `client_detail(client_id)` [094] — project_detail unioned across a client's
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
- Nightly schedule for sync-hubspot.yml; QB Time sync rewrite; People /
  Departments pages are placeholders. **Scoping tool in progress** (plan in
  `~/.claude/plans/i-want-to-start-iridescent-sonnet.md`, 13 Sep 2026): Phase 1
  Hour Planning shipped (095); Phase 2 scope tables + editor + verdict shipped
  (096/097); Phase 3 product catalog + benchmarks shipped (098/099); Phase 4a
  forecast handoff shipped (100); Phase 4b promotion door shipped (101); next
  102 cashflow rebate (optional, after 100 is trusted in prod), 103 terms. Decisions locked with Boris there — labor
  cost is ONE rolled-up number (salary privacy), rebate is COGS not billable,
  fee bands are monthly, Paid Media pools search + social, scope dates win at
  promotion, excluded catalog items skip silently.
- Cashflow refinements deferred: retire COGS run-rate at high shaped coverage;
  invoiced deal-months exiting the contracted tier.
- SECURITY: a GitHub PAT was embedded in the old sandbox's git remote — must be
  revoked now that local git auth exists. Old Supabase project deletion.

## Where the deep history lives
The platform was built across long Claude.ai sessions; design rationale beyond
this file is in those transcripts. When something here seems arbitrary, it
almost certainly is not — ask Boris rather than reverting it.
