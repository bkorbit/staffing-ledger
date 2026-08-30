// HubSpot -> Postgres.
//
// Two jobs, deliberately separate:
//
//   MIRROR     every deal into pipeline_deals, verbatim. Sync-owned, disposable,
//              replaced on every run. Sales Forecast's promotion gate reads this.
//   PROMOTE    consume promotion_approvals — a human's decision, made in Sales
//              Forecast, to promote one specific won deal with a specific client
//              and QBO project already picked. This is the mechanical write only:
//              create the deal, record the promotion forever, flight the line
//              items. It does NOT decide whether a deal should promote or which
//              client/project it belongs to — a human already decided that, in
//              the browser, before this ever runs. (Before this file's rewrite,
//              promotion was a fully-automatic nightly door with no human review
//              at all — fine for one-time historical backfill, wrong for a tool
//              meant to run indefinitely against real client billing.)
//
// What promotion does NOT do: touch deal lines by hand. Line items in HubSpot have
// not been enforced, so the as-sold amount travels in the promotion snapshot for
// reference and humans shape MOST forecast lines in the platform, but when a won
// deal's line items map cleanly onto ledger types, promotion flights them out
// automatically — budgets spread evenly over the flight, fees attached — still
// unreviewed until a human blesses them. One unmapped item and NO lines are
// created: a skeleton plus a reason beats a half-invented plan.
//
// An approval whose campaign dates are missing or invalid (changed in HubSpot
// after a human approved it, say) is held back, not forced through with
// defaults — the database constraint (won deals must have a flight) is the
// contract; the sync respects it rather than working around it. It stays queued
// and promotes on a later run once fixed.
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
async function sbInsert(table, rows, { returning = false } = {}) {
  if (!rows.length) return [];
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}`, {
    method: 'POST',
    headers: { ...sb, Prefer: returning ? 'return=representation' : 'return=minimal' },
    body: JSON.stringify(rows)
  });
  if (!r.ok) fail(`Supabase insert ${table} \u2192 ${r.status}: ${(await r.text()).slice(0, 500)}`);
  return returning ? r.json() : [];
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
// ---- line items -> deal lines, the same type map the Sales page uses ----------
export const LI_MAP = {
  'programmatic media': ['programmatic', 'budget'], 'programmatic buying fee': ['programmatic', 'fee'],
  'paid search media': ['search', 'budget'], 'paid search fee': ['search', 'fee'],
  'paid social media': ['social', 'budget'], 'paid social fee': ['social', 'fee'],
  'paid search hourly': ['retainer', 'flat'], 'paid social hourly': ['retainer', 'flat'],
  'creative retainer': ['retainer', 'flat'], 'creative services': ['retainer', 'flat'],
  'planning': ['retainer', 'flat'], 'dashboard': ['retainer', 'flat'],
};

export function monthsOf(a, b) {
  const out = []; let d = new Date(a + 'T00:00:00Z'); const end = new Date(b + 'T00:00:00Z');
  while (d <= end && out.length < 48) { out.push(d.toISOString().slice(0, 10));
    d = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth() + 1, 1)); }
  return out;
}

// Returns { lines:[{kind,fee_pct,amount,months:{iso:budgetCents}}], reason } —
// lines only when EVERY item maps; total cents preserved against rounding by
// putting the remainder on the last month.
export function flightFromItems(items, flightStart, flightEnd) {
  if (!items || !items.length) return { lines: [], reason: 'no line items' };
  const months = monthsOf(flightStart, flightEnd);
  if (!months.length) return { lines: [], reason: 'no flight months' };
  const byType = {};
  for (const li of items) {
    const key = String(li.name || '').split(':').pop().trim().toLowerCase();
    const m = LI_MAP[key];
    if (!m) return { lines: [], reason: 'unmapped line item: ' + (li.name || '?') };
    const cents = Math.round(parseFloat(li.amount || 0) * 100);
    const [type, role] = m;
    (byType[type] = byType[type] || { budget: 0, fee: 0, flat: 0 })[role] += cents;
  }
  const spread = total => {
    const per = Math.floor(total / months.length), out = {};
    months.forEach((m, i) => out[m] = per + (i === months.length - 1 ? total - per * months.length : 0));
    return out;
  };
  const lines = [];
  for (const [type, v] of Object.entries(byType)) {
    if (type === 'retainer') {
      const flat = v.flat + v.fee + v.budget;
      if (flat > 0) lines.push({ kind: 'retainer',
        amount: Math.round(flat / months.length), fee_pct: 0, months: null });
    } else {
      if (v.budget > 0) {
        const feePct = v.fee > 0 ? +(v.fee / v.budget * 100).toFixed(2) : 0;
        lines.push({ kind: type, amount: 0, fee_pct: feePct, months: spread(v.budget) });
      } else if (v.fee > 0) {
        // a fee with no media: a flat monthly amount is the honest shape
        lines.push({ kind: 'retainer',
          amount: Math.round(v.fee / months.length), fee_pct: 0, months: null });
      }
    }
  }
  return lines.length ? { lines } : { lines: [], reason: 'items sum to nothing' };
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

// The flight is stored as first-of-month dates (database constraint). A campaign
// running Aug 14 to Nov 20 flies Aug through Nov.
export function monthStart(dateStr) {
  return dateStr ? dateStr.slice(0, 8) + '01' : null;
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

// Why a won deal cannot promote, or null if it can. The reasons are the run log's
// vocabulary, so keep them short and stable. blockedNames is a set of
// nameKey()-normalized company names a human has marked "don't match" on the
// Clients tab (029) — checked right alongside "no company", since both mean
// there's no client this deal should attach to yet.
export function promotionBlocker(deal, blockedNames = new Set()) {
  if (!deal.company)         return 'no company';
  if (blockedNames.has(nameKey(deal.company))) return 'company name blocked (see Clients tab)';
  if (!deal.campaign_start)  return 'no campaign start date';
  if (!deal.campaign_end)    return 'no campaign end date';
  if (deal.campaign_end < deal.campaign_start) return 'campaign ends before it starts';
  return null;
}

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

  // ---- promotion: consume a human's decision, not decide one. Every row in
  // promotion_approvals is a deal a person reviewed in Sales Forecast and
  // confirmed a client + QBO project for; this just does the mechanical write
  // that used to happen automatically. See db/060 for why there's no FK here.
  const approvals = await sbGet('promotion_approvals?select=*');
  const already = new Set((await sbGet('promotions?select=hubspot_deal_id'))
    .map(r => r.hubspot_deal_id));

  let promoted = 0, flighted = 0, unflighted = [], stale = 0;
  const heldBack = [];

  for (const a of approvals) {
    // already promoted (e.g. a re-run after a partial failure) — the approval
    // has done its job, clear it rather than leaving it queued forever
    if (already.has(a.hubspot_deal_id)) {
      await sbDelete(`promotion_approvals?hubspot_deal_id=eq.${a.hubspot_deal_id}`);
      stale++;
      continue;
    }
    const m = byHsId[a.hubspot_deal_id];
    if (!m) { heldBack.push(`${a.hubspot_deal_id}: no longer in the HubSpot mirror`); continue; }
    // re-validate campaign dates at the moment of the actual write — they were
    // valid when a human approved this, but HubSpot could have changed since
    const blocker = promotionBlocker(m);
    if (blocker) { heldBack.push(`${m.name || a.hubspot_deal_id}: ${blocker}`); continue; }

    const [deal] = await sbInsert('deals', [{
      client_id: a.client_id,
      name: m.name || 'Unnamed deal',
      status: 'won',
      origin: 'hubspot',
      // exact HubSpot campaign dates, not month-truncated — 022 dropped the
      // schema's first-of-month constraint and taught v_deal_month_forecast
      // to date_trunc internally for its own month series; this was the one
      // remaining place still throwing the day precision away at the door
      flight_start: m.campaign_start,
      flight_end: m.campaign_end,
      hubspot_deal_id: m.hubspot_deal_id,
      jobcode: m.jobcode,
      qbo_project_id: a.qbo_project_id,
      promoted_at: new Date().toISOString(),
      set_by: a.approved_by
    }], { returning: true });

    await sbInsert('promotions', [{
      hubspot_deal_id: m.hubspot_deal_id,
      deal_id: deal.id,
      promoted_by: a.approved_by,   // the real human who approved it, not 'hubspot-sync'
      source_payload: m             // the as-sold record, amount included, forever
    }]);
    promoted++;

    // flight the line items out when they map cleanly; otherwise leave the
    // skeleton and say why
    const fl = flightFromItems(m.line_items, monthStart(m.campaign_start), monthStart(m.campaign_end));
    if (!fl.lines.length) {
      unflighted.push(`${m.name}: ${fl.reason}`);
    } else {
      for (const ln of fl.lines) {
        const [row] = await sbInsert('deal_lines', [{
          deal_id: deal.id, kind: ln.kind, amount: ln.amount, budget: 0,
          fee_pct: ln.fee_pct, hours_per_month: 0, rate: 0,
          billing_day: ln.kind === 'retainer' ? 'first' : 'last',
          set_by: 'hubspot-sync:line-items'
        }], { returning: true });
        if (ln.months) {
          await sbInsert('deal_line_months', Object.entries(ln.months).map(([mo, b]) => ({
            deal_line_id: row.id, month: mo, budget: b, set_by: 'hubspot-sync:line-items'
          })));
        }
      }
      flighted++;
    }

    await sbDelete(`promotion_approvals?hubspot_deal_id=eq.${a.hubspot_deal_id}`);
  }

  if (flighted || unflighted.length)
    console.log(`  flighted ${flighted} promoted deal(s) from line items; ` +
      `${unflighted.length} left as skeletons` +
      (unflighted.length ? ' — ' + unflighted.slice(0, 5).join(' | ') : ''));
  console.log(`  promoted ${promoted} approved deal(s)` + (stale ? ` (${stale} approval(s) already done, cleared)` : '') +
    (heldBack.length ? `, ${heldBack.length} approval(s) held back:` : ''));
  heldBack.slice(0, 5).forEach(r => console.log(`    ${r}`));

  // With the mirror fresh and promotions done, link any still-unmatched
  // promoted deal to its QuickBooks project: QB link first, then unambiguous
  // jobcode. A residual safety net (e.g. a QBO project that didn't exist yet
  // at promotion time and synced in later) — idempotent, never guesses, and
  // never touches a deal a human already matched at the gate.
  let matchLog = null;
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/match_deals_to_projects`, {
      method: 'POST', headers: sb, body: '{}'
    });
    if (!r.ok) throw new Error(`${r.status}: ${(await r.text()).slice(0, 200)}`);
    matchLog = await r.json();
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
