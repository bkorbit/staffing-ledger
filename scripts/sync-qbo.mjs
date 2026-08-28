// QuickBooks Online -> Postgres.
//
// Writes the cash domain: what we invoiced, what was collected, what we owe, what we
// paid, and what is in the bank. Everything here is an ACTUAL. This sync never writes
// a forecast, never sets a flight, and never touches a deal.
//
//   invoices / invoice_lines   what was billed, with DUE DATE and TERMS
//   payments                   when customers actually paid          [new]
//   bills / bill_lines         what we owe, with DUE DATE and BALANCE
//   bill_payments              when we actually paid vendors         [new]
//   cash_accounts              bank balances, for the cashflow opening position [new]
//
// The due dates and the two payment tables are the point of this rewrite. Without them
// there is no cashflow forecast, only an AR total. With them, expected collection and
// expected payment become OBSERVED distributions rather than assumptions.
//
// Attribution is deliberately dumb: rows land carrying qbo_project_id, and client_id /
// deal_id are resolved afterwards through qbo_project_links. Matching is human
// judgement and does not belong in a sync.
//
// Env: QBO_CLIENT_ID, QBO_CLIENT_SECRET, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// State: sync_state where id='quickbooks' — realm_id, import_from, rotating refresh token.

const CLIENT_ID    = process.env.QBO_CLIENT_ID;
const CLIENT_SECRET= process.env.QBO_CLIENT_SECRET;
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;   // no longer hardcoded
const QBO       = 'https://quickbooks.api.intuit.com/v3/company';
const TOKEN_URL = 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';
const MINOR     = '75';
const STATE_ID  = 'quickbooks';

const fail  = m => { console.error('\u2716 ' + m); process.exit(1); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

// Anything that goes wrong after the credentials check is recorded in sync_state
// before exiting, so a failure is queryable from the database rather than only
// visible in an Actions log. Best-effort: if the database itself is what failed,
// the console message is all there is.
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

// Money is stored as integer cents. Rounding once here means no float ever reaches the
// database, so sums are exact and the earned/invoiced/collected distinction can never
// hide behind a rounding artefact.
const cents = n => Math.round((+n || 0) * 100);
const day   = v => (v === undefined || v === null || v === '') ? null : String(v).slice(0, 10);

function preflight() {
  const missing = [];
  if (!CLIENT_ID)     missing.push('QBO_CLIENT_ID — repo secret, from your Intuit app');
  if (!CLIENT_SECRET) missing.push('QBO_CLIENT_SECRET — repo secret, same app');
  if (!SERVICE_KEY)   missing.push('SUPABASE_SERVICE_ROLE_KEY — repo secret (the sb_secret_… key)');
  if (!SUPABASE_URL)  missing.push('SUPABASE_URL — repo variable, e.g. https://xxxx.supabase.co');
  if (!missing.length) return;
  console.error('\n\u2716 Cannot run. ' + missing.length + ' missing:');
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
async function sbUpsert(table, rows, onConflict = 'id') {
  if (!rows.length) return;
  for (let i = 0; i < rows.length; i += 500) {
    const chunk = rows.slice(i, i + 500);
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}?on_conflict=${onConflict}`, {
      method: 'POST',
      headers: { ...sb, Prefer: 'resolution=merge-duplicates,return=minimal' },
      body: JSON.stringify(chunk)
    });
    if (!r.ok) fail(`Supabase upsert ${table} \u2192 ${r.status}: ${(await r.text()).slice(0, 500)}`);
  }
}
async function sbPatchState(patch) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/sync_state?id=eq.${STATE_ID}`, {
    method: 'PATCH', headers: { ...sb, Prefer: 'return=minimal' },
    body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() })
  });
  if (!r.ok) fail(`Supabase state write \u2192 ${r.status}: ${await r.text()}`);
}

/* ------------------------------------------------------------ QuickBooks -- */

// The refresh token rotates on every use. It is written back BEFORE any other work, so
// a later failure can never strand the integration on a token already consumed.
async function refreshAccess(refreshToken) {
  const basic = Buffer.from(`${CLIENT_ID}:${CLIENT_SECRET}`).toString('base64');
  const r = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { Authorization: 'Basic ' + basic, 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({ grant_type: 'refresh_token', refresh_token: refreshToken })
  });
  const body = await r.text();
  if (!r.ok) fail(`Token refresh \u2192 ${r.status}: ${body.slice(0, 300)}\n` +
    'invalid_grant means the refresh token expired (100 days unused) — re-authorise and reseed sync_state.');
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
  if (!r.ok) throw new Error(`QuickBooks query \u2192 ${r.status}: ${(await r.text()).slice(0, 400)}`);
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
    if (start > 60000) { console.log(`  \u26a0 ${entity} exceeded 60k rows — stopping.`); break; }
  }
  return out;
}

/* ---------------------------------------------------------------- pure -- */
// Exported for tests. These are where the bugs live, and they need no network.

// Terms are free text in QuickBooks ("Net 45", "NET30", "Due on receipt", "2/10 Net 30").
// Return the net days, or null when it cannot be read rather than guessing a default —
// a wrong term silently shifts a whole month of cash.
export function netDaysFromTerms(terms) {
  if (!terms) return null;
  const t = String(terms).toLowerCase();
  if (/due on receipt|on receipt|cod|immediate/.test(t)) return 0;
  const net = t.match(/net\s*(\d{1,3})/);
  if (net) return +net[1];
  const bare = t.match(/^(\d{1,3})\s*days?$/);
  if (bare) return +bare[1];
  return null;
}

// A due date QuickBooks did not supply, derived from terms. Falls back to null, never
// to an assumed 30 — an invented due date is worse than a missing one because the
// cashflow forecast cannot tell it apart from a real one.
export function deriveDueDate(issuedOn, terms) {
  const n = netDaysFromTerms(terms);
  if (n === null || !issuedOn) return null;
  const d = new Date(issuedOn + 'T00:00:00Z');
  d.setUTCDate(d.getUTCDate() + n);
  return d.toISOString().slice(0, 10);
}

// Payments carry Line[].LinkedTxn[] pointing at the invoices they settle, and one
// payment can cover several invoices. Split it into one row per linked invoice so the
// lag between an invoice and its money is measurable per invoice.
export function splitPaymentLines(pmt) {
  const out = [];
  const paidOn = day(pmt.TxnDate);
  (pmt.Line || []).forEach((l, i) => {
    (l.LinkedTxn || []).forEach((lt, j) => {
      if (lt.TxnType !== 'Invoice') return;
      out.push({
        id: `${pmt.Id}:${i}:${j}`,
        invoice_id: String(lt.TxnId),
        paid_on: paidOn,
        amount: cents(l.Amount)
      });
    });
  });
  // A payment with no linked invoice is a deposit or a prepayment. Keep it, unlinked,
  // so total cash in still reconciles even though it cannot be attributed.
  if (!out.length && (+pmt.TotalAmt || 0) !== 0) {
    out.push({ id: String(pmt.Id), invoice_id: null, paid_on: paidOn, amount: cents(pmt.TotalAmt) });
  }
  return out;
}

// Same shape for money out. BillPayment lines link to Bill txns.
export function splitBillPaymentLines(bp) {
  const out = [];
  const paidOn = day(bp.TxnDate);
  (bp.Line || []).forEach((l, i) => {
    (l.LinkedTxn || []).forEach((lt, j) => {
      if (lt.TxnType !== 'Bill') return;
      out.push({
        id: `${bp.Id}:${i}:${j}`,
        bill_id: `bill:${lt.TxnId}`,
        paid_on: paidOn,
        amount: cents(l.Amount)
      });
    });
  });
  if (!out.length && (+bp.TotalAmt || 0) !== 0) {
    out.push({ id: String(bp.Id), bill_id: null, paid_on: paidOn, amount: cents(bp.TotalAmt) });
  }
  return out;
}

// Project id on an expense line, wherever QuickBooks decided to put it.
export function lineProject(l) {
  const d = l.AccountBasedExpenseLineDetail || l.ItemBasedExpenseLineDetail || {};
  const e = d.CustomerRef || d.Entity || {};
  return e.value ? String(e.value) : null;
}

/* ----------------------------------------------------------------- main -- */

if (process.env.NODE_ENV !== 'test') main().catch(e => die('unhandled', e));

async function main() {
  const rows = await sbGet(`sync_state?id=eq.${STATE_ID}&select=*`);
  if (!rows.length) fail(`No sync_state row for '${STATE_ID}'. Run db/001_init.sql.`);
  const state = rows[0];
  if (!state.refresh_token) fail(
    "No refresh token. Authorise once in Intuit's OAuth playground, then:\n" +
    `  update sync_state set refresh_token='…', realm_id='…' where id='${STATE_ID}';`);
  if (!state.realm_id) fail(`No realm_id. update sync_state set realm_id='…' where id='${STATE_ID}';`);

  const from = day(state.import_from) || '2025-01-01';
  console.log(`QuickBooks Online sync — window from ${from}`);

  const token = await refreshAccess(state.refresh_token).catch(e => die('token-refresh', e));
  const realm = state.realm_id;

  // Probe before the real work. A refresh can succeed while the realm is wrong, and
  // the resulting error is far clearer here than buried in the first bulk query.
  try {
    const probe = await qboQuery(realm, token, 'SELECT COUNT(*) FROM Invoice');
    console.log(`  connected to realm ${realm} — ${probe.totalCount ?? '?'} invoices in the file`);
  } catch (e) {
    await die('realm-check', new Error(
      `realm_id '${realm}' was rejected. The token refreshed fine, so the credentials are ` +
      `good but the company id is wrong. Check the realmId shown in the OAuth playground. (${e.message || e})`));
  }

  // ---- bank accounts: the cashflow opening position ----
  const accounts = await qboAll(realm, token, 'Account', "AccountType = 'Bank'");
  await sbUpsert('cash_accounts', accounts.map(a => ({
    id: String(a.Id),
    name: a.Name || '',
    account_type: a.AccountSubType || a.AccountType || '',
    balance: cents(a.CurrentBalance),
    as_of: new Date().toISOString().slice(0, 10),
    synced_at: new Date().toISOString()
    // is_operating deliberately NOT written — a human ticks that in Settings and the
    // sync must not clobber the choice on every run.
  })), 'id');
  console.log(`  ${accounts.length} bank accounts, total ` +
    (accounts.reduce((s, a) => s + (+a.CurrentBalance || 0), 0)).toLocaleString());

  // ---- invoices ----
  // The window is REPLACED, not merged: invoices are deleted rather than voided in this
  // file, and a deleted record simply stops appearing in the API. An incremental sync
  // would keep it forever.
  const invoices = await qboAll(realm, token, 'Invoice', `TxnDate >= '${from}'`);
  const invRows = [], invLines = [];
  let noDue = 0;
  invoices.forEach(inv => {
    const issued = day(inv.TxnDate);
    const terms  = (inv.SalesTermRef || {}).name || '';
    let due = day(inv.DueDate);
    if (!due) { due = deriveDueDate(issued, terms); if (!due) noDue++; }
    invRows.push({
      id: String(inv.Id),
      qbo_project_id: (inv.CustomerRef || {}).value ? String(inv.CustomerRef.value) : null,
      doc_number: inv.DocNumber || '',
      issued_on: issued,
      due_on: due,
      terms,
      total: cents(inv.TotalAmt),
      balance: cents(inv.Balance),
      synced_at: new Date().toISOString()
    });
    (inv.Line || []).forEach((l, n) => {
      if (l.DetailType !== 'SalesItemLineDetail') return;
      const d = l.SalesItemLineDetail || {};
      invLines.push({
        id: `${inv.Id}:${l.Id || n}`, invoice_id: String(inv.Id), line_no: +l.LineNum || n + 1,
        item_id: (d.ItemRef || {}).value || null, item_name: (d.ItemRef || {}).name || '',
        description: l.Description || '', qty: d.Qty !== undefined ? +d.Qty : null,
        unit_price: d.UnitPrice !== undefined ? cents(d.UnitPrice) : null,
        amount: cents(l.Amount)
      });
    });
  });
  await sbDelete(`invoices?issued_on=gte.${from}`);
  await sbUpsert('invoices', invRows);
  await sbUpsert('invoice_lines', invLines);
  const openInv = invRows.filter(r => r.balance > 0);
  console.log(`  ${invRows.length} invoices · ${invLines.length} lines · ` +
    `${openInv.length} open (${(openInv.reduce((s, r) => s + r.balance, 0) / 100).toLocaleString()})`);
  if (noDue) console.log(`  \u26a0 ${noDue} invoice(s) have no due date and no readable terms — ` +
    `cashflow will fall back to observed client behaviour for these.`);

  // ---- customer payments ----
  const payments = await qboAll(realm, token, 'Payment', `TxnDate >= '${from}'`);
  const payRows = payments.flatMap(splitPaymentLines);
  await sbDelete(`payments?paid_on=gte.${from}`);
  await sbUpsert('payments', payRows);
  const unlinked = payRows.filter(p => !p.invoice_id).length;
  console.log(`  ${payments.length} payments \u2192 ${payRows.length} invoice links` +
    (unlinked ? ` (${unlinked} unlinked — deposits or prepayments)` : ''));

  // ---- bills, card charges, journals ----
  const bills     = await qboAll(realm, token, 'Bill', `TxnDate >= '${from}'`);
  const purchases = await qboAll(realm, token, 'Purchase', `TxnDate >= '${from}'`);
  const journals  = await qboAll(realm, token, 'JournalEntry', `TxnDate >= '${from}'`);

  const billRows = [], billLines = [];
  const addCost = (kind, t, vendor, opts = {}) => {
    const id = `${kind}:${t.Id}`;
    billRows.push({
      id, kind, vendor_name: vendor || '',
      issued_on: day(t.TxnDate),
      due_on: opts.due || null,
      balance: opts.balance !== undefined ? opts.balance : 0,
      terms: opts.terms || '',
      total: cents(t.TotalAmt),
      synced_at: new Date().toISOString()
    });
    (t.Line || []).forEach((l, n) => {
      const d = l.AccountBasedExpenseLineDetail || l.ItemBasedExpenseLineDetail || {};
      if (!d.AccountRef && !d.ItemRef) return;
      billLines.push({
        id: `${id}:${l.Id || n}`, bill_id: id, line_no: +l.LineNum || n + 1,
        item_name: (d.ItemRef || {}).name || '', account_name: (d.AccountRef || {}).name || '',
        description: l.Description || '', amount: cents(l.Amount),
        qbo_project_id: lineProject(l)
      });
    });
  };

  // A Bill is owed and has terms. A Purchase is a card charge — already paid, so its
  // balance is zero and it is cash out on the transaction date.
  bills.forEach(b => addCost('bill', b, (b.VendorRef || {}).name, {
    due: day(b.DueDate) || deriveDueDate(day(b.TxnDate), (b.SalesTermRef || {}).name),
    balance: cents(b.Balance),
    terms: (b.SalesTermRef || {}).name || ''
  }));
  purchases.forEach(p => addCost('purchase', p, (p.EntityRef || {}).name || p.PaymentType || ''));

  // Journal lines are signed: a debit to an expense account is a cost, a credit reduces
  // it. Kept separate so they can be included or excluded deliberately — payroll already
  // arrives via purchases, and folding these in blind risks double-counting.
  journals.forEach(j => {
    const id = `journal:${j.Id}`;
    const signed = (j.Line || []).reduce((t, l) => {
      const d = l.JournalEntryLineDetail || {};
      return t + (d.PostingType === 'Credit' ? -(+l.Amount || 0) : (+l.Amount || 0));
    }, 0);
    billRows.push({
      id, kind: 'journal', vendor_name: j.DocNumber || '',
      issued_on: day(j.TxnDate), due_on: null, balance: 0, terms: '',
      total: cents(signed), synced_at: new Date().toISOString()
    });
    (j.Line || []).forEach((l, n) => {
      const d = l.JournalEntryLineDetail || {};
      if (!d.AccountRef) return;
      const ent = d.Entity || {};
      billLines.push({
        id: `${id}:${l.Id || n}`, bill_id: id, line_no: +l.LineNum || n + 1,
        item_name: '', account_name: (d.AccountRef || {}).name || '',
        description: l.Description || '',
        amount: cents(d.PostingType === 'Credit' ? -(+l.Amount || 0) : (+l.Amount || 0)),
        qbo_project_id: ent.Type === 'Customer' ? String((ent.EntityRef || {}).value || '') || null : null
      });
    });
  });
  await sbDelete(`bills?issued_on=gte.${from}`);
  await sbUpsert('bills', billRows);
  await sbUpsert('bill_lines', billLines);
  const openBills = billRows.filter(b => b.balance > 0);
  console.log(`  ${bills.length} bills · ${purchases.length} card charges · ${journals.length} journals · ` +
    `${billLines.length} lines · ${openBills.length} unpaid ` +
    `(${(openBills.reduce((s, b) => s + b.balance, 0) / 100).toLocaleString()})`);

  // ---- vendor payments ----
  const billPmts = await qboAll(realm, token, 'BillPayment', `TxnDate >= '${from}'`);
  const bpRows = billPmts.flatMap(splitBillPaymentLines);
  await sbDelete(`bill_payments?paid_on=gte.${from}`);
  await sbUpsert('bill_payments', bpRows);
  console.log(`  ${billPmts.length} bill payments \u2192 ${bpRows.length} bill links`);

  // ---- attribution coverage, so a broken match map is visible immediately ----
  const links = await sbGet('qbo_project_links?select=qbo_project_id');
  const known = new Set(links.map(l => String(l.qbo_project_id)));
  const unmatched = new Set(invRows.map(r => r.qbo_project_id).filter(p => p && !known.has(p)));
  if (unmatched.size) {
    console.log(`  \u26a0 ${unmatched.size} QuickBooks project(s) on invoices have no client link yet — ` +
      `their revenue is stored but unattributed until matched.`);
  }

  await sbPatchState({
    last_run_at: new Date().toISOString(),
    last_run_log: {
      from, accounts: accounts.length,
      invoices: invRows.length, invoice_lines: invLines.length, invoices_open: openInv.length,
      invoices_no_due: noDue,
      payments: payments.length, payment_links: payRows.length, payments_unlinked: unlinked,
      bills: bills.length, purchases: purchases.length, journals: journals.length,
      bill_lines: billLines.length, bills_open: openBills.length,
      bill_payments: billPmts.length, bill_payment_links: bpRows.length,
      unmatched_projects: unmatched.size
    }
  });
  console.log('\u2714 Done.');
}
