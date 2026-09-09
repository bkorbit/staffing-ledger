// The two reports behind an opened project (Project Hours) or client (Client
// Profitability): hours logged per ISO week stacked by department, and
// revenue + gross profit actual vs plan per month. One copy, imported by both
// pages, so the two can never drift — they read project_detail (db/088) and
// client_detail (db/089), which return the same `weeks` / `months` shapes.
//
// Deliberately does NOT import shell.js: a module reached through a second
// URL would be a second module instance, and shell.js creates the Supabase
// client at import time. The two helpers it would have wanted are restated.
//
// Drawn here rather than through shell.js's barChart/bandChart because these
// need things no other chart has — a shaded band for the page's range, a
// "today" rule, null-terminated actual lines beside dashed plan lines, a
// y-axis snapped to the project's own scale (bandChart snaps to Forecast's
// $250k gridlines, which flattens a $30k/month project to the floor), and a
// per-period hover tooltip listing every series.

const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
const fmtHours = h => (+h || 0).toLocaleString(undefined, { maximumFractionDigits: 1 });
const fmt$0 = c => (c < 0 ? '-$' : '$') + Math.abs(Math.round((c || 0) / 100)).toLocaleString();
const fmtDayMon = s => new Date(s + 'T00:00:00Z')
  .toLocaleDateString(undefined, { day: 'numeric', month: 'short', timeZone: 'UTC' });
const fmtMonYY = s => new Date(s + 'T00:00:00Z')
  .toLocaleDateString(undefined, { month: 'short', year: '2-digit', timeZone: 'UTC' });
// condensed money for a y-axis with no room to spell the number out
const fmtK = c => { const d = c / 100, a = Math.abs(d), sign = d < 0 ? '-' : '';
  if (a >= 1e6) return `${sign}$${(a / 1e6).toFixed(1)}MM`;
  if (a >= 1e3) return `${sign}$${Math.round(a / 1e3)}k`;
  return `${sign}$${Math.round(a)}`; };
const iso = d => d.toISOString().slice(0, 10);
const endOfMonth = m => { const [y, mm] = m.slice(0, 7).split('-').map(Number);
  return iso(new Date(Date.UTC(y, mm, 0))); };
const shiftM = (m, n) => { const [y, mm] = m.slice(0, 7).split('-').map(Number);
  return iso(new Date(Date.UTC(y, mm - 1 + n, 1))); };
const addDays = (s, n) => { const d = new Date(s + 'T00:00:00Z'); d.setUTCDate(d.getUTCDate() + n); return iso(d); };
// Monday on or before s — the same bucket date_trunc('week') gives the weeks
const mondayOf = s => { const d = new Date(s + 'T00:00:00Z'); const dow = (d.getUTCDay() + 6) % 7;
  d.setUTCDate(d.getUTCDate() - dow); return iso(d); };

// Department series colours: the chart categorical ramp (--cat-1..6 in
// style.css — six steps of the brand green from the extended kit, in the one
// dark/light alternation that keeps adjacent stacked segments apart; slot 1
// is Muted Ledger Green). Assigned by department NAME company-wide, never by
// a project's own ranking, so the same department is the same colour on every
// project and every client: departments are ordered by headcount on
// hours_page's staff list (ties alphabetical), which puts the brand green on
// the largest team and only changes when the roster does. DEPT_SLOTS pins a
// department to a slot explicitly and wins over that order — fill it in once
// the department names are settled. A seventh department folds into grey
// "Other" rather than inventing a hue: the kit has no seventh legible step.
export const DEPT_COLORS = ['var(--cat-1)', 'var(--cat-2)', 'var(--cat-3)', 'var(--cat-4)', 'var(--cat-5)', 'var(--cat-6)'];
export const DEPT_SLOTS = {};        // e.g. { 'Paid Media': 0, 'Creative': 2 } — slot index into DEPT_COLORS
const OTHER_COLOR = 'var(--cat-other)';
const OTHER = 'Other';

// company-wide department order: pinned slots first, then by headcount desc,
// then name — the key every chart colours by
export function departmentOrder(staff) {
  const count = {};
  staff.forEach(s => { if (s.department) count[s.department] = (count[s.department] || 0) + 1; });
  const free = Object.keys(count).filter(d => DEPT_SLOTS[d] === undefined)
    .sort((a, b) => count[b] - count[a] || a.localeCompare(b));
  const order = [];
  Object.entries(DEPT_SLOTS).forEach(([d, i]) => { if (count[d] !== undefined) order[i] = d; });
  free.forEach(d => { let i = 0; while (order[i] !== undefined) i++; order[i] = d; });
  return order.filter(Boolean);
}

// ---- hours logged, stacked — by week, or by month once the window is long ----
// opts.by = 'department' (default; detail.weeks, coloured by the company-wide
// department order) or 'deal' (detail.weeks_by_deal, one series per project,
// named and ordered by detail.deals — flight start then name, so a project
// keeps its colour as hours shift between projects). The by-project /
// by-department switch is the page's (a small pill on the card), not the
// chart's.
//
// The window is where the information is: from the first week with hours to
// the last, never the flight or the future — an empty flight start or a lull
// after the last entry is not drawn as empty track. A dribble at either end
// (a bucket under 1% of the tallest, e.g. a stray quarter-hour logged a year
// early) is trimmed too, so one mislogged entry cannot stretch the axis back
// across a year of nothing; the table's totals still count it. Once the
// trimmed window is longer than four months the bars become MONTHS (a week
// is bucketed by the month its Monday falls in) — 26+ weekly bars read as
// noise where six monthly ones read as a trend. The page's own range is
// shaded whichever grain is drawn.
const DRIBBLE = 0.01;
const MONTHLY_AFTER_WEEKS = 18;   // ~4 months
export function hoursByWeekChart(el, detail, rangeFrom, rangeTo, deptOrder, opts = {}) {
  const W = 940, H = opts.height || 190, P = { l: 48, r: 28, t: 14, b: 24 };
  const byDeal = opts.by === 'deal';
  // rows normalised to {week, key, hours}; order[] is the fixed colour key
  let rows, order, label;
  if (byDeal) {
    const deals = detail.deals || [];
    const names = {}; deals.forEach(d => names[d.id] = d.name || '(unnamed deal)');
    rows = (detail.weeks_by_deal || []).map(r => ({ week: r.week, key: r.deal_id, hours: +r.hours }));
    label = k => names[k] || '(unknown deal)';
    // slots by total hours, biggest first: with more projects than colours,
    // the six that matter are the six you can tell apart
    const tot = {}; rows.forEach(r => tot[r.key] = (tot[r.key] || 0) + r.hours);
    order = Object.keys(tot).sort((a, b) => tot[b] - tot[a] || label(a).localeCompare(label(b)));
  } else {
    rows = (detail.weeks || []).map(r => ({ week: r.week, key: r.department, hours: +r.hours }));
    label = k => k;
    // the company-wide order first (same colour for the same department on
    // every chart), then any department the staff list does not know — an
    // entry's own QB Time department standing in for a person with none —
    // appended so it gets a colour while slots remain instead of going grey
    const extra = [...new Set(rows.map(r => r.key))].filter(k => !deptOrder.includes(k)).sort();
    order = [...deptOrder, ...extra];
  }
  const totalsByWeek = {};
  rows.forEach(r => { if (r.hours > 0) totalsByWeek[r.week] = (totalsByWeek[r.week] || 0) + r.hours; });
  let dataWeeks = Object.keys(totalsByWeek).sort();
  if (!dataWeeks.length) {
    el.innerHTML = `<div class="empty-note" style="padding:28px 14px">No hours logged here yet.</div>`; return;
  }
  // trim the dribble at either end
  const tallest = Math.max(...dataWeeks.map(w => totalsByWeek[w]));
  while (dataWeeks.length > 1 && totalsByWeek[dataWeeks[0]] < tallest * DRIBBLE) dataWeeks.shift();
  while (dataWeeks.length > 1 && totalsByWeek[dataWeeks[dataWeeks.length - 1]] < tallest * DRIBBLE) dataWeeks.pop();
  const first = dataWeeks[0], last = dataWeeks[dataWeeks.length - 1];
  const weeksSpan = Math.round((new Date(last) - new Date(first)) / 6048e5) + 1;
  const monthly = weeksSpan > MONTHLY_AFTER_WEEKS;
  // buckets: every week (or month) from first to last, gaps included
  const bucketOf = w => monthly ? w.slice(0, 7) + '-01' : w;
  const buckets = [];
  if (monthly) { for (let m = first.slice(0, 7) + '-01'; m <= bucketOf(last); m = shiftM(m, 1)) buckets.push(m); }
  else { for (let w = first; w <= last; w = addDays(w, 7)) buckets.push(w); }
  const idx = {}; buckets.forEach((k, i) => idx[k] = i);
  const slot = k => order.indexOf(k);
  const colorOf = k => { const i = slot(k); return i >= 0 && i < DEPT_COLORS.length ? DEPT_COLORS[i] : OTHER_COLOR; };
  const nameOf = k => { const i = slot(k); return i >= 0 && i < DEPT_COLORS.length ? label(k) : OTHER; };
  const seriesByName = {};
  const folded = {};   // Other's members: key -> per-bucket hours, for the tooltip
  rows.forEach(r => {
    if (r.week < first || r.week > last) return;
    const name = nameOf(r.key);
    const s = seriesByName[name] = seriesByName[name] || { name, key: name === OTHER ? OTHER : r.key, color: colorOf(r.key), values: buckets.map(() => 0) };
    const i = idx[bucketOf(r.week)]; if (i === undefined) return;
    s.values[i] += r.hours;
    if (name === OTHER) { const f = folded[r.key] = folded[r.key] || buckets.map(() => 0); f[i] += r.hours; }
  });
  // the fold is named by what it holds, not "Other": "+3 smaller projects"
  const foldedKeys = Object.keys(folded).sort((a, b) => label(a).localeCompare(label(b)));
  if (seriesByName[OTHER]) seriesByName[OTHER].name =
    `+${foldedKeys.length} smaller ${byDeal ? (foldedKeys.length === 1 ? 'project' : 'projects') : (foldedKeys.length === 1 ? 'department' : 'departments')}`;
  // stack order = the fixed palette order, Other last — so the colours read
  // the same way top-to-bottom everywhere
  const series = Object.values(seriesByName).sort((a, b) =>
    (a.key === OTHER ? 99 : slot(a.key)) - (b.key === OTHER ? 99 : slot(b.key)));
  const totals = buckets.map((_, i) => series.reduce((s, sr) => s + sr.values[i], 0));
  const rawMax = Math.max(...totals, 1);
  const unit = rawMax > 400 ? 100 : rawMax > 80 ? 20 : 10;
  let max = Math.ceil(rawMax / unit) * unit; if (max - rawMax < unit * 0.2) max += unit;
  const step = max / unit > 8 ? unit * Math.ceil(max / unit / 6) : unit;
  const bw = (W - P.l - P.r) / buckets.length;
  const y = v => P.t + (H - P.t - P.b) * (1 - v / max);
  let grid = '';
  for (let v = 0; v <= max; v += step) grid += `<line x1="${P.l}" y1="${y(v)}" x2="${W - P.r}" y2="${y(v)}" stroke="var(--line)"/>
    <text x="${P.l - 6}" y="${y(v) + 4}" fill="var(--slate)" font-size="10" font-family="IBM Plex Mono" text-anchor="end">${v}h</text>`;
  // the page's own range, shaded, in whichever grain is drawn
  const rFrom = bucketOf(mondayOf(rangeFrom)), rTo = bucketOf(mondayOf(endOfMonth(rangeTo)));
  const bi = buckets.findIndex(k => k >= rFrom), bj = buckets.findIndex(k => k > rTo);
  const b0 = bi < 0 ? buckets.length : bi, b1 = bj < 0 ? buckets.length : bj;
  const band = b1 > b0 ? `<rect x="${P.l + b0 * bw}" y="${P.t}" width="${(b1 - b0) * bw}" height="${H - P.t - P.b}" fill="var(--mint)" opacity=".7"/>` : '';
  const bars = buckets.map((_, i) => { let acc = 0; return series.map(sr => {
    const v = sr.values[i]; if (!v) return '';
    const y1 = y(acc + v), h = Math.max(y(acc) - y1 - 1, 0); acc += v;   // 1px gap between stacked fills
    return `<rect x="${P.l + i * bw + bw * .15}" y="${y1}" width="${bw * .7}" height="${h}" fill="${sr.color}"/>`; }).join(''); }).join('');
  const fmtBucket = k => monthly ? fmtMonYY(k) : fmtDayMon(k);
  const every = Math.max(1, Math.ceil(buckets.length / 9));
  const xl = buckets.map((k, i) => i % every ? '' :
    `<text x="${P.l + i * bw + bw / 2}" y="${H - 8}" fill="var(--slate)" font-size="10" font-family="IBM Plex Mono" text-anchor="middle">${fmtBucket(k)}</text>`).join('');
  const cols = buckets.map((k, i) => `<rect class="hit" data-i="${i}" x="${P.l + i * bw}" y="${P.t}" width="${bw}" height="${H - P.t - P.b}" fill="transparent" tabindex="0" role="img" aria-label="${esc(`${monthly ? '' : 'week of '}${fmtBucket(k)}: ${fmtHours(totals[i])}h`)}"/>`).join('');
  const legend = series.map(sr => `<span class="lg-item"><i class="lg-dot" style="background:${sr.color}"></i>${esc(sr.name)}</span>`).join('')
    + `<span class="lg-item"><i class="lg-dot" style="background:var(--mint);border:1px solid var(--line)"></i>selected range</span>`
    + `<span class="lg-item" style="color:var(--slate)">${monthly ? 'by month' : 'by week'}</span>`;
  el.style.position = 'relative';
  el.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Hours logged per ${monthly ? 'month' : 'week'} by ${byDeal ? 'project' : 'department'}">${band}${grid}${bars}<g class="hover"></g>${xl}${cols}</svg>
    <div class="chart-tip"></div><div class="chart-legend">${legend}</div>`;
  wireChartTip(el,
    i => `<div class="tip-label">${monthly ? '' : 'wk of '}${esc(fmtBucket(buckets[i]))} · ${fmtHours(totals[i])}h</div>` +
      series.filter(sr => sr.values[i]).map(sr => sr.key === OTHER
        // the fold, itemised: each small project/department on its own line
        ? foldedKeys.filter(k => folded[k][i]).map(k => `<div class="tip-row"><span class="tip-dot" style="background:${OTHER_COLOR}"></span>${esc(label(k))} <b>${fmtHours(folded[k][i])}h</b></div>`).join('')
        : `<div class="tip-row"><span class="tip-dot" style="background:${sr.color}"></span>${esc(sr.name)} <b>${fmtHours(sr.values[i])}h</b></div>`).join(''),
    i => { const x = P.l + i * bw + bw / 2; return `<line x1="${x}" y1="${P.t}" x2="${x}" y2="${H - P.b}" stroke="var(--slate)" stroke-dasharray="2 3"/>`; });
}

// ---- revenue & gross profit, actual vs plan, by month ------------------------
// Two hues carry the measure (revenue = --brand, GP = --brand-4); line style
// carries plan vs actual (plan dashed and lighter — DESIGN.md's measured-vs-
// forecast rule). The actual line ends at the last fully-closed month; the
// plan runs the whole window.
export function revGpChart(el, detail, opts = {}) {
  // r:28 leaves room for the last month's centred label (10px clipped "Dec 2")
  const W = 940, H = opts.height || 190, P = { l: 48, r: 28, t: 14, b: 24 };
  // a closed month with nothing invoiced is measured $0, not unknown — 090
  // returns 0 there, and this keeps a pre-090 payload from breaking the line
  const through = detail.measured_through || '';
  const meas = (m, v) => v !== null && v !== undefined ? +v : (through && m.month <= through ? 0 : null);
  let months = (detail.months || []).map(m => ({ ...m,
    rev_actual: meas(m, m.rev_actual), gp_actual: meas(m, m.gp_actual),
    rev_plan: +(m.rev_plan || 0), gp_plan: +(m.gp_plan || 0) }));
  // the window is where the information is: a month carries information when
  // any of the four series is non-zero. Leading and trailing empty months are
  // trimmed; a $0 month stays only between two months that have something —
  // that gap IS information (nothing invoiced), a year of nothing before the
  // first invoice is not.
  const informative = m => m.rev_actual || m.gp_actual || m.rev_plan || m.gp_plan;
  let lo = months.findIndex(informative), hi = months.length - 1;
  while (hi > lo && !informative(months[hi])) hi--;
  months = lo < 0 ? [] : months.slice(lo, hi + 1);
  if (!months.length) {
    const noProj = detail.deal && !detail.deal.qbo_project_id;
    el.innerHTML = `<div class="empty-note" style="padding:28px 14px">${noProj ? 'No QB project claimed and no plan — nothing to measure.' : 'No plan or invoices here yet.'}</div>`; return;
  }
  const n = months.length;
  const SERIES = [
    { key: 'rev_plan',   name: 'revenue plan', color: 'var(--brand)',   plan: true },
    { key: 'rev_actual', name: 'revenue',      color: 'var(--brand)',   plan: false },
    { key: 'gp_plan',    name: 'GP plan',      color: 'var(--brand-4)', plan: true },
    { key: 'gp_actual',  name: 'gross profit', color: 'var(--brand-4)', plan: false },
  ];
  const all = SERIES.flatMap(s => months.map(m => m[s.key])).filter(v => v !== null && v !== undefined);
  const rawMax = Math.max(0, ...all), rawMin = Math.min(0, ...all);
  // gridline step: the smallest of these that keeps the axis under ~7 lines
  const STEPS = [100000, 250000, 500000, 1000000, 2500000, 5000000, 10000000, 25000000, 50000000, 100000000];
  const step = STEPS.find(s => (rawMax - rawMin) / s <= 7) || STEPS[STEPS.length - 1];
  // headroom: the highest point must sit clear of the frame, never on the top
  // gridline — if the snapped bound leaves it less than a fifth of a step of
  // air, add one more gridline (and the same below zero on the negative side)
  let max = Math.max(Math.ceil(rawMax / step) * step, step), min = Math.floor(rawMin / step) * step;
  if (max - rawMax < step * 0.2) max += step;
  if (rawMin < 0 && rawMin - min < step * 0.2) min -= step;
  const x = i => P.l + (W - P.l - P.r) * (n === 1 ? .5 : i / (n - 1));
  const y = v => P.t + (H - P.t - P.b) * (1 - (v - min) / (max - min));
  let grid = '';
  for (let v = min; v <= max; v += step) grid += `<line x1="${P.l}" y1="${y(v)}" x2="${W - P.r}" y2="${y(v)}" stroke="var(--line)"/>
    <text x="${P.l - 6}" y="${y(v) + 4}" fill="var(--slate)" font-size="10" font-family="IBM Plex Mono" text-anchor="end">${fmtK(v)}</text>`;
  const zero = (min < 0 && max > 0) ? `<line x1="${P.l}" y1="${y(0)}" x2="${W - P.r}" y2="${y(0)}" stroke="var(--rust)" stroke-dasharray="4 3"/>` : '';
  // a polyline over the non-null points of a series, in month order
  const path = key => { let d = '', pen = false;
    months.forEach((m, i) => { const v = m[key]; if (v === null || v === undefined) { pen = false; return; }
      d += `${pen ? 'L' : 'M'}${x(i)},${y(v)} `; pen = true; }); return d; };
  const lines = SERIES.map(s => s.plan
    ? `<path fill="none" stroke="${s.color}" stroke-width="2" stroke-dasharray="5 4" opacity=".6" d="${path(s.key)}"/>`
    : `<path fill="none" stroke="${s.color}" stroke-width="2" d="${path(s.key)}"/>` +
      months.map((m, i) => m[s.key] === null ? '' : `<circle cx="${x(i)}" cy="${y(m[s.key])}" r="3.5" fill="${s.color}" stroke="var(--paper-raised)" stroke-width="2"/>`).join('')
  ).join('');
  // "today": between the last measured month and the first unmeasured one
  const lastMeasured = months.reduce((k, m, i) => m.rev_actual !== null ? i : k, -1);
  let todayLine = '';
  if (lastMeasured >= 0 && lastMeasured < n - 1) {
    const tx = x(lastMeasured) + (x(lastMeasured + 1) - x(lastMeasured)) * (new Date().getUTCDate() / 31);
    todayLine = `<line x1="${tx}" y1="${P.t}" x2="${tx}" y2="${H - P.b}" stroke="var(--slate)" stroke-dasharray="3 3"/>
      <text x="${tx + 4}" y="${P.t + 10}" fill="var(--slate)" font-size="9" font-family="IBM Plex Mono">today</text>`;
  }
  const every = Math.max(1, Math.ceil(n / 12));
  const xl = months.map((m, i) => i % every ? '' : `<text x="${x(i)}" y="${H - 8}" fill="var(--slate)" font-size="10" font-family="IBM Plex Mono" text-anchor="middle">${fmtMonYY(m.month)}</text>`).join('');
  const stepX = n > 1 ? (W - P.l - P.r) / (n - 1) : (W - P.l - P.r);
  const cols = months.map((m, i) => { const l = Math.max(P.l, x(i) - stepX / 2), r = Math.min(W - P.r, x(i) + stepX / 2);
    return `<rect class="hit" data-i="${i}" x="${l}" y="${P.t}" width="${r - l}" height="${H - P.t - P.b}" fill="transparent" tabindex="0" role="img" aria-label="${esc(`${fmtMonYY(m.month)}: revenue ${m.rev_actual === null ? 'forecast' : fmt$0(m.rev_actual)} vs ${fmt$0(m.rev_plan)} plan`)}"/>`; }).join('');
  const legend = SERIES.map(s => s.plan
    ? `<span class="lg-item" style="color:var(--slate)"><i class="lg-dash" style="color:${s.color}"></i>${esc(s.name)}</span>`
    : `<span class="lg-item"><i class="lg-dot" style="background:${s.color}"></i>${esc(s.name)}</span>`).join('');
  el.style.position = 'relative';
  el.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Revenue and gross profit, actual vs plan, by month">${grid}${zero}${lines}${todayLine}<g class="hover"></g>${xl}${cols}</svg>
    <div class="chart-tip"></div><div class="chart-legend">${legend}</div>`;
  const delta = (a, p) => (a === null || !p) ? '' :
    `<span style="color:${a - p < 0 ? 'var(--rust)' : 'var(--brand-2)'};margin-left:6px">${a - p < 0 ? '−' : '+'}${Math.abs((a - p) / p * 100).toFixed(1)}%</span>`;
  wireChartTip(el,
    i => { const m = months[i];
      return `<div class="tip-label">${esc(fmtMonYY(m.month))}${m.rev_actual === null ? ' · forecast' : ''}</div>` +
        `<div class="tip-row"><span class="tip-dot" style="background:var(--brand)"></span>revenue <b>${m.rev_actual === null ? '—' : fmt$0(m.rev_actual)}</b> / ${fmt$0(m.rev_plan)} plan${delta(m.rev_actual, m.rev_plan)}</div>` +
        `<div class="tip-row"><span class="tip-dot" style="background:var(--brand-4)"></span>GP <b>${m.gp_actual === null ? '—' : fmt$0(m.gp_actual)}</b> / ${fmt$0(m.gp_plan)} plan${delta(m.gp_actual, m.gp_plan)}</div>`; },
    i => `<line x1="${x(i)}" y1="${P.t}" x2="${x(i)}" y2="${H - P.b}" stroke="var(--slate)" stroke-dasharray="2 3"/>`);
}

// Nearest-period crosshair + tooltip, mouse and keyboard (each .hit rect is
// its own focus stop) — the same pattern shell.js bandChart uses.
function wireChartTip(el, html, cross) {
  const tip = el.querySelector('.chart-tip'), hover = el.querySelector('.hover');
  const show = (i, cx, cy) => { hover.innerHTML = cross(i); tip.innerHTML = html(i); tip.style.opacity = '1';
    const box = el.getBoundingClientRect(); tip.style.top = (cy - box.top - 10) + 'px';
    tip.style.left = Math.min(box.width - tip.offsetWidth, Math.max(0, cx - box.left + 12)) + 'px'; };
  const hide = () => { tip.style.opacity = '0'; hover.innerHTML = ''; };
  el.querySelectorAll('.hit').forEach(r => {
    r.onmousemove = e => show(+r.dataset.i, e.clientX, e.clientY);
    r.onfocus = () => { const b = r.getBoundingClientRect(); show(+r.dataset.i, b.left + b.width / 2, b.top); };
    r.onblur = hide; });
  el.querySelector('svg').onmouseleave = hide;
}

// The one-line stat beside each chart's eyebrow: the number the chart is
// about, so a reader gets it without hovering.
export function hoursStat(detail, rangeFrom, rangeTo) {
  const rFrom = mondayOf(rangeFrom), rTo = mondayOf(endOfMonth(rangeTo));
  const byWeek = {};
  (detail.weeks || []).forEach(r => byWeek[r.week] = (byWeek[r.week] || 0) + +r.hours);
  const inRange = Object.entries(byWeek).filter(([w]) => w >= rFrom && w <= rTo);
  if (!inRange.length) return '';
  const total = inRange.reduce((s, [, h]) => s + h, 0);
  const peak = inRange.slice().sort((a, b) => b[1] - a[1])[0];
  return `<span>avg <b>${fmtHours(total / inRange.length)}h</b> / wk in range</span><span>peak <b>${fmtHours(peak[1])}h</b> wk of ${esc(fmtDayMon(peak[0]))}</span>`;
}
export function revStat(detail) {
  const through = detail.measured_through || '';
  const measured = (detail.months || []).filter(m => (m.rev_actual !== null && m.rev_actual !== undefined) || (through && m.month <= through));
  if (!measured.length) return '';
  const sum = k => measured.reduce((s, m) => s + +(m[k] || 0), 0);
  const pct = (a, p) => p ? `<span class="delta-note ${a - p < 0 ? 'neg' : 'pos'}" style="display:inline">${a - p < 0 ? '−' : '+'}${Math.abs((a - p) / p * 100).toFixed(1)}%</span>` : '';
  const ra = sum('rev_actual'), rp = sum('rev_plan'), ga = sum('gp_actual'), gp = sum('gp_plan');
  return `<span>rev to date <b>${fmt$0(ra)}</b> vs <b>${fmt$0(rp)}</b> ${pct(ra, rp)}</span><span>GP to date <b>${fmt$0(ga)}</b> vs <b>${fmt$0(gp)}</b> ${pct(ga, gp)}</span>`;
}
