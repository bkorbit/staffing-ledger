// The Scoping verdict chart: revenue, gross profit and labor per flight month
// as grouped bars, profit after labor (GP − rebate − labor) as the gold line —
// the same gold the Forecast's NET line and the detail charts' PAL line use,
// the one number the page is about. Draws from scope_verdict.months (db/097).
//
// Deliberately does NOT import shell.js (a second module instance would be a
// second Supabase client — see detail-charts.js). Axis snapping, tooltip and
// crosshair follow detail-charts.js revGpChart so the two read as one system.

const esc = s => String(s ?? '').replace(/[&<>"']/g,
  c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
const fmt$0 = c => (c < 0 ? '-$' : '$') + Math.abs(Math.round((c || 0) / 100)).toLocaleString();
const fmtK = c => { const d = c / 100, a = Math.abs(d), sign = d < 0 ? '-' : '';
  if (a >= 1e6) return `${sign}$${(a / 1e6).toFixed(1)}MM`;
  if (a >= 1e3) return `${sign}$${Math.round(a / 1e3)}k`;
  return `${sign}$${Math.round(a)}`; };
const fmtMonYY = s => new Date(s + 'T00:00:00Z')
  .toLocaleDateString(undefined, { month: 'short', year: '2-digit', timeZone: 'UTC' });
const fmtH = h => (+h || 0).toLocaleString(undefined, { maximumFractionDigits: 1 }) + 'h';

export const STATUS_LABEL = { go: 'Go', go_with_hire: 'Go with a hire', go_with_contractor: 'Go with a contractor', no_go: 'No-go', unclear: 'Unclear' };
export const STATUS_PILL = { go: 'good', go_with_hire: 'warn', go_with_contractor: 'warn', no_go: 'bad', unclear: '' };

// months: [{ month, billable, gp, rebate, labor, pal }]
export function scopeChart(el, months, opts = {}) {
  const rows = (months || []).slice().sort((a, b) => a.month.localeCompare(b.month));
  if (!rows.length) { el.innerHTML = `<div class="empty-note" style="padding:28px 14px">${esc(opts.empty || 'Add a deal with flight dates and at least one line.')}</div>`; return; }
  const W = 940, H = opts.height || 200, P = { l: 52, r: 28, t: 14, b: 24 };
  const n = rows.length;
  const BARS = [
    { key: 'billable', name: 'revenue', color: 'var(--brand)' },
    { key: 'gp',       name: 'gross profit', color: 'var(--brand-4)' },
    { key: 'labor',    name: 'labor', color: 'var(--slate)' },
  ];
  const all = [...BARS.flatMap(s => rows.map(r => +r[s.key] || 0)), ...rows.map(r => +r.pal || 0)];
  const rawMax = Math.max(0, ...all), rawMin = Math.min(0, ...all);
  const STEPS = [10000, 25000, 50000, 100000, 250000, 500000, 1000000, 2500000, 5000000, 10000000, 25000000, 50000000, 100000000];
  const step = STEPS.find(s => (rawMax - rawMin) / s <= 7) || STEPS[STEPS.length - 1];
  let max = Math.max(Math.ceil(rawMax / step) * step, step), min = Math.floor(rawMin / step) * step;
  if (max - rawMax < step * 0.2) max += step;
  if (rawMin < 0 && rawMin - min < step * 0.2) min -= step;
  const slot = (W - P.l - P.r) / n;
  const xc = i => P.l + slot * (i + 0.5);
  const y = v => P.t + (H - P.t - P.b) * (1 - (v - min) / (max - min));
  let grid = '';
  for (let v = min; v <= max; v += step) grid += `<line x1="${P.l}" y1="${y(v)}" x2="${W - P.r}" y2="${y(v)}" stroke="var(--line)"/>
    <text x="${P.l - 6}" y="${y(v) + 4}" fill="var(--slate)" font-size="10" font-family="IBM Plex Mono" text-anchor="end">${fmtK(v)}</text>`;
  const zero = (min < 0 && max > 0) ? `<line x1="${P.l}" y1="${y(0)}" x2="${W - P.r}" y2="${y(0)}" stroke="var(--rust)" stroke-dasharray="4 3"/>` : '';
  const bw = Math.max(4, Math.min(22, slot * 0.7 / BARS.length));
  const bars = rows.map((r, i) => BARS.map((s, k) => {
    const v = +r[s.key] || 0, x0 = xc(i) - bw * BARS.length / 2 + k * bw;
    const top = y(Math.max(v, 0)), bot = y(Math.min(v, 0));
    return `<rect x="${x0 + 1}" y="${top}" width="${bw - 2}" height="${Math.max(bot - top, 0)}" fill="${s.color}" opacity=".9"/>`;
  }).join('')).join('');
  const palPath = rows.map((r, i) => `${i ? 'L' : 'M'}${xc(i)},${y(+r.pal || 0)}`).join(' ');
  const palDots = rows.map((r, i) => `<circle cx="${xc(i)}" cy="${y(+r.pal || 0)}" r="3.5" fill="var(--gold)" stroke="var(--paper-raised)" stroke-width="2"/>`).join('');
  const every = Math.max(1, Math.ceil(n / 12));
  const xl = rows.map((r, i) => i % every ? '' : `<text x="${xc(i)}" y="${H - 8}" fill="var(--slate)" font-size="10" font-family="IBM Plex Mono" text-anchor="middle">${fmtMonYY(r.month)}</text>`).join('');
  const cols = rows.map((r, i) => `<rect class="hit" data-i="${i}" x="${xc(i) - slot / 2}" y="${P.t}" width="${slot}" height="${H - P.t - P.b}" fill="transparent" tabindex="0" role="img" aria-label="${esc(`${fmtMonYY(r.month)}: revenue ${fmt$0(r.billable)}, GP ${fmt$0(r.gp)}, labor ${fmt$0(r.labor)}, after labor ${fmt$0(r.pal)}`)}"/>`).join('');
  const legend = BARS.map(s => `<span class="lg-item"><i class="lg-dot" style="background:${s.color}"></i><span class="lg-txt">${esc(s.name)}</span></span>`).join('')
    + `<span class="lg-item"><i class="lg-dot" style="background:var(--gold)"></i><span class="lg-txt">profit after labor</span></span>`;
  el.style.position = 'relative';
  el.innerHTML = `<svg class="chart" viewBox="0 0 ${W} ${H}" role="img" aria-label="Revenue, gross profit, labor and profit after labor per flight month">${grid}${zero}${bars}<path fill="none" stroke="var(--gold)" stroke-width="2.5" d="${palPath}"/>${palDots}<g class="hover"></g>${xl}${cols}</svg>
    <div class="chart-tip"></div><div class="chart-legend one-line">${legend}</div>`;
  wireChartTip(el,
    i => { const r = rows[i];
      return `<div class="tip-label">${esc(fmtMonYY(r.month))}</div>` +
        `<div class="tip-row"><span class="tip-dot" style="background:var(--brand)"></span>revenue <b>${fmt$0(r.billable)}</b></div>` +
        `<div class="tip-row"><span class="tip-dot" style="background:var(--brand-4)"></span>GP <b>${fmt$0(r.gp)}</b>${+r.rebate ? ` · rebate −${fmt$0(r.rebate)}` : ''}</div>` +
        `<div class="tip-row"><span class="tip-dot" style="background:var(--slate)"></span>labor <b>${fmt$0(r.labor)}</b> · ${fmtH(r.hours)}</div>` +
        `<div class="tip-row"><span class="tip-dot" style="background:var(--gold)"></span>after labor <b>${fmt$0(r.pal)}</b>${r.per_hour_c != null ? ` · ${fmt$0(r.per_hour_c)}/h` : ''}</div>`; },
    i => `<line x1="${xc(i)}" y1="${P.t}" x2="${xc(i)}" y2="${H - P.b}" stroke="var(--slate)" stroke-dasharray="2 3"/>`);
}

// One pill per month: good when pal ≥ 0 and per-hour ≥ target, warn when
// positive but under target, bad when the month loses money.
export function verdictStrip(el, months, targetPerHourC) {
  const rows = (months || []).slice().sort((a, b) => a.month.localeCompare(b.month));
  el.innerHTML = rows.map(r => {
    const cls = r.pal < 0 ? 'bad' : (r.per_hour_c != null && r.per_hour_c < targetPerHourC) ? 'warn' : 'good';
    // the word carries the verdict too — color alone is not a signal everyone gets
    const why = cls === 'bad' ? 'loss' : cls === 'warn' ? 'under target' : '';
    const say = `${fmtMonYY(r.month)}: ${cls === 'bad' ? 'loses money' : cls === 'warn' ? 'profitable but under the per-hour target' : 'clears both checks'}, after labor ${fmt$0(r.pal)}${r.per_hour_c != null ? `, ${fmt$0(r.per_hour_c)}/h` : ''}`;
    return `<span class="pill ${cls}" title="${esc(say)}" aria-label="${esc(say)}">${esc(fmtMonYY(r.month))}${why ? ` <span class="why">· ${why}</span>` : ''}</span>`;
  }).join('');
}

// The one-line stat beside the eyebrow.
export function scopeStat(total, targetPerHourC) {
  if (!total || !(+total.hours > 0)) return '';
  const under = total.per_hour_c != null && total.per_hour_c < targetPerHourC;
  return `<span>after labor <b>${fmt$0(total.pal)}</b></span><span>${fmt$0(total.per_hour_c)}/h ${under ? `<span class="delta-note neg" style="display:inline">under ${fmt$0(targetPerHourC)}</span>` : `<span class="delta-note pos" style="display:inline">target ${fmt$0(targetPerHourC)}</span>`}</span><span>${fmtH(total.hours)}</span>`;
}

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
