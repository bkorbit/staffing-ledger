// Meta Ads Manager exports → per-month drivers.
//   daily    Ads Manager report with a day breakdown: Reporting starts (or Day /
//            Date), Campaign name, Ad set name, Ad name (or Ad ID), Amount spent
//            (any currency), Impressions, optional Country / Region.
//   activity Activity history export: Time / Date, Activity, Item changed,
//            Changed by. changes = rows per month; system / rule actors dropped
//            when opts.excludeAutomated is on.
import { findHeader, col, parseNum, toMonth } from './csv.js?v=c162c85';
import { finish, AUTOMATED } from './google-ads.js?v=c162c85';

const bump = (m, key, v = 1) => { m[key] = (m[key] || 0) + v; };
const ensure = (out, month) => (out[month] = out[month] || { _sets: {} });
const addSet = (o, key, val) => { if (val === undefined || val === null || val === '') return; (o._sets[key] = o._sets[key] || new Set()).add(String(val)); };

export const metaDaily = {
  id: 'meta-daily@1', platform: 'meta', label: 'Meta Ads Manager report',
  matches(rows) { return findHeader(rows, [['reporting starts', 'day', 'date'], ['campaign name']]) >= 0; },
  parse(rows) {
    const hi = findHeader(rows, [['reporting starts', 'day', 'date'], ['campaign name']]);
    const h = rows[hi];
    const cDay = col(h, ['reporting starts', 'day', 'date']), cCamp = col(h, ['campaign name']), cSet = col(h, ['ad set name']),
      cAd = col(h, ['ad id', 'ad name']), cSpend = col(h, ['amount spent']), cImp = col(h, ['impressions']), cGeo = col(h, ['country', 'region', 'dma region']);
    const out = {}; let used = 0; const warnings = [];
    for (const r of rows.slice(hi + 1)) {
      const month = toMonth(r[cDay]); if (!month) continue;
      const imp = cImp >= 0 ? parseNum(r[cImp]) : 0, spend = cSpend >= 0 ? parseNum(r[cSpend]) : 0;
      const o = ensure(out, month); used++;
      if (imp > 0 || spend > 0) {
        addSet(o, 'active_campaigns', r[cCamp]);
        if (cSet >= 0) addSet(o, 'ad_sets', r[cCamp] + '|' + r[cSet]);
        if (cAd >= 0) addSet(o, 'ads_live', r[cCamp] + '|' + (cSet >= 0 ? r[cSet] : '') + '|' + r[cAd]);
        if (cGeo >= 0) addSet(o, 'markets', r[cGeo]);
      }
      bump(o, 'spend', Math.round(spend * 100));
    }
    if (cSpend < 0) warnings.push('no Amount spent column — spend not captured');
    return finish(out, used, warnings, this.id, 'daily');
  }
};

export const metaActivity = {
  id: 'meta-activity@1', platform: 'meta', label: 'Meta activity history',
  matches(rows) { return findHeader(rows, [['time', 'date'], ['activity', 'item changed']]) >= 0; },
  parse(rows, opts = {}) {
    const hi = findHeader(rows, [['time', 'date'], ['activity', 'item changed']]);
    const h = rows[hi];
    const cDate = col(h, ['time', 'date']), cWho = col(h, ['changed by', 'user']);
    const out = {}; let used = 0, dropped = 0;
    for (const r of rows.slice(hi + 1)) {
      const month = toMonth(r[cDate]); if (!month) continue;
      const who = cWho >= 0 ? String(r[cWho] || '') : '';
      if (opts.excludeAutomated && AUTOMATED.test(who) && !/@/.test(who)) { dropped++; continue; }
      const o = ensure(out, month); used++;
      bump(o, 'changes', 1);
    }
    return finish(out, used, dropped ? [`${dropped} automated changes dropped`] : [], this.id, 'changes');
  }
};
