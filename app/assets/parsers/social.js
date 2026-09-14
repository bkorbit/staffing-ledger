// Reddit Ads and LinkedIn Campaign Manager exports → per-month drivers.
//   reddit    Reddit Ads Manager report with a Date column: Date, Campaign
//             name, Ad group name, Ad name (or Ad ID / Post), Spend, Impressions,
//             optional Country. Hierarchy campaign → ad group → ad, so
//             ad_groups and ads_live line up with Google Ads.
//   linkedin  Campaign Manager report (a title block, then Start Date (in UTC),
//             Campaign Group Name, Campaign Name, Creative Name / Ad Name,
//             Total Spent, Impressions). LinkedIn's hierarchy is campaign group
//             → campaign → creative; the group is the "campaign" a person runs,
//             the campaign is its ad set. Mapped so: active_campaigns = groups,
//             ad_sets = campaigns, ads_live = creatives.
// Both: a thing counts as ACTIVE in a month when it had impressions or spend.
// spend = Σ spend in CENTS. Matchers are exclusive with Meta's (Ad set name)
// and Google's (no Campaign name column) so a file lands on one parser only.
// The column names are the exports' documented headers; the alias lists take
// the first real files we see — send one per platform to pin them.
import { findHeader, col, parseNum, toMonth } from './csv.js?v=9765ee9';
import { finish } from './google-ads.js?v=9765ee9';

const bump = (m, key, v = 1) => { m[key] = (m[key] || 0) + v; };
const ensure = (out, month) => (out[month] = out[month] || { _sets: {} });
const addSet = (o, key, val) => { if (val === undefined || val === null || val === '') return; (o._sets[key] = o._sets[key] || new Set()).add(String(val)); };

export const redditDaily = {
  id: 'reddit-daily@1', platform: 'reddit', label: 'Reddit Ads report',
  matches(rows) { return findHeader(rows, [['date', 'day'], ['campaign name', 'campaign'], ['ad group name', 'ad group', 'ad group id']]) >= 0 && findHeader(rows, ['ad set name']) < 0; },
  parse(rows) {
    const hi = findHeader(rows, [['date', 'day'], ['campaign name', 'campaign'], ['ad group name', 'ad group', 'ad group id']]);
    const h = rows[hi];
    const cDay = col(h, ['date', 'day']), cCamp = col(h, ['campaign name', 'campaign id', 'campaign']), cAdg = col(h, ['ad group name', 'ad group id', 'ad group']),
      cAd = col(h, ['ad name', 'ad id', 'post title', 'post id', 'ad']), cCost = col(h, ['spend', 'amount spent', 'cost']), cImp = col(h, ['impressions', 'impr']),
      cGeo = col(h, ['country', 'region', 'location', 'geo']);
    const out = {}; let used = 0; const warnings = [];
    for (const r of rows.slice(hi + 1)) {
      if (/^total/i.test(String(r[0] || '').trim())) continue;
      const month = toMonth(r[cDay]); if (!month) continue;
      const imp = cImp >= 0 ? parseNum(r[cImp]) : 0, cost = cCost >= 0 ? parseNum(r[cCost]) : 0;
      const o = ensure(out, month); used++;
      if (imp > 0 || cost > 0) {
        addSet(o, 'active_campaigns', r[cCamp]);
        addSet(o, 'ad_groups', r[cCamp] + '|' + r[cAdg]);
        if (cAd >= 0) addSet(o, 'ads_live', r[cCamp] + '|' + r[cAdg] + '|' + r[cAd]);
        if (cGeo >= 0) addSet(o, 'markets', r[cGeo]);
      }
      bump(o, 'spend', Math.round(cost * 100));
    }
    if (cCost < 0) warnings.push('no Spend column — spend not captured');
    return finish(out, used, warnings, this.id, 'daily');
  }
};

export const linkedinDaily = {
  id: 'linkedin-daily@1', platform: 'linkedin', label: 'LinkedIn Campaign Manager report',
  matches(rows) { return findHeader(rows, [['start date (in utc)', 'start date', 'date', 'day'], ['campaign name'], ['campaign group name', 'campaign group', 'total spent']]) >= 0 && findHeader(rows, ['ad set name']) < 0; },
  parse(rows) {
    const hi = findHeader(rows, [['start date (in utc)', 'start date', 'date', 'day'], ['campaign name'], ['campaign group name', 'campaign group', 'total spent']]);
    const h = rows[hi];
    const cDay = col(h, ['start date (in utc)', 'start date', 'date', 'day']), cGroup = col(h, ['campaign group name', 'campaign group id', 'campaign group']),
      cCamp = col(h, ['campaign name', 'campaign id']), cCre = col(h, ['creative name', 'creative id', 'ad name', 'ad id', 'creative']),
      cCost = col(h, ['total spent', 'spend', 'cost']), cImp = col(h, ['impressions']), cGeo = col(h, ['country', 'region', 'location']);
    const out = {}; let used = 0; const warnings = [];
    for (const r of rows.slice(hi + 1)) {
      if (/^total/i.test(String(r[0] || '').trim())) continue;
      const month = toMonth(r[cDay]); if (!month) continue;
      const imp = cImp >= 0 ? parseNum(r[cImp]) : 0, cost = cCost >= 0 ? parseNum(r[cCost]) : 0;
      const o = ensure(out, month); used++;
      if (imp > 0 || cost > 0) {
        if (cGroup >= 0) addSet(o, 'active_campaigns', r[cGroup]); else addSet(o, 'active_campaigns', r[cCamp]);
        addSet(o, 'ad_sets', (cGroup >= 0 ? r[cGroup] : '') + '|' + r[cCamp]);
        if (cCre >= 0) addSet(o, 'ads_live', r[cCamp] + '|' + r[cCre]);
        if (cGeo >= 0) addSet(o, 'markets', r[cGeo]);
      }
      bump(o, 'spend', Math.round(cost * 100));
    }
    if (cCost < 0) warnings.push('no Total Spent column — spend not captured');
    if (cGroup < 0) warnings.push('no Campaign Group column — campaigns counted as groups');
    return finish(out, used, warnings, this.id, 'daily');
  }
};
