// The benchmark upload parsers (app/assets/parsers/*) and the NNLS model fit
// (scope-math.js fitModel) on synthetic exports shaped like the real ones.
// Run: node scripts/test/scope-parsers.test.mjs
import { parseCSV, parseNum, toMonth } from '../../app/assets/parsers/csv.js';
import { detect, mergeMonths } from '../../app/assets/parsers/index.js';
import { fitModel } from '../../app/assets/scope-math.js';
let pass = 0, fail = 0;
const eq = (a, b, n) => { const A = JSON.stringify(a), B = JSON.stringify(b); if (A === B) pass++; else { fail++; console.log(`  FAIL ${n}\n    got ${A}\n    want ${B}`); } };

eq(parseCSV('a,b\n1,"x, y"\r\n2,"he said ""hi"""\n'), [['a','b'],['1','x, y'],['2','he said "hi"']], 'quotes, CRLF');
eq(parseCSV('﻿a\tb\n1\t2'), [['a','b'],['1','2']], 'BOM + tabs');
eq([parseNum('$1,234.50'), parseNum('(1,234)'), parseNum('12.5%'), parseNum('--'), parseNum('1.234,56')], [1234.5, -1234, 12.5, 0, 1234.56], 'numbers');
eq([toMonth('2026-09-15'), toMonth('9/15/2026'), toMonth('Sep 15, 2026'), toMonth('2026/09/15 13:22'), toMonth('15 Sep 2026'), toMonth('nope')], ['2026-09-01','2026-09-01','2026-09-01','2026-09-01','2026-09-01',null], 'months');

const gads = `Campaign report\nSep 1, 2026 - Sep 30, 2026\nDay,Campaign,Ad group,Ad ID,Cost,Impressions\n2026-09-01,Brand,Core,111,"1,000.00","5,000"\n2026-09-01,Brand,Core,112,0,0\n2026-09-02,NonBrand,Geo,113,250.5,100\n2026-10-01,Brand,Core,111,10,1\nTotal,,,,1260.5,5101`;
const rows = parseCSV(gads); const p = detect(rows, 'google_ads');
eq(p && p.id, 'google-ads-daily@1', 'detects google daily');
const r = p.parse(rows);
eq(r.months['2026-09-01'], { spend: 125050, active_campaigns: 2, ad_groups: 2, ads_live: 2 }, 'sept counts (ad 112 inactive), spend in cents');
eq(r.months['2026-10-01'].active_campaigns, 1, 'oct');

const ch = `Date & time,Campaign,Ad group,Change type,User,Tool\n"Sep 3, 2026 10:00 AM",Brand,Core,Bid,boris@emg.com,Google Ads web\n"Sep 4, 2026 10:00 AM",Brand,Core,Budget,,API\n"Oct 1, 2026 9:00 AM",Brand,Core,Status,anna@emg.com,Rules`;
const rc = parseCSV(ch); const pc = detect(rc, 'google_ads');
eq(pc && pc.id, 'google-ads-changes@1', 'detects change history');
eq(pc.parse(rc, { excludeAutomated: true }).months['2026-09-01'].changes, 1, 'API change dropped');
eq(pc.parse(rc, { excludeAutomated: false }).months['2026-09-01'].changes, 2, 'kept when not excluding');
eq(pc.parse(rc, { excludeAutomated: true }).months['2026-10-01'].changes, 1, 'a named user with a Rules tool still counts');

const meta = `Reporting starts,Reporting ends,Campaign name,Ad set name,Ad name,Amount spent (USD),Impressions\n2026-09-01,2026-09-01,Launch,Prospecting,Video A,120.00,3000\n2026-09-01,2026-09-01,Launch,Retargeting,Static B,80.00,1000`;
const rm = parseCSV(meta); const pm = detect(rm, 'meta');
eq(pm && pm.id, 'meta-daily@1', 'detects meta');
eq(pm.parse(rm).months['2026-09-01'], { spend: 20000, active_campaigns: 1, ad_sets: 2, ads_live: 2 }, 'meta counts');

eq(mergeMonths([{ months: { '2026-09-01': { changes: 2 } } }, { months: { '2026-09-01': { spend: 5, changes: 1 } } }]), { '2026-09-01': { changes: 3, spend: 5 } }, 'merge sums');

// fit: hours = 5 + 2×campaigns exactly
const fit = fitModel([{ drivers: { c: 10 }, hours: 25 }, { drivers: { c: 20 }, hours: 45 }, { drivers: { c: 30 }, hours: 65 }, { drivers: { c: 40 }, hours: 85 }], ['c']);
eq([Math.round(fit.coefficients.c * 100) / 100, Math.round(fit.coefficients.intercept), fit.r2 > 0.999], [2, 5, true], 'NNLS recovers 5 + 2c');
const fit2 = fitModel([{ drivers: { c: 10, junk: 100 }, hours: 25 }, { drivers: { c: 20, junk: 5 }, hours: 45 }, { drivers: { c: 30, junk: 70 }, hours: 65 }, { drivers: { c: 40, junk: 1 }, hours: 85 }, { drivers: { c: 50, junk: 40 }, hours: 105 }], ['c', 'junk']);
eq([Math.round(fit2.coefficients.c * 10) / 10, fit2.coefficients.junk >= 0], [2, true], 'irrelevant driver stays ≥ 0');
console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
