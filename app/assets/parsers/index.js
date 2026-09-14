// Detect and parse a platform export into per-month driver counts.
//   parseFile(file, platformHint, opts) → { parser, kind, platform, months: {m: drivers}, rows, warnings }
//   mergeMonths([...results])           → { m: drivers } summed per key
// Drivers are plain counts; spend is in CENTS (the SQL side stores cents).
// The platform hint narrows detection to that platform's parsers first; any
// parser may still match when the hint is wrong, and the result says which.
import { parseCSV } from './csv.js?v=9765ee9';
import { googleAdsDaily, googleAdsChanges } from './google-ads.js?v=9765ee9';
import { metaDaily, metaActivity } from './meta-ads.js?v=9765ee9';
import { dspDaily } from './dsp.js?v=9765ee9';
import { redditDaily, linkedinDaily } from './social.js?v=9765ee9';
import { cm360Daily } from './cm360.js?v=9765ee9';

// Order matters when no platform hint is given: the exclusive shapes first
// (a Placement column = CM360; Campaign group / Total spent = LinkedIn; Ad
// group name + Campaign name = Reddit), then the broad ones.
export const PARSERS = [cm360Daily, linkedinDaily, redditDaily, googleAdsDaily, googleAdsChanges, metaDaily, metaActivity, dspDaily];
// The platform registry. `files` = an export is uploaded (the typed-signal
// platforms are kept for old uploads' labels only — nothing is typed any more,
// 112). `parser` = which parser family reads it when the platform has no
// parser of its own (Viant exports share the DSP shape). `group` orders the
// bench view by the team that usually runs the platform.
export const PLATFORMS = {
  google_ads: { label: 'Google Ads', group: 'Paid Media', files: true, hint: 'Reports → ad or ad group level with a Day column; Change history → Download' },
  meta:       { label: 'Meta', group: 'Paid Media', files: true, hint: 'Ads Manager → Export with a day breakdown; Activity history → Export' },
  reddit:     { label: 'Reddit Ads', group: 'Paid Media', files: true, hint: 'Ads Manager → Reports → export by day at ad level (Date, Campaign name, Ad group name, Ad name, Spend, Impressions)' },
  linkedin:   { label: 'LinkedIn', group: 'Paid Media', files: true, hint: 'Campaign Manager → Analytics → export by day, creative or campaign level (Start Date, Campaign Group Name, Campaign Name, Total Spent)' },
  dsp:        { label: 'DV360 / The Trade Desk', group: 'Programmatic', files: true, hint: 'A report by date with insertion order / line item / creative and cost' },
  viant:      { label: 'Viant (Adelphic)', group: 'Programmatic', files: true, parser: 'dsp', hint: 'A report by date with campaign / order, ad group or line item, creative, impressions and spend' },
  cm360:      { label: 'Campaign Manager 360 (Adswerve)', group: 'AdOps', files: true, hint: 'Report Builder → by date with Campaign, Placement, Creative, Site and Impressions — a placement is the unit of trafficking work' },
  calendar:   { label: 'Calendar & meetings', group: 'Planning & Strategy', files: false, hint: 'typed per month (retired)' },
  reporting:  { label: 'Reporting & deliverables', group: 'Planning & Strategy', files: false, hint: 'typed per month (retired)' },
  creative:   { label: 'Creative assets', group: 'Creative', files: false, hint: 'typed per month (retired)' },
};
export const DRIVER_LABELS = {
  changes: 'change events', active_campaigns: 'live campaigns', ad_sets: 'ad sets', ad_groups: 'ad groups', ads_live: 'ads live',
  creatives_refreshed: 'creatives refreshed', spend: 'spend', markets: 'markets', platforms: 'platforms', placements: 'placements trafficked', sites: 'sites',
  meetings: 'meetings', reports: 'reports / deliverables', creatives_delivered: 'creatives delivered', changed_campaigns: 'campaigns changed'
};

export function detect(rows, platformHint) {
  // a platform without its own parser names the family it shares (viant → dsp)
  const fam = platformHint && PLATFORMS[platformHint] && PLATFORMS[platformHint].parser || platformHint;
  const ordered = [...PARSERS.filter(p => p.platform === fam), ...PARSERS.filter(p => p.platform !== fam)];
  return ordered.find(p => { try { return p.matches(rows); } catch { return false; } }) || null;
}

export async function parseFile(file, platformHint, opts = {}) {
  const text = await file.text();
  const rows = parseCSV(text);
  if (!rows.length) return { error: 'empty file', filename: file.name };
  const parser = detect(rows, platformHint);
  if (!parser) return { error: `no known export shape (first header row: ${rows[0].slice(0, 6).join(', ')})`, filename: file.name };
  const r = parser.parse(rows, opts);
  return { ...r, platform: parser.platform, filename: file.name, label: parser.label };
}

export function mergeMonths(results) {
  const out = {};
  for (const r of results) for (const [m, d] of Object.entries(r.months || {})) {
    out[m] = out[m] || {};
    for (const [k, v] of Object.entries(d)) out[m][k] = (out[m][k] || 0) + (+v || 0);
  }
  return out;
}

export const monthKeys = months => Object.keys(months).sort();
