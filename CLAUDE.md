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
  Budget spread for search/social/programmatic allocates by covered days;
  retainers/creative-retainer bill FULL months regardless of days; hours spread
  evenly. Explicit per-month overrides are human numbers — never scaled.
- **Freeze-on-close**: closed months get explicit deal_line_months rows at the
  as-opened value on save; forecast accuracy is measured, never rewritten.
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
- Forecast axis: bounds snap to $250k, gridlines every $500k ($1M if >13 lines).

## Current migration head: 089. Key views/functions
The number in brackets is the migration holding the CURRENT definition — a fix
is always a new migration, so grep for the highest one before reading an old body.

- `v_deal_month_forecast` [087] — the commercial plan as money. Day-weighted
  media spread from 024; 058 stopped hidden deals leaking into the plan; 087
  split `pass_through` (rebilled search/social media: cash, never revenue) out
  of `billable`. Revenue wants `billable`; cash wants `billable + pass_through`.
- `v_cost_lines_classified` [056] — bill/purchase/journal lines with cost_class
  (cogs/payroll/overhead/other/income/excluded); overrides via
  qbo_accounts.override_class. 056 fixed Other Income and labor sub-accounts
  against the real QB P&L.
- `forecast_page(p_from,p_to)` [080] — whole Forecast page in one jsonb.
  025 added contra revenue; 068-071 wired in bottoms-up labor; 076 made it scan
  v_cost_lines_classified ONCE instead of ~15-20 times (it was the page's load
  cost, not a behaviour change — 076_fixture_test.sql proves byte-identical output);
  079/080 stopped balance-sheet invoice lines (customer deposits) counting as
  revenue, which needs a full QBO re-sync to stamp invoice_lines.account_id.
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
- `hours_page` [064], `rev_proj_page` [080], `accounts_page` [084],
  `v_cash_accounts` [086].
- `project_detail(deal_id)` [088] — one opened project on Project Hours: hours
  per ISO week per department (staff.department first, the entry's own QB Time
  department as fallback) and revenue/GP actual vs plan per month. The actual
  side restates forecast_page's rev_proj/cogs_proj per month for ONE project —
  same CTEs, same 080 fail-open rules — and 088_fixture_test asserts they agree
  to the cent. Per-person hours are NOT here; hours_page's staff_hours_deal /
  staff_deal_planned already carry them.
- `snapshot_forecast`, `v_forecast_accuracy`, `v_invoice_settlement_calibration`
  [067] — measuring the model against itself.
- `promote_approval(hubspot_deal_id)` [078] — the promotion door: deal +
  promotion + flighted lines in ONE transaction, called by Sales Forecast's
  Approve button (the normal path) and by sync-hubspot.mjs as a retry for
  anything still queued. Both go through the single once-only check inside it,
  under an advisory lock, so a deal can never promote twice. Its helpers
  `hs_flight_lines` / `hs_line_item_map` [078] are the ONLY copy of the
  line-item flighting math — the JS twin in sync-hubspot.mjs was deleted, not
  left to drift.
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
- Nightly schedule for sync-hubspot.yml; QB Time sync rewrite; People / Hour
  Planning / Departments / Scoping pages are placeholders.
- Cashflow refinements deferred: retire COGS run-rate at high shaped coverage;
  invoiced deal-months exiting the contracted tier.
- SECURITY: a GitHub PAT was embedded in the old sandbox's git remote — must be
  revoked now that local git auth exists. Old Supabase project deletion.

## Where the deep history lives
The platform was built across long Claude.ai sessions; design rationale beyond
this file is in those transcripts. When something here seems arbitrary, it
almost certainly is not — ask Boris rather than reverting it.
