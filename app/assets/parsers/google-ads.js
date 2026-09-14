// Google Ads exports → per-month drivers.
//   daily   "Reports" export at ad level (or campaign / ad group level) with a
//           Day column: Day, Campaign, Ad group, Ad ID (or Ad / Headline 1),
//           Cost, Impressions, optional Campaign state / Country/Territory.
//           A campaign / ad group / ad counts as ACTIVE in a month when it had
//           impressions or cost that month. spend = Σ Cost in CENTS.
//   changes "Change history" export: Date & time (or Date), Campaign, Ad group,
//           Change type / Changes, User, Tool. changes = rows per month;
//           automated tools (API, scripts, rules, Google's own) are dropped
//           when opts.excludeAutomated is on — they are not a person's time.
import { findHeader, col, parseNum, toMonth } from './csv.js?v=760727b';

const bump = (m, key, v = 1) => { m[key] = (m[key] || 0) + v; };
const ensure = (out, month) => (out[month] = out[month] || { _sets: {} });
const addSet = (o, key, val) => { if (val === undefined || val === null || val === '') return; (o._sets[key] = o._sets[key] || new Set()).add(String(val)); };
export const AUTOMATED = /api|automat|script|rule|system|google|smart bidding|recommendation/i;

export const googleAdsDaily = {
  id: 'google-ads-daily@1', platform: 'google_ads', label: 'Google Ads daily report',
  matches(rows) { return findHeader(rows, [['day', 'date'], 'campaign']) >= 0 && findHeader(rows, [['change type', 'changes', 'changed item']]) < 0; },
  parse(rows) {
    const hi = findHeader(rows, [['day', 'date'], 'campaign']);
    const h = rows[hi];
    const cDay = col(h, ['day', 'date']), cCamp = col(h, ['campaign']), cAdg = col(h, ['ad group']),
      cAd = col(h, ['ad id', 'ad', 'headline 1', 'final url']), cCost = col(h, ['cost', 'spend']), cImp = col(h, ['impr.', 'impressions', 'impr']),
      cGeo = col(h, ['country/territory', 'country', 'region', 'location', 'metro area']);
    const out = {}; let used = 0; const warnings = [];
    for (const r of rows.slice(hi + 1)) {
      if (/^total/i.test(String(r[0] || '').trim())) continue;
      const month = toMonth(r[cDay]); if (!month) continue;
      const imp = cImp >= 0 ? parseNum(r[cImp]) : 0, cost = cCost >= 0 ? parseNum(r[cCost]) : 0;
      const o = ensure(out, month); used++;
      if (imp > 0 || cost > 0) {
        addSet(o, 'active_campaigns', r[cCamp]);
        if (cAdg >= 0) addSet(o, 'ad_groups', r[cCamp] + '|' + r[cAdg]);
        if (cAd >= 0) addSet(o, 'ads_live', r[cCamp] + '|' + (cAdg >= 0 ? r[cAdg] : '') + '|' + r[cAd]);
        if (cGeo >= 0) addSet(o, 'markets', r[cGeo]);
      }
      bump(o, 'spend', Math.round(cost * 100));
    }
    if (cCost < 0) warnings.push('no Cost column — spend not captured');
    if (cAdg < 0) warnings.push('no Ad group column — ad_groups not captured');
    return finish(out, used, warnings, this.id, 'daily');
  }
};

export const googleAdsChanges = {
  id: 'google-ads-changes@1', platform: 'google_ads', label: 'Google Ads change history',
  matches(rows) { return findHeader(rows, [['date & time', 'date', 'time'], ['change type', 'changes', 'changed item', 'change']]) >= 0; },
  parse(rows, opts = {}) {
    const hi = findHeader(rows, [['date & time', 'date', 'time'], ['change type', 'changes', 'changed item', 'change']]);
    const h = rows[hi];
    const cDate = col(h, ['date & time', 'date', 'time']), cUser = col(h, ['user', 'changed by']), cTool = col(h, ['tool', 'source']);
    const cCamp = col(h, ['campaign']);
    const out = {}; let used = 0, dropped = 0;
    for (const r of rows.slice(hi + 1)) {
      const month = toMonth(r[cDate]); if (!month) continue;
      const who = `${cUser >= 0 ? r[cUser] : ''} ${cTool >= 0 ? r[cTool] : ''}`;
      if (opts.excludeAutomated && AUTOMATED.test(who) && !/@/.test(String(cUser >= 0 ? r[cUser] : ''))) { dropped++; continue; }
      const o = ensure(out, month); used++;
      bump(o, 'changes', 1);
      if (cCamp >= 0) addSet(o, 'changed_campaigns', r[cCamp]);
    }
    const warnings = dropped ? [`${dropped} automated changes dropped`] : [];
    return finish(out, used, warnings, this.id, 'changes');
  }
};

export function finish(out, used, warnings, parser, kind) {
  const months = {};
  for (const [m, o] of Object.entries(out)) {
    const d = {};
    for (const [k, v] of Object.entries(o)) if (k !== '_sets') d[k] = v;
    for (const [k, set] of Object.entries(o._sets)) d[k] = set.size;
    months[m] = d;
  }
  return { parser, kind, months, rows: used, warnings };
}
