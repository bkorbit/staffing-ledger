// Pull QuickBooks Online revenue and cost into Supabase for the EMG ledger.
//
//   projects   Customers flagged as jobs (QuickBooks Projects) — the join key
//   invoices   revenue, line by line, so contra-revenue items can be excluded
//   costs      vendor bills and credit card charges, attributed per line
//   items      the product list, mapped to ledger types in Settings
//
// Labour is deliberately absent. Hours and their cost come from QuickBooks Time via
// sync-qbtime.mjs; pulling payroll from QBO as well would double-count it.
//
// The whole import window is REPLACED on every run. Invoices are deleted rather than
// voided in this QuickBooks file, and a deleted record simply stops appearing in the
// API — an incremental sync would leave it behind forever.
//
// Secrets:  QBO_CLIENT_ID, QBO_CLIENT_SECRET, SUPABASE_SERVICE_ROLE_KEY
// State:    qb_sync_state holds realm_id, import_from and the rotating refresh token.

const CLIENT_ID = process.env.QBO_CLIENT_ID;
const CLIENT_SECRET = process.env.QBO_CLIENT_SECRET;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = 'https://bdtzpeazcjgnsxodwzpz.supabase.co';
const QBO = 'https://quickbooks.api.intuit.com/v3/company';
const TOKEN_URL = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';
const MINOR = '75';
const JOBCODE_RE = /\b\d{2}[a-z]{3,6}\d{5,8}\b/i;   // e.g. 26hawt260810

const fail = m => { console.error('✖ ' + m); process.exit(1); };
if (!CLIENT_ID || !CLIENT_SECRET) fail('Missing QBO_CLIENT_ID / QBO_CLIENT_SECRET.');
if (!SERVICE_KEY) fail('Missing SUPABASE_SERVICE_ROLE_KEY.');

const sb = { apikey: SERVICE_KEY, Authorization: 'Bearer ' + SERVICE_KEY, 'Content-Type': 'application/json' };
const sleep = ms => new Promise(r => setTimeout(r, ms));
const money = n => Math.round((+n || 0) * 100) / 100;

/* ---------------------------------------------------------------- Supabase */

async function sbGet(path) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: sb });
  if (!r.ok) fail(`Supabase GET ${path} → ${r.status}: ${await r.text()}`);
  return r.json();
}
async function sbDelete(path) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method: 'DELETE', headers: sb });
  if (!r.ok) fail(`Supabase DELETE ${path} → ${r.status}: ${await r.text()}`);
}
async function sbUpsert(table, rows, onConflict = 'id') {
  if (!rows.length) return;
  for (let i = 0; i < rows.length; i += 500) {
    const chunk = rows.slice(i, i + 500);
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}?on_conflict=${onConflict}`, {
      method: 'POST',
      headers: { ...sb, Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(chunk)
    });
    if (!r.ok) fail(`Supabase upsert ${table} → ${r.status}: ${(await r.text()).slice(0, 400)}`);
  }
}
async function sbPatchState(patch) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/qb_sync_state?id=eq.default`, {
    method: 'PATCH', headers: { ...sb, Prefer: 'return=minimal' }, body: JSON.stringify(patch)
  });
  if (!r.ok) fail(`Supabase state write → ${r.status}: ${await r.text()}`);
}

/* ---------------------------------------------------------------- QuickBooks */

// The refresh token rotates on every use. It is written back before any other work so
// a later failure can never strand the integration on a token that has been consumed.
async function refreshAccess(refreshToken) {
  const basic = Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString('base64');
  const r = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { Authorization: 'Basic ' + basic, 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken })
  });
  const body = await r.text();
  if (!r.ok) fail(`Token refresh → ${r.status}: ${body.slice(0, 300)}\n` +
    'If this says invalid_grant the refresh token has expired (100 days unused) — re-authorise and reseed it.');
  const j = JSON.parse(body);
  if (j.refresh_token && j.refresh_token !== refreshToken) {
    await sbPatchState({ refresh_token: j.refresh_token });
    console.log('  refresh token rotated and saved');
  }
  return j.access_token;
}

async function qboQuery(realm, token, sql, tries = 0) {
  const url = `${QBO}/${realm}/query?minorversion=${MINOR}&query=${encodeURIComponent(sql)}`;
  const r = await fetch(url, { headers: { Authorization: 'Bearer ' + token, Accept: 'application/json' } });
  if ((r.status === 429 || r.status >= 500) && tries < 5) {
    const wait = 1000 * Math.pow(2, tries);
    console.log(`  ${r.status} from QuickBooks, retrying in ${wait}ms…`);
    await sleep(wait);
    return qboQuery(realm, token, sql, tries + 1);
  }
  if (!r.ok) fail(`QuickBooks query → ${r.status}: ${(await r.text()).slice(0, 400)}\n  query: ${sql}`);
  return (await r.json()).QueryResponse || {};
}

// QuickBooks caps a page at 1000 and offers no cursor, so walk STARTPOSITION.
async function qboAll(realm, token, entity, where) {
  const out = [];
  let start = 1;
  for (;;) {
    const sql = `SELECT * FROM ${entity}${where ? ' WHERE ' + where : ''} STARTPOSITION ${start} MAXRESULTS 1000`;
    const q = await qboQuery(realm, token, sql);
    const batch = q[entity] || [];
    out.push(...batch);
    if (batch.length < 1000) break;
    start += 1000;
    if (start > 40000) { console.log(`  ⚠ ${entity} exceeded 40k rows — stopping.`); break; }
  }
  return out;
}

/* ---------------------------------------------------------------- helpers */

const customFieldValue = (inv, label) => {
  const f = (inv.CustomField || []).find(x => String(x.Name || '').trim().toLowerCase() === label);
  return f ? String(f.StringValue || '').trim() : '';
};
const jobcodeFromName = name => { const m = String(name || '').match(JOBCODE_RE); return m ? m[0] : ''; };

// Bills and card charges carry the project on the line, in whichever detail block the
// line happens to use, so check both.
const lineProject = l => {
  const d = l.AccountBasedExpenseLineDetail || l.ItemBasedExpenseLineDetail || {};
  return (d.CustomerRef || {}).value || null;
};

/* ---------------------------------------------------------------- main */

(async () => {
  const [st] = await sbGet('qb_sync_state?id=eq.default&select=*');
  if (!st) fail('No qb_sync_state row — run the schema SQL first.');
  if (!st.refresh_token) fail('No refresh token stored. Authorise QuickBooks once and seed qb_sync_state.refresh_token.');
  if (!st.realm_id) fail('No realm_id stored. Put your QuickBooks company id in qb_sync_state.realm_id.');

  const realm = st.realm_id;
  const from = st.import_from || '2026-01-01';
  console.log(`QuickBooks sync · realm ${realm} · from ${from}`);

  const token = await refreshAccess(st.refresh_token);

  // ---- projects (sub-customers flagged as jobs) ----
  const customers = await qboAll(realm, token, 'Customer');
  const byId = Object.fromEntries(customers.map(c => [c.Id, c]));
  const projects = customers.filter(c => c.Job === true || c.ParentRef);
  await sbUpsert('qb_projects', projects.map(c => ({
    id: c.Id,
    name: c.DisplayName || c.FullyQualifiedName || '',
    jobcode: jobcodeFromName(c.DisplayName || c.FullyQualifiedName),
    parent_id: (c.ParentRef || {}).value || null,
    parent_name: (c.ParentRef || {}).value && byId[(c.ParentRef || {}).value]
      ? byId[(c.ParentRef || {}).value].DisplayName : ((c.ParentRef || {}).name || null),
    active: c.Active !== false,
    synced_at: new Date().toISOString()
  })));
  const projectIds = new Set(projects.map(p => p.Id));
  console.log(`  ${customers.length} customers · ${projects.length} projects`);

  // ---- items ----
  const items = await qboAll(realm, token, 'Item');
  await sbUpsert('qb_items', items.map(i => ({
    id: i.Id, name: i.Name || '', fully_qualified_name: i.FullyQualifiedName || i.Name || '',
    type: i.Type || '', income_account: (i.IncomeAccountRef || {}).name || '',
    expense_account: (i.ExpenseAccountRef || {}).name || '',
    purchase_cost: money(i.PurchaseCost), active: i.Active !== false,
    synced_at: new Date().toISOString()
  })));
  console.log(`  ${items.length} items`);

  // ---- replace the window ----
  await sbDelete(`qb_invoices?txn_date=gte.${from}`);
  await sbDelete(`qb_costs?txn_date=gte.${from}`);

  // ---- invoices ----
  const invoices = await qboAll(realm, token, 'Invoice', `TxnDate >= '${from}'`);
  const invRows = [], invLines = [];
  let excluded = 0, excludedValue = 0;
  invoices.forEach(inv => {
    const custId = (inv.CustomerRef || {}).value || null;
    const isProject = custId && projectIds.has(custId);
    const jobcode = customFieldValue(inv, 'account') || (isProject ? jobcodeFromName((inv.CustomerRef || {}).name) : '');
    if (!isProject) { excluded++; excludedValue += money(inv.TotalAmt); }
    invRows.push({
      id: inv.Id, doc_number: inv.DocNumber || '', txn_date: String(inv.TxnDate).slice(0, 10),
      project_id: isProject ? custId : null, jobcode,
      customer_name: (inv.CustomerRef || {}).name || '',
      total: money(inv.TotalAmt), balance: money(inv.Balance),
      currency: (inv.CurrencyRef || {}).value || 'USD',
      excluded: !isProject, exclude_reason: isProject ? null : 'no project on invoice',
      synced_at: new Date().toISOString()
    });
    (inv.Line || []).forEach((l, n) => {
      if (!l.SalesItemLineDetail && l.DetailType !== 'SalesItemLineDetail') return;
      const d = l.SalesItemLineDetail || {};
      invLines.push({
        id: `${inv.Id}:${l.Id || n}`, invoice_id: inv.Id, line_num: +l.LineNum || n + 1,
        item_id: (d.ItemRef || {}).value || null, item_name: (d.ItemRef || {}).name || '',
        description: l.Description || '', qty: +d.Qty || null,
        unit_price: d.UnitPrice !== undefined ? +d.UnitPrice : null, amount: money(l.Amount)
      });
    });
  });
  await sbUpsert('qb_invoices', invRows);
  await sbUpsert('qb_invoice_lines', invLines);
  console.log(`  ${invoices.length} invoices · ${invLines.length} lines` +
    (excluded ? ` · ${excluded} excluded (no project, ${excludedValue.toLocaleString()})` : ''));

  // ---- costs: vendor bills and credit card charges ----
  const bills = await qboAll(realm, token, 'Bill', `TxnDate >= '${from}'`);
  const purchases = await qboAll(realm, token, 'Purchase', `TxnDate >= '${from}'`);
  const costRows = [], costLines = [];
  const addCost = (kind, t, vendorName) => {
    costRows.push({
      id: `${kind}:${t.Id}`, kind, txn_date: String(t.TxnDate).slice(0, 10),
      project_id: null,                       // attribution happens per line
      vendor_name: vendorName || '', total: money(t.TotalAmt),
      currency: (t.CurrencyRef || {}).value || 'USD', synced_at: new Date().toISOString()
    });
    (t.Line || []).forEach((l, n) => {
      const d = l.AccountBasedExpenseLineDetail || l.ItemBasedExpenseLineDetail || {};
      const pid = lineProject(l);
      costLines.push({
        id: `${kind}:${t.Id}:${l.Id || n}`, cost_id: `${kind}:${t.Id}`, line_num: +l.LineNum || n + 1,
        item_id: (d.ItemRef || {}).value || null, item_name: (d.ItemRef || {}).name || '',
        account_name: (d.AccountRef || {}).name || '', description: l.Description || '',
        amount: money(l.Amount), project_id: pid && projectIds.has(pid) ? pid : null
      });
    });
  };
  bills.forEach(b => addCost('bill', b, (b.VendorRef || {}).name));
  purchases.forEach(p => addCost('purchase', p, (p.EntityRef || {}).name || p.PaymentType || ''));
  await sbUpsert('qb_costs', costRows);
  await sbUpsert('qb_cost_lines', costLines);
  const attributed = costLines.filter(l => l.project_id).length;
  console.log(`  ${bills.length} bills · ${purchases.length} card charges · ` +
    `${costLines.length} cost lines (${attributed} attributed to a project)`);

  // ---- unmapped items, so nothing counts as revenue unnoticed ----
  const mapped = new Set((await sbGet('qb_item_map?select=item_name')).map(m => String(m.item_name).toLowerCase()));
  const unmapped = [...new Set(invLines.map(l => l.item_name).filter(Boolean)
    .filter(n => !mapped.has(n.split(':').pop().trim().toLowerCase())))];
  if (unmapped.length) {
    console.log(`  ⚠ ${unmapped.length} invoice item(s) not mapped in Settings — counting as revenue by default:`);
    unmapped.slice(0, 15).forEach(n => console.log(`      ${n}`));
  }

  await sbPatchState({
    last_run_at: new Date().toISOString(),
    last_run_log: {
      from, projects: projects.length, items: items.length,
      invoices: invoices.length, invoice_lines: invLines.length,
      excluded_invoices: excluded, excluded_value: excludedValue,
      bills: bills.length, purchases: purchases.length,
      cost_lines: costLines.length, cost_lines_attributed: attributed,
      unmapped_items: unmapped
    }
  });
  console.log('✔ Done.');
})();
