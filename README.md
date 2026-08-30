# EMG Staffing Ledger

A staffing & profitability platform for EMG, a media agency with ~60 clients
and ~50 staff. It reconciles QuickBooks Online actuals, HubSpot pipeline, and
internal staffing data into a single forecast — held to agree with the
QuickBooks P&L within ~$20k/month — so leadership can see the agency's real
financial trajectory without reconciling spreadsheets by hand.

No build step: static ES-module pages in `app/`, deployed by pushing to
`main`, served by GitHub Pages at
https://bkorbit.github.io/staffing-ledger/app/. Data lives in a single
Supabase project. Nothing to compile, no bundler, no `node_modules` in
production.

## Pages

**Forecast** — the core P&L. A combo chart (revenue / COGS / labour /
overhead / other / fixed costs, plus a net-profit line) over an editable
month range, backed by a client/deal ledger table that expands into each
client's deals and unclaimed QuickBooks projects. Clicking a deal opens a
full editor: per-line-kind cards (retainer, creative, search, social,
programmatic, hourly) with rate/fee/margin fields, day-weighted or even
budget spreading across flight months, per-month overrides, a live
GP/revenue preview split into closed vs. open months, QB project linking,
and Save (which freezes closed months at their as-opened value). Includes
an "Export forecast" button that writes a fill-in .xlsx template, and an
expandable panel showing how every QuickBooks account is classified.

**Sales Forecast** — pipeline-based revenue forecast from the HubSpot
mirror, stacked as committed GP (from shaped deals) plus pipeline value by
stage-confidence tier. Weighted/total and forecastable/all-deals toggles, a
pipeline-health panel (% forecastable, promotion status), and a client →
deal → line-item drill-down table flagging missing line items, stale close
dates, and unmapped line-item names.

**Cashflow** — a three-line (optimistic / expected / conservative) projected
cash position chart over half-month periods, a KPI strip (bank balance,
run-rate, open AR/AP with overdue %), a period-by-period ledger table, and
aging tables for both clients and vendors. Read-only.

**Client Profitability** — per-client health blending measured actuals with
forecast for months still open: revenue, COGS, GP, hours-based labor cost,
profit-after-labor, effective rate/hour, and an at-risk flag for negative
margin. Sortable, searchable, with a "measured only" toggle.

**Project Hours** — the same actuals-times-labor-cost method at the
deal/project level: hours logged vs. planned, labor cost, revenue, profit,
with a top-10-by-revenue chart and at-risk flagging.

**Team** — the staff roster and compensation editor. Sortable table with
computed total annual cost (salary/hourly cost plus employer FICA, FUTA,
401k match, health insurance, and state workers'-comp). Each person's modal
holds department, hire/end date, active/ended/inactive status, benefits
elections, and a full multi-period compensation history (each period its own
date range, employment type, and rate).

**Team Hours** — read-only per-staff utilization report: hours logged vs.
capacity, pacing against assignment, and plan-vs-logged, each as a stacked
mini-bar. Expands per row into a client/project breakout. Quick-range presets
(this/last month, this/last quarter) plus department filter.

**Clients** — the linking utility that ties platform clients to QuickBooks
customers and blocks specific company names from HubSpot auto-attachment,
with unlink/deactivate controls.

**Settings** — the admin console: sync status, HubSpot reconciliation
(promotion allowlist, stale-date and reopened-deal diagnostics), operating
bank account flags, and every tunable knob behind the math above (sales
probability threshold, programmatic margin/COGS terms, payroll burden rates,
benefits costs, per-state workers'-comp rates).

**Home** — a bottom-up hours dashboard (department hours, revenue-vs-labor
trend, time-allocation donuts, hours by project) plus live embedded copies
of the Cashflow, Forecast, and Sales Forecast charts, all sharing one
date-range picker.

**Hour Planning** and **Scoping** are stubs — not yet built for the
finance/ops and account-manager audiences they're aimed at.

## Domain concepts worth knowing

- **Claims attribution** — a QuickBooks project matched to a deal belongs to
  that deal's client; a client's actuals are its deals' claimed projects plus
  its own QuickBooks parent's unclaimed remainder. This lets two platform
  clients split one QuickBooks entity.
- **Contra revenue** — search/social pass-through media spend is booked
  against income-type contra accounts, so measured revenue is invoices minus
  income-class cost lines, netted per month and per project.
- **Day-weighting** — media flights (search/social/programmatic) spread
  their total budget by covered calendar days; retainers and creative bill
  full months regardless of days; hours spread evenly. Explicit per-month
  overrides are human numbers and are never rescaled.
- **Freeze-on-close** — once a month closes, its deal-line values get
  explicit frozen rows at the as-opened figure, so forecast accuracy is
  measured against history, never quietly rewritten.
- **Measured vs. forecast** — a month counts as "measured" only once it has
  fully closed; the in-progress month always runs on forecast, never on
  partial actuals.

## Data syncs

- `scripts/sync-qbo.mjs` — QuickBooks Online invoices, bills, purchases,
  journal entries, accounts, and projects. Runs several times during
  business hours via `.github/workflows/sync-qbo.yml`.
- `scripts/sync-hubspot.mjs` — full-replace mirror of the HubSpot pipeline,
  plus one-time promotion of won deals into the ledger (promotions protect
  history — a hidden or renamed deal is never resurrected). Same schedule,
  via `.github/workflows/sync-hubspot.yml`.
- `scripts/sync-qbtime.mjs` — QuickBooks Time hours, daily at 07:00 UTC via
  `.github/workflows/sync-qbtime.yml`. See below for one-time setup.

### QuickBooks Time sync setup

The daily sync pulls hours from QuickBooks Time and writes them into the
ledger as **actuals** for the current month plus the two previous months.
Those months are treated as fully owned by QuickBooks Time — each sync
replaces them, so corrections and deletions in QB Time flow through.

1. **Get a QuickBooks Time API token**: in QuickBooks Time, go to **Feature
   Add-ons → Manage Add-ons → API** and install it, then open the API
   add-on and choose **Add Token**. Copy the access token. (If your account
   was migrated to Intuit sign-in and this screen looks different, an admin
   may need to create the token via the Intuit developer portal instead.)
2. **Get your Supabase service-role key**: Supabase dashboard → Project
   Settings → API → `service_role` key. This key bypasses row security — it
   must only ever live in GitHub secrets, never in the app code.
3. **Add both as repository secrets**: GitHub repo → Settings → Secrets and
   variables → Actions → New repository secret:
   - `QBTIME_TOKEN`
   - `SUPABASE_SERVICE_ROLE_KEY`
4. **Test it**: repo → Actions → "Sync QuickBooks Time actuals" → Run
   workflow. The log shows how many entries were pulled and which months
   were written.

**Mapping rules**: the **person** is the QB Time user's first + last name,
matched case-insensitively to the Team list; unknown people are created
with $0 cost (set it in the Team tab). The **project** is the top-level
parent jobcode (the customer), so hours logged against sub-jobs roll up to
the customer; jobcodes named Internal / Non-billable / Admin / Overhead go
to internal hours. Unknown customers become new projects with $0 revenue
(set revenue in the Clients/Forecast tabs).

## Development

- Schema changes ship as new, immutable, numbered SQL migrations in `db/`,
  run manually in the Supabase SQL editor — never edited in place once
  shipped.
- Run `node scripts/check-forecast.mjs` before every commit that touches
  `app/forecast.html` (syntax, scope, and retired-key audit).
- Every deploy re-stamps `?v=<short-sha>` on the `shell.js`/`style.css`
  references in every `app/*.html` page (a follow-up "Stamp assets." commit
  using the sha of the change it's stamping), to bust GitHub Pages' CDN
  cache.
