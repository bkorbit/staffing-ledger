// Pull open HubSpot deals (with their line items and associated company) into the
// EMG ledger, for the Sales Forecast tab.
//
// Runs nightly via .github/workflows/sync-hubspot.yml.
// Deliberately stores deals close to raw — line items are kept as-is and the gross
// profit maths happens in the app, so changing the mapping in Settings takes effect
// immediately rather than waiting for the next sync.
//
// Required secrets:
//   HUBSPOT_TOKEN              – HubSpot private app token
//   SUPABASE_SERVICE_ROLE_KEY  – Supabase service-role key (server-side only)

const HS_TOKEN = process.env.HUBSPOT_TOKEN;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = 'https://bdtzpeazcjgnsxodwzpz.supabase.co';
const WORKSPACE_ID = 'default';
const HS = 'https://api.hubapi.com';
// Won deals stay in the payload for this long so they can still be copied to the ledger.
const WON_RETAIN_DAYS = 60;
// Deals won before the cutover were loaded into the ledger by hand, so pulling them in
// would only create duplicates. Overridable from Settings via hubspotConfig.wonCutover.
const WON_CUTOVER_DEFAULT = '2026-08-11';

if (!HS_TOKEN) fail('Missing HUBSPOT_TOKEN secret.');
if (!SERVICE_KEY) fail('Missing SUPABASE_SERVICE_ROLE_KEY secret.');

function fail(m) { console.error('✖ ' + m); process.exit(1); }
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function hs(path, opts = {}, tries = 0) {
  const res = await fetch(HS + path, {
    ...opts,
    headers: { Authorization: 'Bearer ' + HS_TOKEN, 'Content-Type': 'application/json', ...(opts.headers || {}) }
  });
  if (res.status === 429 && tries < 5) {            // rate limited — back off and retry
    const wait = 1000 * Math.pow(2, tries);
    console.log(`  rate limited, waiting ${wait}ms…`);
    await sleep(wait);
    return hs(path, opts, tries + 1);
  }
  if (!res.ok) fail(`HubSpot ${path} returned ${res.status}: ${(await res.text()).slice(0, 400)}`);
  return res.json();
}

// ---------- HubSpot ----------

async function searchDeals(pipelines, wonFrom) {
  const props = ['dealname', 'dealstage', 'pipeline', 'amount', 'closedate',
                 'campaign_start_date', 'campaign_end_date', 'hs_deal_stage_probability',
                 'hs_is_closed', 'hs_is_closed_won',
                 // job_code is the shared key with QuickBooks; the invoice totals are
                 // already synced into HubSpot by the existing QuickBooks integration.
                 'job_code', 'qb_project_link', 'total_amount_invoices', 'total_left_to_bill'];
  const out = [];
  const wonSince = Date.parse(wonFrom + 'T00:00:00Z');
  for (const pl of pipelines) {
    let after;
    for (;;) {
      const body = {
        // group 1: still open · group 2: won recently, so it stays available to copy
        filterGroups: [
          { filters: [
            { propertyName: 'pipeline', operator: 'EQ', value: pl },
            { propertyName: 'hs_is_closed', operator: 'EQ', value: 'false' }
          ]},
          { filters: [
            { propertyName: 'pipeline', operator: 'EQ', value: pl },
            { propertyName: 'hs_is_closed_won', operator: 'EQ', value: 'true' },
            { propertyName: 'closedate', operator: 'GTE', value: String(wonSince) }
          ]}
        ],
        properties: props, limit: 100, ...(after ? { after } : {})
      };
      const d = await hs('/crm/v3/objects/deals/search', { method: 'POST', body: JSON.stringify(body) });
      out.push(...(d.results || []));
      after = d.paging && d.paging.next && d.paging.next.after;
      if (!after) break;
    }
  }
  return out;
}

// Batch-read associations, 100 ids at a time.
async function assoc(fromType, toType, ids) {
  const map = {};
  for (let i = 0; i < ids.length; i += 100) {
    const chunk = ids.slice(i, i + 100);
    const d = await hs(`/crm/v4/associations/${fromType}/${toType}/batch/read`, {
      method: 'POST', body: JSON.stringify({ inputs: chunk.map(id => ({ id: String(id) })) })
    });
    (d.results || []).forEach(r => {
      map[r.from.id] = (r.to || []).map(t => t.toObjectId || t.id);
    });
  }
  return map;
}

async function readBatch(objectType, ids, properties) {
  const out = {};
  for (let i = 0; i < ids.length; i += 100) {
    const chunk = ids.slice(i, i + 100);
    const d = await hs(`/crm/v3/objects/${objectType}/batch/read`, {
      method: 'POST',
      body: JSON.stringify({ properties, inputs: chunk.map(id => ({ id: String(id) })) })
    });
    (d.results || []).forEach(r => { out[r.id] = r.properties || {}; });
  }
  return out;
}

// ---------- Supabase ----------

const sbHeaders = { apikey: SERVICE_KEY, Authorization: 'Bearer ' + SERVICE_KEY, 'Content-Type': 'application/json' };
let loadedVersion = null;

async function loadLedger() {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/ledger_state?id=eq.${WORKSPACE_ID}&select=data,version`, { headers: sbHeaders });
  if (!res.ok) fail(`Supabase read failed (${res.status}): ${await res.text()}`);
  const rows = await res.json();
  if (!rows.length) fail('No ledger row found — open the app once before syncing.');
  loadedVersion = typeof rows[0].version === 'number' ? rows[0].version : 0;
  return rows[0].data || {};
}

async function saveLedger(state) {
  const url = `${SUPABASE_URL}/rest/v1/ledger_state?id=eq.${WORKSPACE_ID}&version=eq.${loadedVersion}`;
  const res = await fetch(url, {
    method: 'PATCH',
    headers: { ...sbHeaders, Prefer: 'return=representation' },
    body: JSON.stringify({ data: state, version: (loadedVersion || 0) + 1, updated_at: new Date().toISOString() })
  });
  if (!res.ok) fail(`Supabase write failed (${res.status}): ${await res.text()}`);
  const rows = await res.json();
  if (!rows.length) {
    console.log('⚠ Ledger changed during sync (someone saved while it ran) — skipping write. Re-run.');
    process.exit(0);
  }
}

// ---------- main ----------

const clean = v => (v === undefined || v === null || v === '') ? '' : String(v).slice(0, 10);

(async () => {
  const state = await loadLedger();
  const cfg = state.hubspotConfig || {};
  if (cfg.enabled === false) { console.log('Sync disabled in Settings — nothing to do.'); return; }
  const pipelines = (cfg.pipelines && cfg.pipelines.length) ? cfg.pipelines : ['default'];
  console.log('Pipelines:', pipelines.join(', '));

  // Retain won deals for 60 days, but never reach back past the cutover — whichever
  // of the two is later wins, so the window slides forward once 60 days have elapsed.
  const retainFrom = new Date(Date.now() - WON_RETAIN_DAYS * 86400000).toISOString().slice(0, 10);
  const cutover = cfg.wonCutover || WON_CUTOVER_DEFAULT;
  const wonFrom = retainFrom > cutover ? retainFrom : cutover;
  console.log(`Won deals: keeping those closed on or after ${wonFrom} ` +
    `(${WON_RETAIN_DAYS}-day retention, cutover ${cutover}).`);

  const deals = await searchDeals(pipelines, wonFrom);
  console.log(`Fetched ${deals.length} open deals.`);
  if (!deals.length) { console.log('Nothing to write.'); return; }

  const ids = deals.map(d => d.id);
  console.log('Reading associations…');
  const liMap = await assoc('deals', 'line_items', ids);
  const coMap = await assoc('deals', 'companies', ids);

  const liIds = [...new Set(Object.values(liMap).flat())];
  const coIds = [...new Set(Object.values(coMap).flat())];
  console.log(`  ${liIds.length} line items, ${coIds.length} companies.`);

  const lineItems = liIds.length ? await readBatch('line_items', liIds, ['name', 'amount', 'price', 'quantity']) : {};
  const companies = coIds.length ? await readBatch('companies', coIds, ['name']) : {};

  // "Already copied" is derived from the ledger's own projects, not a stored flag, so it
  // stays true only while the project actually exists.
  const inLedgerFromProjects = new Set([
    ...(state.deals || []).filter(d => d.hubspotDealId).map(d => String(d.hubspotDealId)),
    ...(state.projects || []).filter(p => p.hubspotDealId).map(p => String(p.hubspotDealId))
  ]);

  let withItems = 0, withCompany = 0;
  const out = deals.map(d => {
    const p = d.properties || {};
    const items = (liMap[d.id] || []).map(id => {
      const li = lineItems[id] || {};
      return [li.name || '', +li.amount || 0];
    }).filter(x => x[0] || x[1]);
    if (items.length) withItems++;
    const coId = (coMap[d.id] || [])[0];
    const company = coId && companies[coId] ? (companies[coId].name || '') : '';
    if (company) withCompany++;
    return {
      id: d.id,
      name: p.dealname || 'Untitled',
      company,
      stage: p.dealstage || '',
      prob: parseFloat(p.hs_deal_stage_probability) || 0,
      amount: parseFloat(p.amount) || 0,
      closeDate: clean(p.closedate),
      campaignStart: clean(p.campaign_start_date),
      campaignEnd: clean(p.campaign_end_date),
      items,
      won: String(p.hs_is_closed_won) === 'true',
      jobCode: (p.job_code || '').trim(),
      qbLink: p.qb_project_link || '',
      billed: parseFloat(p.total_amount_invoices) || 0,
      leftToBill: parseFloat(p.total_left_to_bill) || 0,
      url: `https://app.hubspot.com/contacts/45979252/record/0-3/${d.id}`,
      inLedger: inLedgerFromProjects.has(String(d.id))
    };
  });

  state.salesPipeline = { syncedAt: new Date().toISOString(), deals: out };
  await saveLedger(state);

  console.log('');
  const nWon = out.filter(d => d.won).length;
  console.log(`✔ Wrote ${out.length} deals (${out.length - nWon} open, ${nWon} won since ${wonFrom}).`);
  console.log(`  ${withItems} have line items (${out.length - withItems} cannot be forecast until sales adds them).`);
  console.log(`  ${withCompany} have an associated company.`);
  const nJob = out.filter(d => d.jobCode).length;
  const nBilled = out.filter(d => d.billed > 0).length;
  console.log(`  ${nJob} carry a jobcode, ${nBilled} have QuickBooks billing totals.`);
  // jobcodes that clearly are not jobcodes — someone pasted the wrong thing in
  const badJob = out.filter(d => d.jobCode && (d.jobCode.length > 24 || /\s/.test(d.jobCode)));
  if (badJob.length) {
    console.log(`  ⚠ ${badJob.length} jobcode(s) look malformed:`);
    badJob.slice(0, 5).forEach(d => console.log(`      ${d.name}: "${d.jobCode.slice(0, 60)}…"`));
  }
  const noDates = out.filter(d => !d.campaignStart || !d.campaignEnd).length;
  if (noDates) console.log(`  ⚠ ${noDates} have no campaign dates.`);
  const stale = out.filter(d => d.closeDate && d.closeDate < new Date().toISOString().slice(0, 10)).length;
  if (stale) console.log(`  ⚠ ${stale} are past their close date.`);
})();
