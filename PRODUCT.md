# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

Primary user is Boris, owner-operator of EMG (a media agency with ~60 clients
and ~50 staff) — direct, ships fast, verifies everything against real
production data. The platform is also used by EMG's finance/ops staff and
account managers: finance/ops for staffing and cost data on their own pages,
account managers for their clients' profitability and staffing view. Several
of those audiences' pages (People, Hour Planning, Departments, Scoping) are
currently placeholders — built for Boris's workflow first, with the other
roles' surfaces still to come.

## Product Purpose

A staffing & profitability platform for EMG. It tracks staffing costs,
revenue, and forecasted profitability across every client and every staff
member, so leadership can see EMG's real financial trajectory without
manually reconciling QuickBooks exports, HubSpot pipeline data, and staffing
spreadsheets by hand every month.

## Positioning

Unified profitability truth: one system that reconciles QuickBooks actuals
(invoices, bills, purchases, journal entries), HubSpot pipeline, and internal
staffing/forecast data into a single P&L-accurate forecast — reconciled to
the QuickBooks P&L within ~$20k/month. No spreadsheet or standalone tool can
replicate this without the same integration depth: claims attribution
(matching QBO projects to deals and clients), contra revenue netting for
pass-through media spend, and day-weighted media-flight budget spreading.
Client and server math are held to agree digit-for-digit, so the forecast is
trusted as a real number, not an estimate.

## Operating Context

No-build static app (ES modules) deployed to GitHub Pages by pushing to
main; data lives in a single Supabase project. `scripts/sync-qbo.mjs` and
`scripts/sync-hubspot.mjs` run nightly to keep actuals and pipeline current;
a GitHub Action pulls QuickBooks Time hours daily. Schema changes ship as
new, immutable, numbered SQL migrations run manually in the Supabase SQL
editor — never edited in place once shipped. The forecast is reviewed on an
ongoing basis to track measured-vs-forecast accuracy; "measured" only ever
means a month that has fully closed, never an in-progress month showing
partial actuals.

## Capabilities and Constraints

- Static ES-module pages in `app/`, shared shell/auth/helpers in
  `app/assets/shell.js`, tokens in `app/assets/style.css`. No bundler.
- Single source of truth: Supabase project `zytmlowigbfchfqcilrr`. Supabase
  caps requests at 1000 rows; unbounded reads must page.
- Nightly syncs from QuickBooks Online and HubSpot; daily QuickBooks Time
  sync for staffing hours.
- Domain logic that is decided and not to be re-litigated silently: claims
  attribution, contra revenue netting, day-weighted media flight spreading
  (media only — retainers/creative bill full months), freeze-on-close
  forecast accuracy.
- Hard constraint: `app/forecast.html`'s client-side math and the
  `v_deal_month_forecast` view must agree exactly; a change to one requires
  the matching change to the other, fixture-tested before shipping.
- Currently placeholder/undecided: People, Hour Planning, Departments, and
  Scoping pages exist as stubs, not yet built out for the finance/ops and
  account-manager audiences.

## Brand Commitments

Brand kit is locked in `app/assets/style.css` tokens: paper `#ebebeb`, brand
greens `#0a493c` / `#48a278` / `#19a789`, accent gold `#fabf4d` (the net
line — the most important figure on the forecast chart), logo `#3bc9ac`.
Functional red/amber retain their alert meanings and are not part of the
brand palette. Chart text is black; the legend sits at the bottom and is
interactive.

## Evidence on Hand

Real production financial and staffing data lives in Supabase (client
deals, actuals, forecasts, staffing costs) — this is operational data, not
marketing content. This is a 100% internal tool with no external-facing
surface, so there are no testimonials, case studies, press, or pricing to
reference, and none should be fabricated.

## Product Principles

- Client and server math must agree digit-for-digit — trust comes from
  exact reconciliation to QuickBooks, never from a close-enough estimate.
- A month is "measured" only once it is fully over; forecast and actuals are
  never blended to make an in-progress month look decided.
- Decided domain truths (attribution, contra revenue, day-weighting,
  freeze-on-close) are facts to build on, not open questions — ask Boris
  before reversing one rather than assuming it was arbitrary.
- Ship fast, verify with real data — changes are validated against
  production numbers and fixture-tested, not just reasoned about.
- Deploy is a push, with no build step; keep the app dependency-light so
  that stays true.
