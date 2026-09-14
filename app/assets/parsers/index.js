// Detect and parse a platform export into per-month driver counts.
//   parseFile(file, platformHint, opts) → { parser, kind, platform, months: {m: drivers}, rows, warnings }
//   mergeMonths([...results])           → { m: drivers } summed per key
// Drivers are plain counts; spend is in CENTS (the SQL side stores cents).
// The platform hint narrows detection to that platform's parsers first; any
// parser may still match when the hint is wrong, and the result says which.
import { parseCSV } from './csv.js?v=4437c52';
import { googleAdsDaily, googleAdsChanges } from './google-ads.js?v=4437c52';
import { metaDaily, metaActivity } from './meta-ads.js?v=4437c52';
import { dspDaily } from './dsp.js?v=4437c52';

export const PARSERS = [googleAdsDaily, googleAdsChanges, metaDaily, metaActivity, dspDaily];
export const PLATFORMS = {
  google_ads: { label: 'Google Ads', hint: 'Reports → ad or ad group level with a Day column; Change history → Download' },
  meta:       { label: 'Meta',       hint: 'Ads Manager → Export with a day breakdown; Activity history → Export' },
  dsp:        { label: 'DSP (DV360 / TTD)', hint: 'A report by date with insertion order / line item / creative and cost' },
  calendar:   { label: 'Calendar & meetings', hint: 'typed per month' },
  reporting:  { label: 'Reporting & deliverables', hint: 'typed per month' },
  creative:   { label: 'Creative assets', hint: 'typed per month' },
};
export const DRIVER_LABELS = {
  changes: 'change events', active_campaigns: 'live campaigns', ad_sets: 'ad sets', ad_groups: 'ad groups', ads_live: 'ads live',
  creatives_refreshed: 'creatives refreshed', spend: 'spend', markets: 'markets', platforms: 'platforms',
  meetings: 'meetings', reports: 'reports / deliverables', creatives_delivered: 'creatives delivered', changed_campaigns: 'campaigns changed'
};

export function detect(rows, platformHint) {
  const ordered = [...PARSERS.filter(p => p.platform === platformHint), ...PARSERS.filter(p => p.platform !== platformHint)];
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
