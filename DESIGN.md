---
name: EMG Staffing Ledger
description: The Ledger Console — a flat, brand-locked financial operations shell where Montserrat speaks and IBM Plex Mono counts.
colors:
  deep-ledger-green: "#0a493c"
  muted-ledger-green: "#48a278"
  signal-gold: "#fabf4d"
  logo-teal: "#3bc9ac"
  ledger-paper: "#ebebeb"
  raised-paper: "#ffffff"
  ink: "#23272b"
  slate: "#67706d"
  hairline: "#d2d2d2"
  mint-tint: "#e2f5ef"
  placeholder-gray: "#b5b5b5"
  alert-rust: "#d1453b"
  alert-rust-tint: "#fbe7e4"
  alert-amber: "#b07a14"
  alert-amber-tint: "#fdf3dc"
  ledger-teal: "#19a789"
  table-header-wash: "#f6f6f6"
  column-header-wash: "#f2f2f2"
  client-row-tint: "#fafaf8"
  deal-hover-tint: "#f4faf7"
  rust-on-brand: "#ffb4ac"
typography:
  title:
    fontFamily: "Montserrat, sans-serif"
    fontSize: "14.5px"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "normal"
  body:
    fontFamily: "Montserrat, sans-serif"
    fontSize: "12.5px"
    fontWeight: 400
    lineHeight: 1.65
    letterSpacing: "normal"
  label:
    fontFamily: "'IBM Plex Mono', monospace"
    fontSize: "9px"
    fontWeight: 500
    lineHeight: 1.2
    letterSpacing: "0.12em"
  data:
    fontFamily: "'IBM Plex Mono', monospace"
    fontSize: "11px"
    fontWeight: 400
    lineHeight: 1.2
    letterSpacing: "normal"
  scale:
    root-min: "13px"
    root-max: "16px"
    micro-label: "9px"
    index-text: "10px"
    dense-table-cell: "10.5px"
    table-cell: "11px"
    button-label: "11.5px"
    primary-button-label: "12px"
    body-text: "12.5px"
    nav-item: "13px"
    row-name: "13.5px"
    title: "14.5px"
    modal-title: "15px"
    brand-mark: "17px"
    kpi-value: "18px"
    login-heading: "22px"
    editor-micro-1: "0.56rem"
    editor-micro-2: "0.58rem"
    editor-micro-3: "0.6rem"
    editor-micro-4: "0.62rem"
    editor-micro-5: "0.64rem"
    editor-micro-6: "0.66rem"
    editor-micro-7: "0.68rem"
    editor-small-1: "0.72rem"
    editor-small-2: "0.76rem"
    editor-small-3: "0.78rem"
    editor-small-4: "0.8rem"
    editor-small-5: "0.82rem"
rounded:
  sm: "4px"
  md: "5px"
  lg: "6px"
  xl: "8px"
  full: "99px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  lg: "16px"
  xl: "22px"
components:
  button-primary:
    backgroundColor: "{colors.deep-ledger-green}"
    textColor: "{colors.raised-paper}"
    rounded: "{rounded.sm}"
    padding: "7px 13px"
  button-primary-hover:
    backgroundColor: "{colors.muted-ledger-green}"
  button-ghost:
    backgroundColor: "transparent"
    textColor: "{colors.slate}"
    rounded: "{rounded.sm}"
    padding: "7px 12px"
  button-danger:
    backgroundColor: "transparent"
    textColor: "{colors.alert-rust}"
    rounded: "{rounded.sm}"
    padding: "5px 10px"
  input-field:
    backgroundColor: "{colors.raised-paper}"
    textColor: "{colors.ink}"
    rounded: "{rounded.sm}"
    height: "34px"
  pill-good:
    backgroundColor: "{colors.mint-tint}"
    textColor: "{colors.deep-ledger-green}"
    rounded: "{rounded.full}"
    padding: "2px 8px"
  pill-warn:
    backgroundColor: "{colors.alert-amber-tint}"
    textColor: "{colors.alert-amber}"
    rounded: "{rounded.full}"
    padding: "2px 8px"
  pill-bad:
    backgroundColor: "{colors.alert-rust-tint}"
    textColor: "{colors.alert-rust}"
    rounded: "{rounded.full}"
    padding: "2px 8px"
---

# Design System: EMG Staffing Ledger

## Overview

**Creative North Star: "The Ledger Console"**

This is an operator's console for running the numbers, not a marketing surface — every screen exists so Boris (and, as their pages come online, EMG's finance/ops staff and account managers) can see exactly where the agency's money and staffing hours stand. The voice is precise and institutional: controlled, exact, unshowy. Density and hairline borders read as rigor, not clutter — a page with forty rows of tabular figures is the system working as intended, not a page that needs simplifying.

Two fonts carry the whole identity. Montserrat speaks — every heading, every sentence of prose. IBM Plex Mono counts — every label, every table cell, every number, every badge. The moment you're reading a figure, the typeface itself tells you you're in the ledger, not the prose. Two colors carry the emphasis: Deep Ledger Green is the system's authority (headers, totals, positive figures), and Signal Gold is reserved entirely for the one line that matters most on the forecast chart — net profit. Everything else is neutral: paper, hairlines, slate.

The system is flat by rule. There is no drop shadow anywhere in this design language — elevation is expressed only through hairline borders and background contrast. (The deal-editor modal and the line-item cards were once drift from this rule — both now use border-based separation instead, per the Elevation & Depth section below.)

**Key Characteristics:**
- A locked, closed brand palette — two greens, one gold, one teal, functional red/amber. No new accent colors.
- Montserrat for words, IBM Plex Mono for numbers — never swapped, never mixed within one element.
- Flat surfaces, hairline dividers, zero shadows by rule.
- Dense, tabular, laptop-disciplined: charts scale to their container, table names truncate before they wrap, horizontal scroll is a last resort.
- Settled data reads at full strength; forecast/projected data reads visually lighter — the system always shows you which numbers are real.

## Colors

A closed, two-green-plus-two-accents palette on a warm gray paper ground — nothing decorative, every color assigned a job.

### Primary
- **Deep Ledger Green** (`#0a493c`): The system's authority color. The sidebar brand mark, table totals rows, positive figures. If a number or heading needs to read as "this is the real, settled truth," it's this green.

### Secondary
- **Muted Ledger Green** (`#48a278`): The active/positive/hover register — primary-button hover, "matched" and "ok" status text, links inside summary notes, the good-pill border, and the input focus ring.
- **Ledger Teal** (`#19a789`): A confirmed brand color, declared as `--brand-4` but never wired through it — it shows up as a literal hex instead. The "expected/on-track" line on the cashflow chart and the home dashboard's band chart, and the most-confident tier in the sales pipeline ramp. Legitimate and usable; the gap was documentation, not the color.

### Tertiary
- **Signal Gold** (`#fabf4d`): The single most important color in the system. Reserved for the forecast chart's net-profit line — nothing else. The comment at its point of use in the codebase says it plainly: "Net wears accent gold: the most important line."
- **Logo Teal** (`#3bc9ac`): A sparing wayfinding accent in the app chrome — the current-nav-item indicator border and the sidebar collapse-toggle icon. It marks "you are here" there and nothing more. It also appears as a confidence-tier step in the sales pipeline chart (a confirmed, pre-existing exception — see Sales pipeline confidence ramp); that's a different context (chart series identity, not navigation), not license to use it as a decorative accent generally.

### Neutral
- **Ledger Paper** (`#ebebeb`): The page background — a warm, slightly warm-gray paper, never pure white.
- **Raised Paper** (`#ffffff`): Every card, panel, table, and input surface that sits above the page paper.
- **Ink** (`#23272b`): Primary text.
- **Slate** (`#67706d`): Secondary/muted text — eyebrows, hints, table headers, mono labels.
- **Hairline** (`#d2d2d2`): The default 1px border/divider color, used everywhere a seam matters less than a section boundary.
- **Mint Tint** (`#e2f5ef`): The logo color at roughly 14% on white — hover backgrounds for nav items and table rows, the good-pill fill, the input focus glow.
- **Placeholder Gray** (`#b5b5b5`): Every input's placeholder text, sitewide — one step lighter than Slate so an empty field never reads as a filled one.
- **Table Header Wash** (`#f6f6f6`): The default background for a plain `<th>` — any ordinary table that isn't the account table or the deal-editor grid.
- **Column Header Wash** (`#f2f2f2`): A slightly darker header background reserved for the account table's and the deal-editor totals grid's column headers — one step more emphasis than Table Header Wash.
- **Client Row Tint** (`#fafaf8`): The account table's client (parent) row background — distinguishes a client summary row from the plain-white deal rows nested under it.
- **Deal Hover Tint** (`#f4faf7`): A faint mint-adjacent hover state for deal sub-rows in the account table, quieter than the standard Mint Tint used elsewhere.

### Functional (semantic — reserved for alert meaning only)
- **Alert Rust** (`#d1453b`) / **Alert Rust Tint** (`#fbe7e4`): Errors, negative figures, the danger-button treatment, the bad-pill fill.
- **Alert Amber** (`#b07a14`) / **Alert Amber Tint** (`#fdf3dc`): Warnings, the warn-pill treatment.
- **Rust on Brand** (`#ffb4ac`): A lightened rust used only for negative figures sitting on the totals row's solid Deep Ledger Green background — plain Alert Rust doesn't have enough contrast there.

### Sales pipeline confidence ramp
Pre-existing, not invented this session: `sales.html`'s pipeline chart colors stages by close confidence, deep teal (certain) fading to pale gold (early) — an ordinal ramp, which is the right structure for tiered confidence data. Every step is now a confirmed brand token; the two steps that weren't (`#7dd8bd`, `#e0d3ad` — never documented, discovered during a color audit) are replaced with Mint Tint and Alert Amber Tint, both already established elsewhere in this system.
- **certain → early:** Ledger Teal `#19a789` → Logo Teal `#3bc9ac` → Mint Tint `#e2f5ef` → Signal Gold `#fabf4d` → Alert Amber Tint `#fdf3dc`.

### Named Rules
**The One Gold Rule.** Within the forecast chart, Signal Gold appears in exactly one place: the net line. It is not a general accent, a warning color, or a highlight there — its rarity is what makes it legible as "the number that matters." It also appears as a confidence-tier step in the sales pipeline chart, a separate, confirmed, pre-existing exception (see Sales pipeline confidence ramp) — a different chart, a different job. Don't add a third.

## Typography

**Display/Body Font:** Montserrat (with `sans-serif` fallback) — one family for every heading and every sentence of prose; headings differ from body only in weight and size, never in family.
**Label/Data Font:** IBM Plex Mono (with `monospace` fallback) — reserved entirely for anything that is a number, a label, a badge, or a column header.

**Character:** A single humanist sans carries the system's voice; a monospace face carries its arithmetic. The split is total and load-bearing — it's the fastest way to tell, at a glance, whether you're reading prose or a figure.

### Hierarchy
- **Title** (700, 14.5px, 1.2 line-height): Client names, modal titles, brand-name mark — section-level identifiers. No page in the app currently renders a page-title heading above this weight; the sidebar's highlighted nav item is the only "where am I" signal today.
- **Body** (400, 12.5px, 1.65 line-height): Running prose — page subtitles, hints, descriptive text. Sized via a fluid `clamp(13px, 0.55vw + 11.2px, 16px)` root that shrinks slightly on small screens and grows slightly on large ones.
- **Label** (500, 9px, uppercase, 0.12em tracking, IBM Plex Mono): Eyebrows, summary-strip labels, table headers, mono form labels — the small-caps mono vocabulary that appears on almost every screen.
- **Data** (400, 11px, IBM Plex Mono, tabular numerals): Every table cell, badge, and numeric input. `font-variant-numeric: tabular-nums` is set wherever figures line up in a column, so digits never jitter as they change.

### Scale

The roles above are anchor points on a continuous, fine-grained scale, not the whole ramp — the interface runs a real 29-step scale from 9px up to 22px because a dense financial console has that many distinct jobs for text to do (a table header is not a table cell; a KPI value is not a modal title). Two tracks exist side by side:

- **Chrome scale (fixed px):** `9px` (micro-label: eyebrows, mono labels, table headers, kbadges) → `10px` (index text) → `10.5px` (dense grid/sum/fc table cells) → `11px` (default table cell, summary note) → `11.5px` (button label, emphasized client row) → `12px` (primary-button label, hint text) → `12.5px` (body text, input values) → `13px` (nav item) → `13.5px` (row/deal name) → `14.5px` (client-card title) → `15px` (modal title) → `17px` (sidebar brand mark) → `18px` (KPI value) → `22px` (login heading). These sizes are absolute; they do not respond to the fluid root below.
- **Editor micro-scale (fluid rem):** `0.56rem`–`0.82rem` in twelve steps, used only inside the deal-editor's line/card controls (`.pf`, `.kbadge`, `.lgp`, `.totalsgrid`, `.cardnote`, `.pmcell`, and siblings). Because these are `rem`, they scale with the fluid `html { font-size: clamp(13px, 0.55vw + 11.2px, 16px) }` root — the one part of the UI that actually gets denser on small screens and roomier on large ones.
- The root itself is documented at its two fixed endpoints, `13px` and `16px`.

### Named Rules
**The Two-Voice Rule.** Montserrat speaks; IBM Plex Mono counts. A heading, a sentence, a button label — Montserrat. A number, a table cell, a badge, a column header — IBM Plex Mono. Never swap them, never mix them within one element.
**The Micro-Scale Rule.** New chrome text uses a step from the Chrome scale above; new deal-editor controls use a step from the Editor micro-scale. Don't invent a new literal size — pick the closest existing step, or extend the scale deliberately (and document it here) if none fits.

## Layout

An app-shell with a fixed 184px sticky sidebar (collapsible to 52px, its own independent scroll) and a flexed main content area (`padding: 20px 22px 80px`). Below 760px the sidebar drops above the content and stops being sticky. Density is the default posture: table cells run 10.5–11px, row padding is single-digit pixels, and columns are packed edge to edge rather than given breathing room — this is a tool for scanning many numbers quickly, not a leisurely read.

**The Laptop Discipline Rule.** Charts scale to their container (`max-width: 100%; height: auto`) rather than overflowing. Long names truncate with an ellipsis rather than wrapping a row taller. Horizontal scroll on a table is a last resort, reached for explicitly (`.gridwrap`) rather than allowed to happen by accident.

## Elevation & Depth

Flat by rule: every surface separation in this system is a hairline border (`1px solid var(--line)`) or a background-contrast step (paper vs. raised-paper), never a shadow. Section boundaries that matter more than an ordinary hairline — the sidebar's brand mark, a data table's header row, the modal's title bar, the totals-grid header — step up to a 2px Deep-Ledger-Green rule line instead of a heavier shadow or a bigger gap.

The deal-editor modal and the line-item cards once drifted from this rule with a soft shadow each; both are flat now — the modal uses its hairline border plus the 2px brand rule under its header, and the line cards use a plain hairline border, no shadow on either.

### Named Rules
**The Flat-By-Rule Rule.** No `box-shadow` anywhere. Depth is hairline borders and background contrast only.
**The Brand Rule Line.** A boundary that matters gets a 2px Deep-Ledger-Green underline; every lesser division gets a 1px hairline in `--line`. The weight of the border tells you how important the seam is.

## Shapes

A tight, mostly-shared radius scale: 4px for the smallest interactive controls (buttons, base inputs), 5–6px for badges, panels, and grouped cards, 8px for the modal and floating line cards, and full pill (`99px`) radius for status pills and the "soon" badge. Borders default to 1px hairline; the only heavier border is the 2px brand rule line marking a real section boundary (see Elevation & Depth). No clipping, no cut corners, no asymmetric radii — every rounded corner in the system uses the same small, quiet curve.

## Components

Buttons, inputs, and cards read as **terminal-tactile**: small, precise, and dense, built to feel like instrument controls on a trading-floor terminal rather than a soft consumer app — nothing oversized, nothing decorative, every control sized to fit a lot of them on one dense screen.

### Buttons
- **Shape:** 4px radius, IBM Plex Mono label at 11.5px.
- **Primary:** Deep Ledger Green background, white text, no border, `7px 13px` padding; hovers to Muted Ledger Green.
- **Ghost:** transparent background, hairline border, slate text; hovers to a dark border and ink text.
- **Danger:** transparent background, rust border and text — reserved for destructive actions only.
- **Disabled:** hairline-gray background and text, cursor default, no hover response.

### Data Tables
- **Style:** collapsed borders, raised-paper background, hairline cell borders, right-aligned numeric columns (first column stays left-aligned), IBM Plex Mono at 10.5–11px with tabular numerals so figures never jitter.
- **Header:** uppercase IBM Plex Mono label at 9px, light gray background, 2px Deep-Ledger-Green bottom border on the most important table variant (`.acct`); sortable headers show a small directional indicator in brand green.
- **Rows:** client/parent rows are bold with a hairline top border and a light background tint; child/deal rows sit on plain white; hovering a clickable row tints it Mint.
- **Totals row:** solid Deep Ledger Green background, white bold text — the one row in a table allowed to invert the palette.
- **Column grouping:** on the account table, a hairline (`border-left`) marks the start of the Value column and again before Variance, quietly grouping GP Billed and GP Forecast as a pair with no divider between them — proximity signals relationship without a new visual language.
- **Out-of-tolerance flag:** a variance beyond ±15% gets a Rust Tint chip (background, weight, small radius) instead of plain colored text — the one number per row worth interrupting the scan for. Everything inside tolerance stays quiet text; flagging every number would defeat the flag.
- **Sized by its columns, not its container:** the deal-editor's month-by-month grid (`.totalsgrid`) is `table-layout:fixed` with explicit widths (a 190px label column, 84px per month) and no forced 100% width — a two-month deal stays compact instead of stretching into empty columns, a twelve-month deal grows past the modal and scrolls via `.gridwrap`, same laptop-discipline rule as everywhere else.
- **Whole-row-clickable tables (accepted a11y tradeoff):** `sales.html`'s and `forecast.html`'s expandable client/deal rows put `role="button"` directly on the `<tr>` (with `tabindex="0"`, `aria-expanded`) so the entire row — not just a disclosure triangle — is one click/Enter/Space target. This deliberately overrides the row's native table semantics: a screen reader announces it as a button, not a table row, losing per-cell navigation for that row. Accepted because the whole-row click is a real usability win for the primary (mouse/sighted-keyboard) audience and the row's own cell values are still read out as the button's accessible name. Don't silently "fix" this by moving the role to a sub-element without discussing the tradeoff first — it's a decision, not an oversight.

### Status Pills
- **Style:** full-round (`99px`), IBM Plex Mono at 10px, 2px/8px padding, hairline border by default.
- **Good:** Mint Tint background, Deep Ledger Green text and border.
- **Warn:** Alert Amber Tint background, Alert Amber text and border.
- **Bad:** Alert Rust Tint background, Alert Rust text and border.

### Inputs / Fields
- **Style:** 34px height (28–30px in dense in-table contexts), hairline border, 4px radius, IBM Plex Mono value text, raised-paper background.
- **Focus:** border shifts to Muted Ledger Green with a soft Mint glow ring (`box-shadow: 0 0 0 2px var(--mint)`); no color change, no shadow elevation.
- **Disabled:** light gray background, slate text, hairline-light border, not-allowed cursor.
- **Settings form (the deal editor):** a label-beside-control row laid out on a real grid (`auto-fit, minmax(260px,1fr)`), not a stack of full-width rows — the two fields that benefit from room (deal name, QB project) span the full width, the rest pair up. A wide modal only reads as spacious when its form actually uses the width; a stack of capped-width rows against a wide container is what "small box" complaints are usually about.

### Navigation
- **Style:** 184px fixed sidebar, raised-paper background, hairline right border, sticky with independent scroll. Section labels are uppercase IBM Plex Mono at 9px. Nav items are 13px medium-weight Montserrat.
- **States:** default ink text; hover and current both tint to Mint background with Deep-Ledger-Green text; current additionally gets a 3px Logo-Teal right border as the "you are here" mark.
- **Collapsed:** the sidebar can shrink to 52px, hiding every label and centering the icon-only nav items; the transition is a quick 0.12s width ease.

### Chart System — the template for every chart in the platform
Built for `forecast.html`'s combo chart, this is the reusable pattern for every future chart and dashboard here, not a one-off. Two invented six-hue palettes got rejected before landing here — a bright one that read as a gamified consumer stat card, then a deeper/muted one rejected for the same root cause: new colors with no tie to this brand's guide. A full color audit against source (every literal color in `style.css`, `shell.js`, and every page, not just this file) settled it: the chart draws from the confirmed brand tokens, not an invented ramp.

**Two on the chart, the rest on hover.** After the second pass over-labeled (every bar, every month) and read as cluttered, the on-chart labels narrowed to exactly two series: revenue (above its bar) and net (below its marker — placed there specifically so it doesn't collide with the marker or the line). COGS and every opex-stack segment carry their value only in the hover tooltip, not a permanent label. A real interactive tooltip (a positioned div, following the cursor) replaced relying on the native SVG `<title>` alone, which is slow to appear and easy to miss; `<title>` stays as a no-JS/accessibility floor underneath it.

**The bars — five confirmed brand tokens, no invented sixth.** Six cost categories, drawn entirely from the CSS custom properties already in `style.css` — literal `var(--brand)` etc. in the chart code, not new hex values: Deep Ledger Green (revenue), Slate (COGS), Muted Ledger Green (labour), Ledger Teal (overhead), Logo Teal (other). Fixed reuses Slate — the confirmed brand palette only has five real identity colors, one short of six, and the decision was to accept that rather than invent a sixth hue or shrink the category list. COGS and fixed never touch in the layout (COGS is its own bar; fixed sits at the top of the opex stack, several bar-widths away), so the shared color reads as two same-toned areas in different, fixed positions, not one ambiguous boundary — position and the hover title disambiguate them. The legend does show two identical swatches for different labels; that's the accepted trade-off, not an oversight.

**Marks.** Bars are ≤13px, sharp rectangles — no rounding; a rounded top read as soft/consumer-app rather than institutional. Net-line markers are 4px radius with a 2px paper-color ring, so they stay legible crossing the line or each other. Gridlines and the zero-baseline stay hairline and recessive (`var(--line)`, solid, never dashed — dashing reads as a threshold or projection when it's just a grid).

**Measured vs. forecast** stays exactly as before: settled months render at full color strength, projected months at 55% opacity with the net line's projected segments dashed — so a viewer can always tell forecast from fact without reading a label.

**The chart footer — now the one legend for every chart in the app.** The legend lives in a grey bar under the chart (`.chart-legend`, `#f2f2f2`, a hairline top border), not drawn inline in the SVG — established first on `sales.html`, then applied everywhere: the combo chart's per-series toggles moved out of bare `<g role="button">` SVG groups into real `<button class="lg-item toggle">` elements (native Enter/Space activation, no manual keydown shim needed), and `shell.js`'s `barChart`/`bandChart` (home dashboard, Cashflow) draw the same static `.lg-item` swatch rows instead of in-SVG rects and text. Clicking a combo-chart toggle still persists to `localStorage` and rescales the y-axis to whatever series remain visible. The wrapping panel opts in with `.chartpanel` (`padding:0`) so the grey bar can bleed to the panel's own edges and round its own bottom corners to match (the panel itself uses `overflow:visible`, so this is the child's job, not clipping). A page with expandable detail below the swatch row (Sales' pipeline-health status) wraps it in `.chart-detail`, still inside the same grey footer — a status toggle here is styled as just another `.lg-item`, its dot color carrying the good/warn/bad signal, not a separate pill.

**The KPI ribbon.** Every chart page now leads with one: a headline-numbers strip above the chart, reusing the shared `.summary-strip`/`.summary-cell` component (first built for Cashflow). Forecast's shows net profit, revenue, gross profit, and how many months in the range are measured versus still forecast — every figure summed from the exact same per-month rows the chart itself draws from, so the ribbon and the chart can never disagree.

**The chart hover.** Hovering (or, via each month's own `tabindex="0"` focus, tabbing to) a month shows one tooltip aggregating every currently-visible series for that month — not a separate one-line tip per bar segment. Established on Sales' chart, then applied to the combo chart here: the per-series legend toggle still hides/shows a series and rescales the axis exactly as before, and the tooltip respects the same hidden-series state. The per-rect `<title>` stays underneath as a no-JS/accessibility floor.

## Do's and Don'ts

### Do:
- **Do** keep Signal Gold to exactly one job: the forecast chart's net line.
- **Do** write every heading and sentence in Montserrat, and every number, label, badge, and column header in IBM Plex Mono — never swap them.
- **Do** mark a real section boundary with a 2px Deep-Ledger-Green rule line, and everything smaller with a 1px hairline.
- **Do** keep Alert Rust and Alert Amber reserved for their alert meanings only — never decorative.
- **Do** let charts scale to their container and let table names truncate rather than wrap or force horizontal scroll (The Laptop Discipline Rule).
- **Do** render settled data at full color strength and projected/forecast data visually lighter, everywhere the distinction applies — not just in the flagship chart.

### Don't:
- **Don't** add `box-shadow` anywhere; this system is flat by rule. Bring the modal and line-card's current shadows to border-based separation next time either is touched.
- **Don't** introduce a new accent color outside this closed palette (two greens, one gold, one teal, functional red/amber).
- **Don't** use Logo Teal in the app chrome for anything beyond the current-nav-item indicator and the sidebar toggle icon — it is a wayfinding mark there, not a decorative accent. (The sales pipeline ramp is a confirmed, separate exception.)
- **Don't** use Signal Gold in the forecast chart for anything but the net line — not a pill border, not a warning state, not a highlight. (The sales pipeline ramp is a confirmed, separate exception.)
