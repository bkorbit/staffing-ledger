// HubSpot -> Postgres.
//
// Two jobs, deliberately separate:
//
//   MIRROR     every deal into pipeline_deals, verbatim. Sync-owned, disposable,
//              replaced on every run. Sales Forecast's promotion gate reads this.
//   RETRY      call promote_approval() for every approval still sitting in
//              promotion_approvals. Promotion itself no longer happens here: a
//              human clicking Approve in Sales Forecast calls that same database
//              function directly and the deal is in the Forecast a second later
//              (078). What reaches this loop is the residue — an approval whose
//              RPC never landed (tab closed, network dropped mid-click), or one
//              deliberately held back because HubSpot's campaign dates went
//              missing after a human approved it. It is a safety net, and on a
//              healthy day it has nothing to do.
//
// The mechanical write — deal row, permanent promotion record, line-item
// flighting — lives entirely in promote_approval() (db/078). It used to live
// here, as three unrelated PostgREST round trips with no transaction around
// them, so a failure between them could leave a deal with no promotion record
// or a promoted deal with half its lines. The JS flighting math (LI_MAP,
// flightFromItems) was deleted along with it rather than left to drift against
// the SQL copy; db/078_fixture_test.sql carries its cases.
//
// Both callers enter through the same function, and the "has this HubSpot deal
// already been through the door?" check exists exactly once, inside it, under
// an advisory lock. A deal cannot promote twice even if a human clicks Approve
// at the moment this loop reaches the same row.
//
// Also refreshes name/jobcode on already-promoted deals from the current mirror
// (never flight_start/flight_end/status/hidden — those stay human/policy-owned,
// same as always) — a HubSpot rename used to silently orphan a deal from every
// name-search picker forever; this closes that gap independent of the promotion
// gate itself.
//
// Env: HUBSPOT_TOKEN, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// State: sync_state where id='hubspot'.

const HS_TOKEN     = process.env.HUBSPOT_TOKEN;
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const HS           = process.env.HS_BASE_URL || 'https://api.hubapi.com';
const STATE_ID     = 'hubspot';

const fail  = m => { throw new Error(m); };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const cents = n => Math.round((+n || 0) * 100);

function preflight() {
  const missing = [];
  if (!HS_TOKEN)     missing.push('HUBSPOT_TOKEN — repo secret, HubSpot private app token');
  if (!SERVICE_KEY)  missing.push('SUPABASE_SERVICE_ROLE_KEY — repo secret');
  if (!SUPABASE_URL) missing.push('SUPABASE_URL — repo variable');
  if (!missing.length) return;
  console.error('\n\u2716 Cannot run. Missing:');
  missing.forEach((m, i) => console.error(`   ${i + 1}. ${m}`));
  process.exit(1);
}
preflight();

const sb = { apikey: SERVICE_KEY, Authorization: 'Bearer ' + SERVICE_KEY, 'Content-Type': 'application/json' };

/* -------------------------------------------------------------- Supabase -- */

async function sbGet(path) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: sb });
  if (!r.ok) fail(`Supabase GET ${path} \u2192 ${r.status}: ${await r.text()}`);
  return r.json();
}
async function sbDelete(path) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method: 'DELETE', headers: sb });
  if (!r.ok) fail(`Supabase DELETE ${path} \u2192 ${r.status}: ${await r.text()}`);
}
async function sbUpsert(table, rows, onConflict) {
  if (!rows.length) return;
  const keys = [...new Set(rows.flatMap(Object.keys))];
  const shaped = rows.map(r => {
    const o = {};
    for (const k of keys) o[k] = r[k] === undefined ? null : r[k];
    return o;
  });
  for (let i = 0; i < shaped.length; i += 500) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}?on_conflict=${onConflict}`, {
      method: 'POST',
      headers: { ...sb, Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(shaped.slice(i, i + 500))
    });
    if (!r.ok) fail(`Supabase upsert ${table} \u2192 ${r.status}: ${(await r.text()).slice(0, 500)}`);
  }
}
// PostgREST function call. promote_approval() (078) is the only one the
// promotion path needs — the whole mechanical write is behind it.
async function sbRpc(fn, args) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST', headers: sb, body: JSON.stringify(args)
  });
  if (!r.ok) fail(`Supabase rpc ${fn} \u2192 ${r.status}: ${(await r.text()).slice(0, 500)}`);
  return r.json();
}

async function sbPatchState(patch) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/sync_state?id=eq.${STATE_ID}`, {
    method: 'PATCH', headers: { ...sb, Prefer: 'return=minimal' },
    body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() })
  });
  if (!r.ok) fail(`Supabase state write \u2192 ${r.status}: ${await r.text()}`);
}

async function die(stage, err) {
  const msg = err && err.message ? err.message : String(err);
  console.error(`\u2716 [${stage}] ${msg}`);
  try {
    await sbPatchState({
      last_run_at: new Date().toISOString(),
      last_run_log: { ok: false, stage, error: msg.slice(0, 2000), at: new Date().toISOString() }
    });
    console.error('  (recorded in sync_state.last_run_log)');
  } catch (e) {
    console.error('  (could not record it: ' + (e.message || e) + ')');
  }
  process.exit(1);
}

/* --------------------------------------------------------------- HubSpot -- */

async function hs(path, tries = 0) {
  const r = await fetch(`${HS}${path}`, {
    headers: { Authorization: 'Bearer ' + HS_TOKEN, Accept: 'application/json' }
  });
  if ((r.status === 429 || r.status >= 500) && tries < 5) {
    const wait = 1000 * Math.pow(2, tries);
    console.log(`  ${r.status} from HubSpot, retrying in ${wait}ms…`);
    await sleep(wait);
    return hs(path, tries + 1);
  }
  if (!r.ok) fail(`HubSpot ${path} \u2192 ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}

async function hsPost(path, body, tries = 0) {
  const r = await fetch(`${HS}${path}`, {
    method: 'POST',
    headers: { Authorization: 'Bearer ' + HS_TOKEN, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: JSON.stringify(body)
  });
  if ((r.status === 429 || r.status >= 500) && tries < 5) {
    await sleep(1000 * Math.pow(2, tries));
    return hsPost(path, body, tries + 1);
  }
  if (!r.ok) fail(`HubSpot ${path} \u2192 ${r.status}: ${(await r.text()).slice(0, 300)}`);
  return r.json();
}

/* ---------------------------------------------------------------- pure -- */
// Exported for tests.

// HubSpot date properties arrive as 'YYYY-MM-DD', ISO timestamps, or epoch millis
// depending on property type and API mood. Normalise to a date or null — never guess.
export function hsDate(v) {
  if (v === undefined || v === null || v === '') return null;
  const s = String(v);
  if (/^\d{4}-\d{2}-\d{2}/.test(s)) return s.slice(0, 10);
  if (/^\d+$/.test(s)) {
    const d = new Date(+s);
    return isNaN(d) ? null : d.toISOString().slice(0, 10);
  }
  return null;
}

// Company names arrive with whitespace noise and inconsistent case. The KEY is for
// matching only; the display name keeps its original form.
export function nameKey(name) {
  return String(name || '').trim().replace(/\s+/g, ' ').toLowerCase();
}

// Same jobcode convention as QuickBooks project names — the automatic join key.
// Matched lazily (leading letter + short alnum run) so a short code that itself
// carries a digit, like 'o2kl', still finds the shortest valid split. See
// sync-qbo.mjs's jobcodeFromName for the full rationale.
export function jobcodeFromName(name) {
  const m = String(name || '').match(/\b\d{2}[a-z][a-z0-9]{2,5}?\d{5,8}\b/i);
  return m ? m[0] : null;
}

// NOTE: the old promotionBlocker() lived here — the write-time re-validation
// of a deal about to promote. It moved into promote_approval() (078) with the
// rest of the write, so there is one copy of the rule instead of two. The gate
// UI keeps its own advisory checks (blocked company names, missing dates) for
// what it shows a human BEFORE they decide; that is a different question.

/* ----------------------------------------------------------------- main -- */

if (process.env.NODE_ENV !== 'test') main().catch(e => die('unhandled', e));

async function main() {
  let rows;
  try { rows = await sbGet(`sync_state?id=eq.${STATE_ID}&select=*`); }
  catch (e) { console.error('\u2716 [db-read] ' + (e.message || e)); process.exit(1); }
  if (!rows.length) fail(`No sync_state row for '${STATE_ID}'. Run db/001_init.sql.`);

  console.log('HubSpot sync');

  // ---- stage metadata: which stages mean WON, and each stage's probability ----
  const pipelines = await hs('/crm/v3/pipelines/deals');
  const stageMeta = {};
  const pipelineLabel = {};
  (pipelines.results || []).forEach(p => {
    pipelineLabel[p.id] = p.label || p.id;
    (p.stages || []).forEach(s => {
    stageMeta[s.id] = {
      label: s.label,
      won: String((s.metadata || {}).isClosedWon) === 'true' ||
           +((s.metadata || {}).probability ?? NaN) >= 1,
      probability: +((s.metadata || {}).probability ?? NaN)
    };
  });});
  console.log(`  ${Object.keys(stageMeta).length} stages across ${(pipelines.results || []).length} pipeline(s)`);

  // ---- all deals, paginated, with company associations ----
  const props = ['dealname', 'amount', 'dealstage', 'closedate',
                 'campaign_start_date', 'campaign_end_date', 'pipeline',
                 'job_code', 'qb_project_link'];
  const deals = [];
  let after = '';
  for (;;) {
    const page = await hs(`/crm/v3/objects/deals?limit=100&properties=${props.join(',')}` +
      `&associations=companies,line_items${after ? '&after=' + after : ''}`);
    deals.push(...(page.results || []));
    after = ((page.paging || {}).next || {}).after;
    if (!after) break;
    if (deals.length > 20000) { console.log('  \u26a0 over 20k deals — stopping'); break; }
  }
  console.log(`  ${deals.length} deals`);

  // ---- company names, batch-read ----
  const companyIds = [...new Set(deals.flatMap(d =>
    (((d.associations || {}).companies || {}).results || []).map(a => a.id)))];
  const companyName = {};
  for (let i = 0; i < companyIds.length; i += 100) {
    const batch = await hsPost('/crm/v3/objects/companies/batch/read', {
      properties: ['name'],
      inputs: companyIds.slice(i, i + 100).map(id => ({ id }))
    });
    (batch.results || []).forEach(c => { companyName[c.id] = (c.properties || {}).name || ''; });
  }
  console.log(`  ${companyIds.length} companies`);

  // ---- line items, batch-read: enrichment only, promotion never depends on them ----
  const liIds = [...new Set(deals.flatMap(d =>
    (((d.associations || {})['line items'] || (d.associations || {}).line_items || {}).results || [])
      .map(a => a.id)))];
  const lineItem = {};
  for (let i = 0; i < liIds.length; i += 100) {
    const batch = await hsPost('/crm/v3/objects/line_items/batch/read', {
      properties: ['name', 'amount', 'price', 'quantity'],
      inputs: liIds.slice(i, i + 100).map(id => ({ id }))
    });
    (batch.results || []).forEach(li => { lineItem[li.id] = li.properties || {}; });
  }
  if (liIds.length) console.log(`  ${liIds.length} line items (stored for reference only)`);

  // ---- mirror ----
  const mirrored = deals.map(d => {
    const p = d.properties || {};
    const meta = stageMeta[p.dealstage] || {};
    const firstCompany = ((((d.associations || {}).companies || {}).results || [])[0] || {}).id;
    const lis = ((((d.associations || {})['line items'] || (d.associations || {}).line_items || {}).results) || [])
      .map(a => lineItem[a.id]).filter(Boolean);
    return {
      hubspot_deal_id: String(d.id),
      name: p.dealname || '',
      company: companyName[firstCompany] || null,
      stage: meta.label || p.dealstage || '',
      probability: isNaN(meta.probability) ? null : meta.probability,
      amount: p.amount ? cents(p.amount) : null,
      close_date: hsDate(p.closedate),
      campaign_start: hsDate(p.campaign_start_date),
      campaign_end: hsDate(p.campaign_end_date),
      is_won: !!meta.won,
      pipeline: pipelineLabel[p.pipeline] || p.pipeline || null,
      // the explicit field wins; the name regex survives as a fallback
      jobcode: (p.job_code || '').trim() || jobcodeFromName(p.dealname),
      qbo_link: (p.qb_project_link || '').trim() || null,
      line_items: lis,
      url: `https://app.hubspot.com/contacts/deals/${d.id}`,
      synced_at: new Date().toISOString()
    };
  });
  // Full replace: the mirror is disposable by design; promotions protect history.
  await sbDelete('pipeline_deals?hubspot_deal_id=neq.__none__');
  await sbUpsert('pipeline_deals', mirrored, 'hubspot_deal_id');
  const won = mirrored.filter(m => m.is_won);
  console.log(`  mirrored ${mirrored.length} (${won.length} won)`);
  const byHsId = Object.fromEntries(mirrored.map(m => [m.hubspot_deal_id, m]));

  // ---- keep already-promoted deals findable: refresh name/jobcode from the
  // fresh mirror. name unconditionally (a pure display label — nothing reads it
  // expecting staleness); jobcode only when still null (never overwrite a
  // human- or matcher-set value, same "never guess, never clobber" contract
  // match_deals_to_projects() already holds itself to).
  const promotedRows = await sbGet('deals?hubspot_deal_id=not.is.null&select=id,hubspot_deal_id,name,jobcode');
  let refreshed = 0;
  for (const d of promotedRows) {
    const m = byHsId[d.hubspot_deal_id];
    if (!m) continue;
    const patch = {};
    if (m.name && m.name !== d.name) patch.name = m.name;
    if (!d.jobcode && m.jobcode) patch.jobcode = m.jobcode;
    if (!Object.keys(patch).length) continue;
    patch.set_by = 'hubspot-sync:refresh'; patch.set_at = new Date().toISOString();
    const r = await fetch(`${SUPABASE_URL}/rest/v1/deals?id=eq.${d.id}`, {
      method: 'PATCH', headers: { ...sb, Prefer: 'return=minimal' }, body: JSON.stringify(patch)
    });
    if (!r.ok) fail(`Supabase refresh deals ${d.id} → ${r.status}: ${(await r.text()).slice(0, 300)}`);
    refreshed++;
  }
  if (refreshed) console.log(`  refreshed name/jobcode for ${refreshed} already-promoted deal(s)`);

  // ---- promotion retry. The Approve button already ran promote_approval()
  // for each of these the moment a human clicked it, so an approval reaching
  // this loop is one whose call never landed, or one the function itself held
  // back (HubSpot's campaign dates changed after approval — the database
  // contract is that a won deal has a flight, and it is respected rather than
  // worked around). Held-back approvals STAY queued and are retried every
  // night until HubSpot is fixed or a human dismisses the deal. The mirror is
  // rewritten above before this runs, so the function reads current data.
  const approvals = await sbGet('promotion_approvals?select=hubspot_deal_id');

  let promoted = 0, flighted = 0, unflighted = [], stale = 0;
  const heldBack = [];

  for (const a of approvals) {
    let res;
    try {
      res = await sbRpc('promote_approval', { p_hubspot_deal_id: a.hubspot_deal_id });
    } catch (e) {
      // one bad approval must not abort the run — the mirror is already
      // written and the matcher below still has work to do
      heldBack.push(`${a.hubspot_deal_id}: promote_approval failed — ` +
        String(e && e.message ? e.message : e).slice(0, 200));
      continue;
    }
    const label = res.deal_name || a.hubspot_deal_id;
    // already through the door (the browser's call DID land, or this is a
    // re-run after a partial failure): the function consumed the approval itself
    if (res.already) { stale++; continue; }
    if (!res.ok) { heldBack.push(`${label}: ${res.reason}`); continue; }
    promoted++;
    if (res.flighted) flighted++; else unflighted.push(`${label}: ${res.reason}`);
  }

  if (!approvals.length) {
    console.log('  promotion retry: nothing queued — approvals promote in the browser now');
  } else {
    console.log(`  promotion retry: ${approvals.length} approval(s) were still queued — ` +
      `${promoted} promoted, ${stale} already done (cleared), ${heldBack.length} held back` +
      (heldBack.length ? ':' : ''));
    heldBack.slice(0, 5).forEach(r => console.log(`    ${r}`));
    if (flighted || unflighted.length)
      console.log(`  flighted ${flighted} of them from line items; ${unflighted.length} left as skeletons` +
        (unflighted.length ? ' — ' + unflighted.slice(0, 5).join(' | ') : ''));
  }

  // With the mirror fresh and promotions done, link any still-unmatched
  // promoted deal to its QuickBooks project: QB link first, then unambiguous
  // jobcode. A residual safety net (e.g. a QBO project that didn't exist yet
  // at promotion time and synced in later) — idempotent, never guesses, and
  // never touches a deal a human already matched at the gate.
  let matchLog = null;
  try {
    matchLog = await sbRpc('match_deals_to_projects', {});
    console.log('  deal↔project matching: ' +
      matchLog.map(m => `${m.method} ${m.matched}`).join(' · '));
  } catch (e) {
    console.log('  ⚠ matcher failed (sync data is fine): ' + (e.message || e));
  }

  await sbPatchState({
    last_run_at: new Date().toISOString(),
    last_run_log: {
      ok: true,
      matching: matchLog,
      flighted, unflighted: unflighted.slice(0, 20),
      deals: mirrored.length, won: won.length,
      name_jobcode_refreshed: refreshed,
      promoted, held_back: heldBack.slice(0, 20), approvals_pending: approvals.length - promoted - stale,
      at: new Date().toISOString()
    }
  });
  console.log('✔ Done.');
}
