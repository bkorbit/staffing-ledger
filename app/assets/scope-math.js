// Scope money math — the JS twin of the SQL primitives in db/096 (line_fee,
// line_rebate, prog_suggest_margin) and of scope_months in db/097, which is
// itself the twin of v_deal_month_forecast. ONE copy in the browser: the
// Scoping editor imports it for live totals, and (from 099) the Forecast
// editor's gpMonth / revMonth route their media kinds through lineFee so a
// promoted tiered line shows the same cents on both pages.
//
// Contract with SQL, digit for digit:
//  * every money input and output is INTEGER CENTS; percentages are plain
//    numbers (12.5 = 12.5 %) with at most 3 decimals (numeric(6,3));
//  * lineFee / lineRebate return UNROUNDED values, as the SQL does; callers
//    round ONCE per figure with Math.round, which equals Postgres round()
//    (half away from zero) for the non-negative values money here takes;
//  * arithmetic inside lineFee is done on integers before a single division
//    (pct as thousandths), so a 12.5 % fee on 12345 c is exactly 1543.125 in
//    both places rather than 1543.1249999.
//
// Tested by scripts/test/scope-math.test.mjs on the same numbers as
// db/097_fixture_test.sql. Must NOT import shell.js (second Supabase client).

const milli = pct => Math.round((+pct || 0) * 1000);          // 12.5 -> 12500
const bandsOf = st => (st && st.fee && Array.isArray(st.fee.bands)) ? st.fee.bands : [];
const upto = b => (b.upto === null || b.upto === undefined || b.upto === '') ? null : +b.upto;

// The fee on ONE month's media spend. structure = deal_lines/scope_lines.structure.
export function lineFee(budgetC, feePct, structure) {
  const b = Math.max(0, Math.round(+budgetC || 0));
  const st = structure || {};
  const mode = (st.fee && st.fee.mode) || 'flat';
  let fee;
  if (mode === 'marginal') {
    let acc = 0, lo = 0;                                       // acc in cents × thousandths-of-a-percent
    for (const band of bandsOf(st)) {
      const top = upto(band) === null ? b : Math.min(upto(band), b);
      const slice = Math.max(top - lo, 0);
      acc += slice * milli(band.pct);
      lo = Math.max(lo, upto(band) === null ? b : upto(band));
    }
    fee = acc / 100000;
  } else if (mode === 'whole') {
    let lo = 0, hit = null;
    for (const band of bandsOf(st)) {
      const u = upto(band);
      if (b > lo && (u === null || b <= u)) { hit = band; break; }   // boundary inclusive, like SQL
      lo = u === null ? lo : u;
    }
    fee = hit ? b * milli(hit.pct) / 100000 : 0;
  } else {
    fee = b * milli(feePct) / 100000;
  }
  const min = st.fee_min === null || st.fee_min === undefined || st.fee_min === '' ? null : +st.fee_min;
  const cap = st.fee_cap === null || st.fee_cap === undefined || st.fee_cap === '' ? null : +st.fee_cap;
  if (min !== null && !isNaN(min)) fee = Math.max(fee, min);
  if (cap !== null && !isNaN(cap)) fee = Math.min(fee, cap);
  return fee;
}

// Rebate paid back to the client (COGS, reduces GP, never billable), unrounded.
export function lineRebate(budgetC, feeC, pct, basis) {
  const p = milli(pct);
  if (!p) return 0;
  if ((basis || 'media') === 'media') return Math.max(0, Math.round(+budgetC || 0)) * p / 100000;
  if (basis === 'fee') return (+feeC || 0) * p / 100000;
  return 0;
}

// Backend margin % so GP / revenue ≥ target: target × (100 + fee) / 100 − fee, floored at 0, 3 dp.
export function progSuggestMargin(feePct, targetGpPct) {
  const m = (+targetGpPct || 0) * (100 + (+feePct || 0)) / 100 - (+feePct || 0);
  return Math.round(Math.max(m, 0) * 1000) / 1000;
}

// The month's effective margin for a programmatic line: model A = its own
// margin (or the default); model B (CPM) = 100 − platform share, fee 0.
export function progParams(line, ctx) {
  const st = line.structure || {};
  if (st.prog && st.prog.model === 'cpm') {
    const share = st.prog.platform_share_pct === undefined || st.prog.platform_share_pct === null || st.prog.platform_share_pct === ''
      ? +(ctx.cpmShareDefault ?? 50) : +st.prog.platform_share_pct;
    return { marginPct: 100 - share, feePct: 0, cpm: true };
  }
  return { marginPct: line.margin_pct === null || line.margin_pct === undefined || line.margin_pct === '' ? +(ctx.marginDefault ?? 35) : +line.margin_pct,
           feePct: +line.fee_pct || 0, cpm: false };
}

const isHourlyCreative = l => l.kind === 'creative' && String(l.label || '').startsWith('creative:hourly');

// ONE line, ONE month → { fee, gp, billable, pass, rebate } in integer cents.
// line: { kind, label, amount, budget, fee_pct, margin_pct, rate, hours_per_month,
//         media_funding, structure, months: { 'YYYY-MM-01': { budget, amount, hours } } }
// Mirrors scope_months (097) / v_deal_month_forecast (087, 099) case for case.
export function lineMonth(line, m, ctx = {}) {
  const cell = (line.months && line.months[m]) || {};
  const num = (v, d) => (v === null || v === undefined || v === '') ? d : +v;
  const amount = Math.round(num(cell.amount, num(line.amount, 0)));
  const budget = Math.round(num(cell.budget, num(line.budget, 0)));
  const hours = num(cell.hours, num(line.hours_per_month, 0));
  const rate = Math.round(num(line.rate, 0));
  const st = line.structure || {};
  const rebPct = st.rebate ? st.rebate.pct : 0, rebBasis = st.rebate ? st.rebate.basis : 'media';
  let gpN, feeRaw = 0, billable;
  switch (line.kind) {
    case 'retainer': case 'custom':
      gpN = amount; billable = amount; break;
    case 'creative':
      gpN = isHourlyCreative(line) ? Math.round(rate * hours) : amount; billable = gpN; break;
    case 'hourly':
      gpN = Math.round(rate * hours); billable = gpN; break;
    case 'search': case 'social':
      feeRaw = lineFee(budget, line.fee_pct, st);
      gpN = Math.round(feeRaw); billable = gpN; break;
    case 'programmatic': {
      const p = progParams(line, ctx);
      feeRaw = lineFee(budget, p.feePct, st);
      gpN = Math.round(budget * p.marginPct / 100 + feeRaw);
      billable = budget + Math.round(feeRaw); break;
    }
    default:
      gpN = 0; billable = 0;
  }
  const media = line.kind === 'search' || line.kind === 'social' || line.kind === 'programmatic';
  const fee = media ? Math.round(feeRaw) : gpN;
  const pass = (line.kind === 'search' || line.kind === 'social') && line.media_funding === 'agency' ? budget : 0;
  const rebate = Math.round(lineRebate(budget, media ? feeRaw : gpN, rebPct, rebBasis));
  return { fee, gp: gpN, billable, pass, rebate, budget, amount, hours };
}

// Sum lineMonth over all lines of all deals for each month → [{ month, gp, billable, pass, rebate }].
export function scopeMonths(deals, ctx = {}) {
  const out = new Map();
  for (const d of deals || []) {
    if (!d.flight_start || !d.flight_end) continue;
    for (const m of monthsBetween(d.flight_start, d.flight_end)) {
      for (const l of d.lines || []) {
        const r = lineMonth(l, m, ctx);
        const t = out.get(m) || { month: m, gp: 0, billable: 0, pass: 0, rebate: 0, fee: 0 };
        t.gp += r.gp; t.billable += r.billable; t.pass += r.pass; t.rebate += r.rebate; t.fee += r.fee;
        out.set(m, t);
      }
    }
  }
  return [...out.values()].sort((a, b) => a.month.localeCompare(b.month));
}

// ---- calendar helpers (copied from forecast.html so the spread is identical) ----
export const shiftM = (m, n) => {
  const [y, mm] = m.slice(0, 7).split('-').map(Number);
  return new Date(Date.UTC(y, mm - 1 + n, 1)).toISOString().slice(0, 10);
};
export function monthsBetween(start, end) {
  const out = [];
  if (!start || !end) return out;
  for (let m = start.slice(0, 7) + '-01'; m <= end.slice(0, 7) + '-01'; m = shiftM(m, 1)) out.push(m);
  return out;
}
export const daysInMonth = m => new Date(Date.UTC(+m.slice(0, 4), +m.slice(5, 7), 0)).getUTCDate();
// covered-day fraction of month m within the flight — 1 for a fully covered month (forecast.html dayFrac)
export function dayFrac(m, flight) {
  if (!flight || !flight.start || !flight.end) return 1;
  const dim = daysInMonth(m);
  const monthStart = m, monthEnd = m.slice(0, 8) + String(dim).padStart(2, '0');
  const s = flight.start > monthStart ? flight.start : monthStart;
  const e = flight.end < monthEnd ? flight.end : monthEnd;
  const covered = Math.round((new Date(e + 'T00:00:00Z') - new Date(s + 'T00:00:00Z')) / 864e5) + 1;
  return covered >= dim ? 1 : covered / dim;
}
// Spread a total (cents or hours) over months: media budgets by covered days,
// everything else evenly; remainder on the LAST month so the typed total is
// preserved exactly (forecast.html's totalbudget rule).
export function spreadTotal(total, months, { weighted = false, flight = null, decimals = 0 } = {}) {
  const out = {};
  if (!(total > 0) || !months.length) return out;
  const w = months.map(m => weighted ? dayFrac(m, flight) * daysInMonth(m) : 1);
  const wSum = w.reduce((a, b) => a + b, 0);
  const f = Math.pow(10, decimals);
  let acc = 0;
  months.forEach((m, i) => {
    const v = i === months.length - 1 ? Math.round((total - acc) * f) / f : Math.round(total * w[i] / wSum * f) / f;
    out[m] = v; acc += v;
  });
  return out;
}

// Verdict status from totals (mirrors scope_verdict's status CASE; labor and
// capacity come from the server — this is only for the live preview while typing).
export function verdictStatus({ pal, hours, unpriced = 0, targetPerHourC }) {
  if (!(hours > 0) || unpriced > 0) return 'unclear';
  if (pal < 0) return 'no_go';
  return Math.round(pal / hours) >= targetPerHourC ? 'go' : 'no_go';
}

export const fmtPct = p => (p === null || p === undefined || p === '') ? '' : String(+(+p).toFixed(3));
