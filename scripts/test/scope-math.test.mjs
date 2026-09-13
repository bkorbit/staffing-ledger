// The JS twin of db/096's line_fee / line_rebate / prog_suggest_margin and
// db/097's scope_months, run on the SAME numbers as db/097_fixture_test.sql
// (rows 1 and 2). If a case here and the SQL fixture disagree, one of the
// twins drifted. Run: node scripts/test/scope-math.test.mjs
import { lineFee, lineRebate, progSuggestMargin, lineMonth, scopeMonths, spreadTotal, monthsBetween } from '../../app/assets/scope-math.js';

let pass = 0, fail = 0;
const eq = (a, b, n) => { const A = JSON.stringify(a), B = JSON.stringify(b);
  if (A === B) pass++; else { fail++; console.log(`  FAIL ${n}\n    got ${A}\n    want ${B}`); } };

const bands = [{ upto: 5000000, pct: 15 }, { upto: 15000000, pct: 12 }, { upto: null, pct: 10 }];
const marginal = { fee: { mode: 'marginal', bands } };
const whole = { fee: { mode: 'whole', bands } };

console.log('lineFee — 097 fixture row 1');
eq(lineFee(5000000, 0, marginal), 750000, 'marginal at exactly $50k = 15%');
eq(lineFee(12000000, 0, marginal), 1590000, 'marginal $120k = 7,500 + 8,400');
eq(lineFee(5000000, 0, whole), 750000, 'whole at exactly $50k stays in the 15% band (inclusive)');
eq(lineFee(5000001, 0, whole), 600000.12, 'whole one cent over → 12% of all of it');
eq(lineFee(2000000, 0, { fee: { mode: 'marginal', bands: [{ upto: 5000000, pct: 15 }, { upto: null, pct: 10 }] }, fee_min: 500000 }), 500000, 'min fee floors a $3,000 raw fee to $5,000');
eq(lineFee(20000000, 0, { fee: { mode: 'marginal', bands: [{ upto: 5000000, pct: 15 }, { upto: null, pct: 10 }] }, fee_min: 500000, fee_cap: 2000000 }), 2000000, 'cap wins');
eq(lineFee(12345, 12.5, {}), 1543.125, 'flat half-cent exact (integer arithmetic)');
eq(Math.round(lineFee(12345, 10, {})), 1235, 'flat 1234.5 rounds half away from zero like SQL');
eq(Math.round(lineFee(12345, 12.5, null)), Math.round(12345 * 12.5 / 100), 'flat equals the pre-096 forecast math');
eq(lineFee(0, 0, { fee: { mode: 'whole', bands }, fee_min: 250000 }), 250000, 'min applies at zero spend');
eq(lineFee(0, 0, whole), 0, 'whole at zero spend with no min = 0');

console.log('lineRebate / progSuggestMargin');
eq(lineRebate(10000000, 500000, 2, 'media'), 200000, '2% of media');
eq(lineRebate(12000000, 1440000, 2, 'fee'), 28800, '2% of fee');
eq(lineRebate(12000000, 1440000, 0, 'fee'), 0, 'no pct = 0');
eq(progSuggestMargin(5, 40), 37, '40% GP on revenue with a 5% fee → 37% backend');
eq(progSuggestMargin(50, 40), 10, '40 × 150 / 100 − 50 = 10');
eq(progSuggestMargin(80, 40), 0, 'floored at 0');

console.log('lineMonth — 097 fixture row 2');
const n0 = '2026-09-01', n1 = '2026-10-01';
const search = { kind: 'search', fee_pct: 0, media_funding: 'client', structure: { ...marginal, fee_min: 500000 },
  months: { [n0]: { budget: 12000000 }, [n1]: { budget: 2000000 } } };
eq(lineMonth(search, n0), { fee: 1590000, gp: 1590000, billable: 1590000, pass: 0, rebate: 0, budget: 12000000, amount: 0, hours: 0 }, 'search n0');
eq(lineMonth(search, n1).gp, 500000, 'search n1 floored');
const social = { kind: 'social', fee_pct: 0, media_funding: 'agency', structure: { ...whole, rebate: { pct: 2, basis: 'fee' } },
  months: { [n0]: { budget: 12000000 }, [n1]: { budget: 5000000 } } };
eq(lineMonth(social, n0), { fee: 1440000, gp: 1440000, billable: 1440000, pass: 12000000, rebate: 28800, budget: 12000000, amount: 0, hours: 0 }, 'social n0: agency-funded → pass, fee-basis rebate');
eq([lineMonth(social, n1).gp, lineMonth(social, n1).rebate], [750000, 15000], 'social n1 at the boundary');
const prog = { kind: 'programmatic', fee_pct: 5, margin_pct: 30, budget: 10000000, structure: { prog: { model: 'fee_margin' }, rebate: { pct: 2, basis: 'media' } }, months: {} };
eq([lineMonth(prog, n0).gp, lineMonth(prog, n0).billable, lineMonth(prog, n0).rebate], [3500000, 10500000, 200000], 'programmatic fee+margin with media rebate');
const cpm = { kind: 'programmatic', fee_pct: 9, margin_pct: 12, budget: 1000000, structure: { prog: { model: 'cpm', platform_share_pct: 50 } }, months: {} };
eq([lineMonth(cpm, n0).gp, lineMonth(cpm, n0).billable, lineMonth(cpm, n0).rebate], [500000, 1000000, 0], 'CPM: margin-only, fee ignored');
eq(lineMonth({ kind: 'hourly', rate: 20000, hours_per_month: 40, months: {} }, n0).gp, 800000, 'hourly 40 × $200');
eq(lineMonth({ kind: 'retainer', amount: 1000000, months: {} }, n1).gp, 1000000, 'retainer');
eq(lineMonth({ kind: 'creative', label: 'creative:hourly', rate: 15000, hours_per_month: 10, months: {} }, n0).gp, 150000, 'creative:hourly');
eq(lineMonth({ kind: 'creative', label: 'creative:retainer', amount: 250000, months: {} }, n0).gp, 250000, 'creative:retainer');
// the half-cent programmatic case: one rounding point, not two
const half = { kind: 'programmatic', fee_pct: 12.5, margin_pct: 30, budget: 12345, structure: {}, months: {} };
eq(lineMonth(half, n0).gp, Math.round(12345 * 30 / 100 + 12345 * 12.5 / 100), 'programmatic rounds once: round(3703.5 + 1543.125) = 5247');
eq(lineMonth(half, n0).gp, 5247, 'programmatic half-cent exact');

console.log('scopeMonths totals — fixture n0 8,830,000 / n1 rebate 215,000');
const deals = [{ flight_start: '2026-09-01', flight_end: '2026-10-28', lines: [search, social, prog, cpm,
  { kind: 'hourly', label: 'SEO', rate: 20000, hours_per_month: 40, months: {} },
  { kind: 'retainer', amount: 1000000, hours_included: 20, overage_rate: 25000, months: {} }] }];
const tot = scopeMonths(deals, { marginDefault: 35, cpmShareDefault: 50 });
eq(tot.map(t => t.month), [n0, n1], 'two flight months');
eq([tot[0].gp, tot[0].rebate], [8830000, 228800], 'n0 totals');
eq([tot[1].gp, tot[1].rebate], [7050000, 215000], 'n1 totals');

console.log('spreadTotal');
eq(spreadTotal(100, ['2026-09-01', '2026-10-01', '2026-11-01'], { decimals: 2 }), { '2026-09-01': 33.33, '2026-10-01': 33.33, '2026-11-01': 33.34 }, 'even, remainder last');
eq(Object.values(spreadTotal(1000000, monthsBetween('2026-09-15', '2026-10-31'), { weighted: true, flight: { start: '2026-09-15', end: '2026-10-31' } })).reduce((a, b) => a + b, 0), 1000000, 'day-weighted preserves the total');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
