// Campaign Manager 360 (Adswerve trafficking) reports → per-month drivers for
// AdOps. A CM360 report by date with Campaign, Placement (the unit of
// trafficking work), Creative and, when present, Site and Media Cost:
//   active_campaigns  campaigns that served (impressions or cost)
//   placements        distinct campaign|placement that served — the AdOps driver
//   ads_live          distinct creatives that served
//   sites             distinct sites trafficked to
//   spend             Σ media cost in CENTS (0 when the report has no cost)
// Matcher: a Date column and a Placement column — no other export has one.
// Aliases take the first real Adswerve file we see; send one to pin them.
import { findHeader, col, parseNum, toMonth } from './csv.js?v=e7ad876';
import { finish } from './google-ads.js?v=e7ad876';

const bump = (m, key, v = 1) => { m[key] = (m[key] || 0) + v; };
const ensure = (out, month) => (out[month] = out[month] || { _sets: {} });
const addSet = (o, key, val) => { if (val === undefined || val === null || val === '') return; (o._sets[key] = o._sets[key] || new Set()).add(String(val)); };

export const cm360Daily = {
  id: 'cm360-daily@1', platform: 'cm360', label: 'Campaign Manager 360 report',
  matches(rows) { return findHeader(rows, [['date', 'day'], ['placement', 'placement name', 'placement id']]) >= 0; },
  parse(rows) {
    const hi = findHeader(rows, [['date', 'day'], ['placement', 'placement name', 'placement id']]);
    const h = rows[hi];
    const cDay = col(h, ['date', 'day']), cCamp = col(h, ['campaign', 'campaign name', 'campaign id']),
      cPl = col(h, ['placement', 'placement name', 'placement id']), cCre = col(h, ['creative', 'creative name', 'creative id']),
      cSite = col(h, ['site (cm360)', 'site (dcm)', 'site', 'site name']), cImp = col(h, ['impressions']),
      cCost = col(h, ['media cost', 'dbm cost (account currency)', 'dbm cost', 'cost', 'spend']);
    const out = {}; let used = 0; const warnings = [];
    for (const r of rows.slice(hi + 1)) {
      if (/^(grand )?total/i.test(String(r[0] || '').trim())) continue;
      const month = toMonth(r[cDay]); if (!month) continue;
      const imp = cImp >= 0 ? parseNum(r[cImp]) : 0, cost = cCost >= 0 ? parseNum(r[cCost]) : 0;
      const o = ensure(out, month); used++;
      if (imp > 0 || cost > 0) {
        if (cCamp >= 0) addSet(o, 'active_campaigns', r[cCamp]);
        addSet(o, 'placements', (cCamp >= 0 ? r[cCamp] : '') + '|' + r[cPl]);
        if (cCre >= 0) addSet(o, 'ads_live', r[cCre]);
        if (cSite >= 0) addSet(o, 'sites', r[cSite]);
      }
      if (cCost >= 0) bump(o, 'spend', Math.round(cost * 100));
    }
    if (cCost < 0) warnings.push('no Media Cost column — spend not captured (trafficking reports often have none)');
    return finish(out, used, warnings, this.id, 'daily');
  }
};
