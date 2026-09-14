// Programmatic DSP exports → per-month drivers. One parser covers the shapes
// DV360, The Trade Desk, Viant, Amazon DSP and Vistar export: a Date column, a campaign-ish column
// (Campaign / Insertion Order / Advertiser), a line-item-ish column (Line Item /
// Ad Group), a creative column, Impressions, and a cost column (Media Cost /
// Revenue (Adv Currency) / Advertiser Cost / Total Media Cost). Reports end
// with a blank line and a footer — rows without a parsable date are skipped.
import { findHeader, col, parseNum, toMonth } from './csv.js?v=e7ad876';
import { finish } from './google-ads.js?v=e7ad876';

const bump = (m, key, v = 1) => { m[key] = (m[key] || 0) + v; };
const ensure = (out, month) => (out[month] = out[month] || { _sets: {} });
const addSet = (o, key, val) => { if (val === undefined || val === null || val === '') return; (o._sets[key] = o._sets[key] || new Set()).add(String(val)); };

export const dspDaily = {
  id: 'dsp-daily@1', platform: 'dsp', label: 'DSP report (DV360 / TTD / Viant / Amazon / Vistar)',
  matches(rows) { return findHeader(rows, [['date', 'day'], ['insertion order', 'line item', 'ad group', 'campaign', 'order']]) >= 0 && findHeader(rows, ['campaign name']) < 0 && findHeader(rows, [['placement', 'placement name', 'placement id']]) < 0; },
  parse(rows) {
    const hi = findHeader(rows, [['date', 'day'], ['insertion order', 'line item', 'ad group', 'campaign', 'order']]);
    const h = rows[hi];
    // the campaign is the top level present; the level under it (line item, ad
    // group, or the insertion order when a campaign column sits above it) is
    // the ad-group level. DV360: Campaign › Insertion Order › Line Item; TTD:
    // Campaign › Ad Group; Amazon: Order › Line item; Vistar: Campaign › IO.
    const cDay = col(h, ['date', 'day']), cCamp = col(h, ['campaign', 'order', 'insertion order', 'advertiser']);
    let cLine = col(h, ['line item', 'ad group']);
    if (cLine < 0) { const io = col(h, ['insertion order']); if (io >= 0 && io !== cCamp) cLine = io; }
    const cCre = col(h, ['creative', 'creative id', 'creative name']),
      cImp = col(h, ['impressions']), cCost = col(h, ['media cost', 'revenue (adv currency)', 'advertiser cost', 'total media cost', 'media spend', 'advertiser spend', 'total spend', 'total cost', 'cost', 'spend']),
      cGeo = col(h, ['country', 'region', 'dma', 'metro']);
    const out = {}; let used = 0; const warnings = [];
    for (const r of rows.slice(hi + 1)) {
      const month = toMonth(r[cDay]); if (!month) continue;
      const imp = cImp >= 0 ? parseNum(r[cImp]) : 0, cost = cCost >= 0 ? parseNum(r[cCost]) : 0;
      const o = ensure(out, month); used++;
      if (imp > 0 || cost > 0) {
        addSet(o, 'active_campaigns', r[cCamp]);
        if (cLine >= 0) addSet(o, 'ad_groups', r[cCamp] + '|' + r[cLine]);
        if (cCre >= 0) addSet(o, 'ads_live', r[cCre]);
        if (cGeo >= 0) addSet(o, 'markets', r[cGeo]);
      }
      bump(o, 'spend', Math.round(cost * 100));
    }
    if (cCost < 0) warnings.push('no cost column — spend not captured');
    return finish(out, used, warnings, this.id, 'daily');
  }
};
