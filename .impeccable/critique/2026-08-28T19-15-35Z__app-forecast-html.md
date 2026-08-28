---
target: app/forecast.html
total_score: 27
max_score: 40
na_heuristics: 
p0_count: 0
p1_count: 3
timestamp: 2026-08-28T19-15-35Z
slug: app-forecast-html
---
**Method: dual-agent (A: a0c30093e2d8172a4 · B: a080d52fdd617f2c8)**

# Critique: `app/forecast.html`

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|-----------|-------|-----------|
| 1 | Visibility of System Status | 2/4 | No loading/skeleton state on initial load or date-range change — the page renders nothing until `Promise.all` resolves (forecast.html:243‑291). |
| 2 | Match System / Real World | 4/4 | Deal/flight/GP/COGS/contra vocabulary matches agency finance exactly; the "How costs are counted" panel translates QuickBooks account types into plain English. |
| 3 | User Control and Freedom | 2/4 | Destructive actions get `confirm()` gates but no in-app undo — hides/deletes are documented as reversible only "from SQL" (lines 578, 921). |
| 4 | Consistency and Standards | 3/4 | Strong token reuse; undercut by mixed interaction semantics — some clickable elements are real `<button>`s, others bare `<tr>`/`<g>` with `onclick` only. |
| 5 | Error Prevention | 2/4 | Money-bearing inputs (`input.p`, `.totalbudget`, `.cell`) are plain text with no `type="number"` or clamping — a stray keystroke produces `NaN` that can flow into saved cents (forecast.html:850‑854, 862‑896, 1078). |
| 6 | Recognition Rather Than Recall | 3/4 | Title-attribute tooltips, inline definitions, always-visible state (▸/▾, pills) reduce recall burden well. |
| 7 | Flexibility and Efficiency | 2/4 | Fast for mouse-driven scanning, but zero keyboard path to sort, expand, or open a deal — a real gap for a self-described power-user tool. |
| 8 | Aesthetic and Minimalist Design | 3/4 | Disciplined and on-token; per-bar chart labels at 8.5px on every series/month (lines 173‑184) push past even this system's density-by-design standard. |
| 9 | Error Recovery | 2/4 | Raw Supabase/Postgres error strings surfaced verbatim via `alert()`/`msg.textContent` (e.g. lines 582, 596, 607, 1038, 1063, 1087, 1106, 1115, 1124). |
| 10 | Help and Documentation | 4/4 | The "How costs are counted" panel (lines 305‑319) is a genuinely excellent, in-context model of this heuristic done right for a SQL-fluent audience. |
| **Total** | | **27/40** | **Acceptable** (top of band, one step from Good) |

## Design Specificity Verdict

**LLM assessment:** Unambiguous — this could not be dropped into a generic SaaS dashboard unchanged. `KIND` config objects encode media-agency billing mechanics (`fee_pct`, `margin_pct`, creative's retainer/hourly duality), `dayFrac()` implements the day-weighted media-flight spread CLAUDE.md calls a hard-won domain rule, and the chart's color assignments trace 1:1 to DESIGN.md's named tokens (One Gold Rule, settled-vs-forecast opacity). The domain logic and the markup are the same code, not a template with agency words pasted on top.

**Deterministic scan:** The detector ran in **DEGRADED mode** (HTML parser modules unavailable on this machine — `htmlparser2`/`css-select`/`css-tree`/`domutils` missing; it fell back to regex matching). Custom-property resolution, real selector matching, and computed contrast were **not** evaluated, so treat the one finding below as a floor, not a full audit:

- **`flat-type-hierarchy`** (warning) — forecast.html uses 8 distinct font sizes clustered between 8px–12.5px (9, 9.5, 9.9, 10, 11, 11.5, 12, 12.5px), several adjacent steps under a 1.25 ratio apart. Confirmed real by grepping every `font-size` in the file — not a false positive as raw fact.

Where this needs your judgment, though: DESIGN.md documents this exact fine density deliberately — a "real 30-step scale from 9px to 22px because a dense financial console has that many distinct jobs for text to do," explicitly split into a Chrome scale and an Editor micro-scale. The generic best-practice detector doesn't know that; it's flagging the intentional texture of this design system, not an accident. Worth a deliberate yes/no rather than a reflexive fix.

**Browser visualization:** Unavailable — no browser automation tool (Playwright/Puppeteer/native browser) is exposed in this session, so live-server injection and a visible overlay were skipped entirely. No visual/overlay evidence exists for this run; everything above is from source and the CLI scan.

## Overall Impression

This is a well-authored, domain-faithful console — the palette discipline, the settled-vs-forecast opacity convention, and the in-context cost-methodology panel all work exactly as DESIGN.md intends. But the page has a structural blind spot: everything beyond typing into a search or date field assumes a mouse. And the one place where trust matters most — the gold net-profit line, "the single most important color in the system" — doesn't actually apply the measured/forecast distinction the rest of the chart uses. The biggest opportunity is closing that specific gap, because it directly undermines the thing this page exists to be trusted for.

## What's Working

- **The One Gold Rule and closed palette are faithfully implemented**, not just documented — `SERIES` in `comboChart` (forecast.html:128‑136) maps 1:1 to DESIGN.md's token list, with gold appearing exactly once, matching the code's own comment ("Net wears accent gold: the most important line").
- **Settled-vs-forecast opacity on chart bars** (`op=r.measured?1:0.55`, line 166) is a concrete, working expression of the system's most important semantic rule, right where a reader needs it.
- **The cost-methodology help panel** (lines 305‑319) is best-in-class in-product documentation, calibrated precisely to an audience known to be SQL-fluent — plain English plus the literal fix.

## Priority Issues

**[P1] The net line itself breaks the settled/forecast rule it exists to embody.**
Why it matters: Bars dim for unmeasured months (`op=r.measured?1:0.55`, line 166), but the net-line `polyline` (188) and `circle` (191) render at full gold opacity regardless of `r.measured`. DESIGN.md says this distinction should apply "everywhere... not just in the flagship chart" — and it fails inside the flagship chart, on the one series the whole palette discipline protects. A viewer can't tell a real net swing from a projected one without hovering every point.
Fix: Split the polyline into measured/forecast segments (dashed or lightened for projected months), and drop circle opacity to match `op`.
Suggested command: `/impeccable polish` (or `/impeccable harden` if you want it treated as a correctness fix, not cosmetic).

**[P1] Core interactions are entirely mouse-bound — zero ARIA/roles/tabindex anywhere in the page.**
Why it matters: Confirmed by search: no `aria-`, `role=`, or `tabindex` exists in forecast.html, style.css, or shell.js. Opening a deal (`tr onclick`, line 620), sorting (`th[data-sort] onclick`, line 547), expanding a client (`tr.clientrow onclick`, line 612), and toggling a chart series (`<g class="lgd"> onclick`, line 204) are all unreachable by keyboard and invisible to a screen reader. The core edit workflow has no non-mouse path, and the modal (636‑648) has no `role="dialog"`, no focus trap, and no initial-focus management.
Fix: Convert these to real `<button>`/`role="button"` elements with `tabindex`, Enter/Space handlers, and `aria-expanded`/`aria-sort`/`aria-pressed`; add a focus trap to the modal.
Suggested command: `/impeccable audit` (full a11y sweep), then `/impeccable harden`.

**[P1] Financial inputs accept unvalidated free text that can reach saved dollar amounts.**
Why it matters: `input.p`, `.totalbudget`, and `.cell` (850‑854, 862‑896) are parsed with `+inp.value` — no `type="number"`, no clamping. A stray non-numeric keystroke produces `NaN`, which flows into `Math.round((l.params.amount||0)*100)` (line 1078) toward Supabase. CLAUDE.md's non-negotiable #4 is that client/server math must agree digit-for-digit; an unguarded text field feeding that math is an integrity risk, not a nit.
Fix: `type="number"` with `step`, or an oninput sanitizer that strips non-numeric input and shows an inline error instead of silently producing `NaN`.
Suggested command: `/impeccable harden`.

**[P2] No loading state on initial load or range change.**
Why it matters: `render()` (line 295) only writes to the DOM after `loadAll()`'s `Promise.all` resolves; there's no interim skeleton, so a slow connection shows an unexplained blank pane on a page people check specifically to know whether the business is making money.
Fix: Render a lightweight skeleton/"loading…" state synchronously before the fetch begins — the editor modal already does this at line 643; extend the pattern page-wide.
Suggested command: `/impeccable polish`.

**[P2] Raw backend error strings are shown to the user verbatim.**
Why it matters: Nearly every mutation path surfaces `error.message` directly via `alert()`/`msg.textContent` (582, 596, 607, 1038, 1063, 1087, 1106, 1115, 1124). Boris may parse a Postgres constraint violation fine, but PRODUCT.md names finance/ops and account-manager audiences as future users of adjacent pages — this pattern would hand them undigested driver output at the exact moment a save fails.
Fix: Wrap known error classes with a short human sentence; keep the raw message as an optional "details" disclosure.
Suggested command: `/impeccable clarify`.

## Persona Red Flags

**Alex (Power User):** Served well by density, tabular mono numerals, live search, and sortable columns — but hits a wall the moment they try to move without a mouse: no keyboard path to sort a column, expand a client, or open a deal. The blank-screen load also costs a beat of "did that work?" on every range change. Alex would likely tolerate the raw SQL-flavored error strings, since CLAUDE.md establishes the primary user is SQL-fluent — that failure mode really targets the *other* named audience.

**Sam (Accessibility-Dependent User):** Effectively locked out of the primary workflow. The flagship chart is a bare `<svg>` with mouse-only `<title>` tooltips and no `aria-label` or text-table fallback — a screen reader gets nothing from the page's single most important visualization. The deal editor, the core CRUD surface, opens only via `<tr onclick>` with no keyboard equivalent, and the modal has no `role="dialog"`, `aria-modal`, or focus management. This isn't scattered small nits — it's a page where every interaction beyond typing in a search or date field requires a mouse.

## Minor Observations

- Chart bars carry a dollar-value label on every series/month at 8.5px (173‑175, 182, 184) — precise, but strains legibility even by this system's own density standard, with no independent zoom.
- The "How costs are counted ▸" disclosure triangle never flips to ▾ when opened (line 303; handler at 335‑355 never updates the glyph) — inconsistent with client rows, which correctly flip ▸/▾ (line 477).
- Destructive-action confirmations use native `confirm()`/`alert()` dialogs (578, 582, 588, 596, 602‑603, 921) — the one place system chrome breaks out of the Montserrat/Plex-Mono/flat visual language entirely.
- Destructive-action iconography is inconsistent: a bare `✕` for line deletion (line 771) vs. full-word "Hide project"/"Hide deal" buttons elsewhere (574, 836) for functionally similar removals.
- A page-local `<style>` block (forecast.html:4‑10) duplicates tokens outside style.css rather than extending the shared sheet — minor drift from single-source-of-truth.

## Questions to Consider

- The net line is the one place in the whole system gold is allowed to appear — is there any single change on this page with higher leverage than making it honor measured-vs-forecast, the way the bars beneath it already do?
- If Boris is unavailable and an account manager hits a raw Postgres constraint-violation string in an `alert()` mid-save, does the page currently assume its only real user is its own SQL-fluent builder?
- Given `.rl`/`.rd`/`.pct` and friends read from a real, documented 30-step scale (not accidental drift), is the detector's flat-hierarchy flag worth a rule-name entry in `.impeccable/critique/ignore.md` so future runs don't re-litigate a decision you've already made?
