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
// 112: the new platforms — exclusive matchers, per-month counts, spend in cents
const reddit = `Date,Campaign name,Ad group name,Ad name,Spend,Impressions,Clicks
2026-09-02,Launch,Interests,Post A,"$120.50","8,000",40
2026-09-03,Launch,Interests,Post B,0,0,0
2026-09-03,Launch,Lookalike,Post C,"$80.00","5,000",12
2026-10-01,Launch,Interests,Post A,"$10.00",900,3
Total,,,,"$210.50","13,900",55`;
const rr = parseCSV(reddit); const pr = detect(rr, 'reddit');
eq(pr && pr.id, 'reddit-daily@1', 'detects reddit');
eq(pr.parse(rr).months['2026-09-01'], { spend: 20050, active_campaigns: 1, ad_groups: 2, ads_live: 2 }, 'reddit sept: post B inactive, two ad groups, cents');
eq(detect(rr, null) && detect(rr, null).id, 'reddit-daily@1', 'reddit wins without a hint (Meta needs Ad set name)');
eq(detect(rm, 'reddit') && detect(rm, 'reddit').id, 'meta-daily@1', 'a Meta file with a reddit hint still lands on Meta');

const li = `Campaign Performance Report
Account: EMG
Start Date (in UTC),End Date (in UTC),Campaign Group Name,Campaign Name,Creative Name,Total Spent,Impressions,Clicks
9/1/2026,9/1/2026,B2B Q3,Decision makers,Carousel 1,"1,500.00","20,000",100
9/2/2026,9/2/2026,B2B Q3,Decision makers,Carousel 2,0,0,0
9/2/2026,9/2/2026,B2B Q3,Retargeting,Video 1,"400.00","6,000",30
10/1/2026,10/1/2026,B2B Q4,Awareness,Video 2,"50.00","1,000",4`;
const rl = parseCSV(li); const pl = detect(rl, null);
eq(pl && pl.id, 'linkedin-daily@1', 'detects linkedin through its title block, no hint');
eq(pl.parse(rl).months['2026-09-01'], { spend: 190000, active_campaigns: 1, ad_sets: 2, ads_live: 2 }, 'linkedin sept: one group, two campaigns as ad sets, carousel 2 inactive');

const cm = `Date,Campaign,Placement,Creative,Site (CM360),Impressions,Media Cost
2026-09-01,Fall,300x250 ROS,Banner A,cnn.com,"10,000",250.00
2026-09-01,Fall,728x90 ROS,Banner B,cnn.com,"5,000",125.00
2026-09-02,Fall,300x250 ROS,Banner A,espn.com,"2,000",50.00
2026-09-02,Fall,Native feed,Banner C,espn.com,0,0
Grand Total,,,,,"17,000",425.00`;
const rcm = parseCSV(cm); const pcm = detect(rcm, null);
eq(pcm && pcm.id, 'cm360-daily@1', 'a Placement column is CM360, no hint');
eq(pcm.parse(rcm).months['2026-09-01'], { spend: 42500, active_campaigns: 1, placements: 2, ads_live: 2, sites: 2 }, 'cm360: two placements served, native feed did not, two sites, cents');

const viant = `Date,Order,Ad Group,Creative,Impressions,Advertiser Spend
2026-09-01,Holiday CTV,Prospecting,Spot 30,"100,000","2,000.00"
2026-09-01,Holiday CTV,Retargeting,Spot 15,"40,000","800.00"`;
const rv = parseCSV(viant); const pv = detect(rv, 'viant');
eq(pv && pv.id, 'dsp-daily@1', 'viant hint resolves to the DSP family');
eq(pv.parse(rv).months['2026-09-01'], { spend: 280000, active_campaigns: 1, ad_groups: 2, ads_live: 2 }, 'viant: Order and Advertiser Spend read');
eq(detect(rcm, 'dsp') && detect(rcm, 'dsp').id, 'cm360-daily@1', 'a CM360 file with a dsp hint is not swallowed by the DSP parser');

const amazon = `Date,Order,Line item,Creative,Impressions,Total cost
2026-09-01,Holiday Streaming TV,Prospecting 25-54,Spot A,"250,000","3,750.00"
2026-09-01,Holiday Streaming TV,Retargeting,Spot B,0,0`;
const ra = parseCSV(amazon); const pa = detect(ra, 'amazon_dsp');
eq(pa && pa.id, 'dsp-daily@1', 'amazon_dsp hint resolves to the DSP family');
eq(pa.parse(ra).months['2026-09-01'], { spend: 375000, active_campaigns: 1, ad_groups: 1, ads_live: 1 }, 'amazon: Order is the campaign, Total cost is spend, the idle line item does not count');
const vistar = `Date,Campaign,Insertion Order,Creative,DMA,Impressions,Spend
2026-09-01,Transit Q3,Chicago boards,Board 1,Chicago,"12,000",600.00
2026-09-01,Transit Q3,Dallas boards,Board 2,Dallas-Ft. Worth,"8,000",400.00`;
const rvi = parseCSV(vistar); const pvi = detect(rvi, 'vistar');
eq(pvi && pvi.id, 'dsp-daily@1', 'vistar hint resolves to the DSP family');
eq(pvi.parse(rvi).months['2026-09-01'], { spend: 100000, active_campaigns: 1, ad_groups: 2, ads_live: 2, markets: 2 }, 'vistar: two insertion orders, two boards, two DMAs as markets');
eq(['dv360', 'ttd'].map(h => detect(rv, h) && detect(rv, h).id), ['dsp-daily@1', 'dsp-daily@1'], 'dv360 and ttd hints resolve to the DSP family');

console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail ? 1 : 0);
