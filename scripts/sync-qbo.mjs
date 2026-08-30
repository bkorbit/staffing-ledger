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
const QBO       = process.env.QBO_BASE_URL || 'https://quickbooks.api.intuit.com/v3/company';
const TOKEN_URL = process.env.QBO_TOKEN_URL || 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';
const MINOR     = '75';
const STATE_ID  = 'quickbooks';

const fail  = m => { throw new Error(m); };
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
  // PostgREST rejects a bulk insert whose objects do not all carry the same keys
  // (PGRST102). Rows for one table are built in several places here — bills, card
  // charges and journal entries all land in `bills` — so a column added to one path
  // and not another breaks the whole write with an error that names no column.
  // Normalising to the union of keys makes that impossible rather than merely unlikely.
  const keys = [...new Set(rows.flatMap(Object.keys))];
  const shaped = rows.map(r => {
    const o = {};
    for (const k of keys) o[k] = r[k] === undefined ? null : r[k];
    return o;
  });
  for (let i = 0; i < shaped.length; i += 500) {
    const chunk = shaped.slice(i, i + 500);
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

// QuickBooks types its own accounts, and those types are the COGS/overhead split the
// old rule tables encoded by hand. Payroll is separated out of Expense because it has
// its own cadence in the cashflow model (semi-monthly) and must not be smoothed into a
// six-month category average.
export function classifyAccount(type, subType, name) {
  const t = String(type || '');
  const st = String(subType || '');
  const n = String(name || '').toLowerCase();
  if (t === 'Cost of Goods Sold') return 'cogs';
  // 'Income' is the real contra-revenue path (search/social media pass-through
  // booked against income-type accounts). 'Other Income' (credit card rewards,
  // bank interest) is unrelated to client billing and was wrongly netted into
  // revenue the same way — it's money in, so it reduces overhead instead;
  // v_cost_lines_classified flips its sign accordingly.
  if (t === 'Income') return 'income';
  if (t === 'Other Income') return 'overhead';
  if (t === 'Expense' || t === 'Other Expense') {
    if (/payroll|salaries|salary|wages|compensation|contract labor|bonus|severance|401k|health insurance|life insurance|commission/.test(n) ||
        /PayrollExpenses/i.test(st)) return 'payroll';
    return 'overhead';
  }
  // Balance-sheet accounts move money without being a cost — excluded so they cannot
  // inflate an expense run-rate.
  if (['Bank','Accounts Receivable','Accounts Payable','Credit Card','Equity',
       'Fixed Asset','Other Current Asset','Other Asset','Other Current Liability',
       'Long Term Liability'].includes(t)) return 'excluded';
  return 'other';
}

// The jobcode embedded in a QuickBooks project name, e.g. '26hawt260810'. It is the
// shared key with HubSpot deals, and the most reliable non-manual way to match a
// QuickBooks project to a deal. The short-code segment normally reads as pure
// letters, but some real client codes (e.g. 'o2kl') carry a digit — so it's matched
// lazily as a leading letter plus a short alnum run, which finds the shortest split
// that still leaves a valid digit suffix, agreeing with the letters-only form when
// there's no digit to disambiguate.
export function jobcodeFromName(name) {
  const m = String(name || '').match(/\b\d{2}[a-z][a-z0-9]{2,5}?\d{5,8}\b/i);
  return m ? m[0] : null;
}

// Project id on an expense line, wherever QuickBooks decided to put it.
export function lineProject(l) {
  const d = l.AccountBasedExpenseLineDetail || l.ItemBasedExpenseLineDetail || {};
  const e = d.CustomerRef || d.Entity || {};
  return e.value ? String(e.value) : null;
}

// Shared shape for Bill/Purchase/CreditCardCredit — all three carry a real
// AccountRef per line, unlike CreditMemo/RefundReceipt below. A Credit Card
// Credit is the exact reverse of a Purchase (money back instead of money
// out), so it reuses this with sign=-1 rather than a separate code path.
export function costRow(kind, t, vendor, opts = {}) {
  const sign = opts.sign || 1;
  const id = `${kind}:${t.Id}`;
  const row = {
    id, kind, vendor_name: vendor || '', qbo_customer_name: opts.customer || null,
    issued_on: day(t.TxnDate),
    due_on: opts.due || null,
    balance: opts.balance !== undefined ? opts.balance : 0,
    terms: opts.terms || '',
    total: sign * cents(t.TotalAmt),
    synced_at: new Date().toISOString()
  };
  const lines = [];
  (t.Line || []).forEach((l, n) => {
    const d = l.AccountBasedExpenseLineDetail || l.ItemBasedExpenseLineDetail || {};
    if (!d.AccountRef && !d.ItemRef) return;
    lines.push({
      id: `${id}:${l.Id || n}`, bill_id: id, line_no: +l.LineNum || n + 1,
      item_name: (d.ItemRef || {}).name || '',
      account_id: (d.AccountRef || {}).value ? String(d.AccountRef.value) : null,
      account_name: (d.AccountRef || {}).name || '',
      description: l.Description || '', amount: sign * cents(l.Amount),
      qbo_project_id: lineProject(l)
    });
  });
  return { row, lines };
}

// CreditMemo and RefundReceipt are structured like Invoices, not Bills —
// each line names a Product/Service ITEM (SalesItemLineDetail), never an
// account directly. QuickBooks resolves the posting account through that
// item's own IncomeAccountRef (the same field a normal Invoice line relies
// on to attribute revenue), so itemAccount — built once from the Item list
// — is the only way to know where a given line actually lands. A line whose
// item has no income account configured is left out rather than guessed at.
export function salesCostRow(kind, t, itemAccount) {
  const id = `${kind}:${t.Id}`;
  const row = {
    id, kind, vendor_name: (t.CustomerRef || {}).name || '', qbo_customer_name: null,
    issued_on: day(t.TxnDate), due_on: null, balance: 0, terms: '',
    total: cents(t.TotalAmt), synced_at: new Date().toISOString()
  };
  const lines = [];
  (t.Line || []).forEach((l, n) => {
    if (l.DetailType !== 'SalesItemLineDetail') return;
    const d = l.SalesItemLineDetail || {};
    const itemId = (d.ItemRef || {}).value ? String(d.ItemRef.value) : null;
    const acct = itemId ? itemAccount[itemId] : null;
    if (!acct) return;
    lines.push({
      id: `${id}:${l.Id || n}`, bill_id: id, line_no: +l.LineNum || n + 1,
      item_name: (d.ItemRef || {}).name || '',
      account_id: acct.id, account_name: acct.name,
      description: l.Description || '', amount: cents(l.Amount),
      qbo_project_id: (t.CustomerRef || {}).value ? String(t.CustomerRef.value) : null
    });
  });
  return { row, lines };
}

// A Deposit's line carries an AccountRef directly (DepositLineDetail), same
// as a Bill/Purchase line — but a Deposit can ALSO bundle a linked customer
// payment (an Entity reference on the line), which the payments sync already
// captures. Only a bare account credit — no Entity — is counted here, or
// every bank-fed customer payment swept into a deposit would double count
// revenue. This is how bank interest (recorded as a deposit crediting an
// Other Income account, with nothing on the other side) reaches this system
// at all — confirmed absent from every other synced entity type.
export function depositRow(t) {
  const id = `deposit:${t.Id}`;
  const row = {
    id, kind: 'deposit', vendor_name: '', qbo_customer_name: null,
    issued_on: day(t.TxnDate), due_on: null, balance: 0, terms: '',
    total: cents(t.TotalAmt), synced_at: new Date().toISOString()
  };
  const lines = [];
  (t.Line || []).forEach((l, n) => {
    if (l.DetailType !== 'DepositLineDetail') return;
    const d = l.DepositLineDetail || {};
    if (d.Entity || !d.AccountRef) return;
    lines.push({
      id: `${id}:${l.Id || n}`, bill_id: id, line_no: +l.LineNum || n + 1,
      item_name: '',
      account_id: String(d.AccountRef.value), account_name: d.AccountRef.name || '',
      description: l.Description || '', amount: cents(l.Amount),
      qbo_project_id: null
    });
  });
  return { row, lines };
}

/* ----------------------------------------------------------------- main -- */

if (process.env.NODE_ENV !== 'test') main().catch(e => die('unhandled', e));

async function main() {
  let rows;
  try { rows = await sbGet(`sync_state?id=eq.${STATE_ID}&select=*`); }
  catch (e) { console.error('\u2716 [db-read] ' + (e.message || e)); process.exit(1); }
  if (!rows.length) fail(`No sync_state row for '${STATE_ID}'. Run db/001_init.sql.`);
  const state = rows[0];
  if (!state.refresh_token) fail(
    "No refresh token. Authorise once in Intuit's OAuth playground, then:\n" +
    `  update sync_state set refresh_token='…', realm_id='…' where id='${STATE_ID}';`);
  if (!state.realm_id) fail(`No realm_id. update sync_state set realm_id='…' where id='${STATE_ID}';`);

  const from = day(state.import_from) || '2025-01-01';
  console.log(`QuickBooks Online sync — window from ${from}`);

  let token;
  try { token = await refreshAccess(state.refresh_token); }
  catch (e) { await die('token-refresh', e); }
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

  // ---- customers and projects: the names that make matching possible ----
  // QuickBooks calls a sub-customer a "Project". Both are Customer records; Job=true
  // marks the sub. Without this table an invoice is an id nobody can match to a client.
  const customers = await qboAll(realm, token, 'Customer');
  const custName = {};
  await sbUpsert('qbo_projects', customers.map(c => {
    const fq = c.FullyQualifiedName || c.DisplayName || '';
    custName[String(c.Id)] = fq;
    return {
      id: String(c.Id),
      name: c.DisplayName || fq,
      fully_qualified_name: fq,
      parent_id: (c.ParentRef || {}).value ? String(c.ParentRef.value) : null,
      parent_name: fq.includes(':') ? fq.split(':').slice(0, -1).join(':') : null,
      is_project: !!c.Job,
      jobcode: jobcodeFromName(fq),
      active: c.Active !== false,
      synced_at: new Date().toISOString()
    };
  }), 'id');
  const nProjects = customers.filter(c => c.Job).length;
  const nJob = customers.filter(c => jobcodeFromName(c.FullyQualifiedName || '')).length;
  console.log(`  ${customers.length} customers (${nProjects} projects, ${nJob} carrying a jobcode)`);

  // A project whose name never parsed to a jobcode (and has no manual override)
  // fails silently downstream — it can't auto-match a deal, and QuickBooks Time
  // hours logged against it can't attribute either, with no warning anywhere else
  // in either sync. Surfacing it here is what replaces "someone happens to notice
  // a client shows zero hours" with a name in tonight's run log.
  const unparsed = await sbGet(
    `qbo_projects?is_project=eq.true&active=eq.true&effective_jobcode=is.null&select=name`);
  if (unparsed.length) {
    console.log(`  ⚠ ${unparsed.length} active project(s) have no jobcode and won't auto-match a ` +
      `deal or attribute QuickBooks Time hours — set qbo_projects.jobcode_override for: ` +
      unparsed.slice(0, 10).map(p => p.name).join(', ') +
      (unparsed.length > 10 ? ` +${unparsed.length - 10} more` : ''));
  }

  // ---- chart of accounts ----
  // Every account, not just banks. QuickBooks types them itself, which is the same
  // COGS-versus-overhead judgement the old system kept in hand-built rule tables.
  // is_operating and the override columns are never written here: those are human
  // decisions and a re-run must not clobber them.
  const accounts = await qboAll(realm, token, 'Account');
  await sbUpsert('qbo_accounts', accounts.map(a => ({
    id: String(a.Id),
    name: a.Name || '',
    fully_qualified_name: a.FullyQualifiedName || a.Name || '',
    account_type: a.AccountType || '',
    account_sub_type: a.AccountSubType || '',
    parent_id: (a.ParentRef || {}).value ? String(a.ParentRef.value) : null,
    active: a.Active !== false,
    balance: cents(a.CurrentBalance),
    as_of: new Date().toISOString().slice(0, 10),
    derived_class: classifyAccount(a.AccountType, a.AccountSubType, a.Name),
    synced_at: new Date().toISOString()
  })), 'id');
  const banks = accounts.filter(a => a.AccountType === 'Bank');
  const byClass = {};
  accounts.forEach(a => {
    const c = classifyAccount(a.AccountType, a.AccountSubType, a.Name);
    byClass[c] = (byClass[c] || 0) + 1;
  });
  console.log(`  ${accounts.length} accounts (${banks.length} bank) — ` +
    Object.entries(byClass).map(([k, v]) => `${v} ${k}`).join(', '));
  console.log(`  bank total ${banks.reduce((s, a) => s + (+a.CurrentBalance || 0), 0).toLocaleString()}`);

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
      qbo_customer_name: custName[String((inv.CustomerRef || {}).value)] || (inv.CustomerRef || {}).name || '',
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
  // A payment inside the window can settle an invoice issued BEFORE it. Those invoices
  // are not in the fetch above, so the link would break the foreign key — and, worse,
  // silently lose the pairing that makes payment lag measurable. Pull the stragglers by
  // id rather than widening the whole window.
  const payments = await qboAll(realm, token, 'Payment', `TxnDate >= '${from}'`);
  let payRows = payments.flatMap(splitPaymentLines);

  const haveInv = new Set(invRows.map(r => r.id));
  const missing = [...new Set(payRows.map(p => p.invoice_id).filter(id => id && !haveInv.has(id)))];
  if (missing.length) {
    console.log(`  fetching ${missing.length} earlier invoice(s) referenced by payments in the window…`);
    const extraRows = [], extraLines = [];
    for (let i = 0; i < missing.length; i += 100) {
      const ids = missing.slice(i, i + 100).map(x => `'${x}'`).join(',');
      const q = await qboQuery(realm, token, `SELECT * FROM Invoice WHERE Id IN (${ids})`);
      (q.Invoice || []).forEach(inv => {
        const issued = day(inv.TxnDate);
        const terms  = (inv.SalesTermRef || {}).name || '';
        extraRows.push({
          id: String(inv.Id),
          qbo_project_id: (inv.CustomerRef || {}).value ? String(inv.CustomerRef.value) : null,
          qbo_customer_name: custName[String((inv.CustomerRef || {}).value)] || (inv.CustomerRef || {}).name || '',
          doc_number: inv.DocNumber || '', issued_on: issued,
          due_on: day(inv.DueDate) || deriveDueDate(issued, terms), terms,
          total: cents(inv.TotalAmt), balance: cents(inv.Balance),
          synced_at: new Date().toISOString()
        });
        (inv.Line || []).forEach((l, n) => {
          if (l.DetailType !== 'SalesItemLineDetail') return;
          const d = l.SalesItemLineDetail || {};
          extraLines.push({
            id: `${inv.Id}:${l.Id || n}`, invoice_id: String(inv.Id), line_no: +l.LineNum || n + 1,
            item_id: (d.ItemRef || {}).value || null, item_name: (d.ItemRef || {}).name || '',
            description: l.Description || '', qty: d.Qty !== undefined ? +d.Qty : null,
            unit_price: d.UnitPrice !== undefined ? cents(d.UnitPrice) : null,
            amount: cents(l.Amount)
          });
        });
      });
    }
    await sbUpsert('invoices', extraRows);
    await sbUpsert('invoice_lines', extraLines);
    extraRows.forEach(r => haveInv.add(r.id));
    console.log(`  recovered ${extraRows.length} of ${missing.length}`);
  }

  // Anything still unresolvable (deleted or voided in QuickBooks) is kept as an
  // unlinked payment rather than dropped, so total cash in still reconciles even
  // though that one cannot contribute to a lag figure.
  let orphaned = 0;
  payRows = payRows.map(p => {
    if (p.invoice_id && !haveInv.has(p.invoice_id)) { orphaned++; return { ...p, invoice_id: null }; }
    return p;
  });

  await sbDelete(`payments?paid_on=gte.${from}`);
  await sbUpsert('payments', payRows);
  const unlinked = payRows.filter(p => !p.invoice_id).length;
  console.log(`  ${payments.length} payments \u2192 ${payRows.length} rows` +
    (unlinked ? ` (${unlinked} unlinked` + (orphaned ? `, ${orphaned} of them pointing at invoices no longer in QuickBooks` : '') + ')' : ''));

  // ---- bills, card charges, journals, credit memos, refunds ----
  // 'CreditCardCredit' is NOT a queryable QuickBooks entity — confirmed the
  // hard way (QueryValidationError: invalid context declaration). A Credit
  // Card Credit is stored as a Purchase record with Credit: true, and the
  // existing Purchase query already returns every one (no Credit filter),
  // so there is nothing extra to fetch — just a flag on rows already here.
  const bills          = await qboAll(realm, token, 'Bill', `TxnDate >= '${from}'`);
  const purchases      = await qboAll(realm, token, 'Purchase', `TxnDate >= '${from}'`);
  const journals       = await qboAll(realm, token, 'JournalEntry', `TxnDate >= '${from}'`);
  const creditMemos    = await qboAll(realm, token, 'CreditMemo', `TxnDate >= '${from}'`);
  const refundReceipts = await qboAll(realm, token, 'RefundReceipt', `TxnDate >= '${from}'`);
  const deposits       = await qboAll(realm, token, 'Deposit', `TxnDate >= '${from}'`);

  const billRows = [], billLines = [];
  const addCost = (kind, t, vendor, opts = {}) => {
    const { row, lines } = costRow(kind, t, vendor, opts);
    billRows.push(row);
    billLines.push(...lines);
  };

  // A Bill is owed and has terms. A Purchase is a card charge — already paid, so its
  // balance is zero and it is cash out on the transaction date.
  bills.forEach(b => addCost('bill', b, (b.VendorRef || {}).name, {
    customer: custName[String(((b.Line || []).map(lineProject).find(Boolean)) || '')] || null,
    due: day(b.DueDate) || deriveDueDate(day(b.TxnDate), (b.SalesTermRef || {}).name),
    balance: cents(b.Balance),
    terms: (b.SalesTermRef || {}).name || ''
  }));
  // A Purchase with Credit: true is a Credit Card Credit — money back, not
  // out. Never checking this flag is what made a month's card charges show
  // up without their offsetting reversals (confirmed against a real
  // QuickBooks account register: July's $22,315.45 of uncredited Facebook
  // charges vs. the true -$4,774.55 net once these are signed correctly).
  let ccCreditCount = 0;
  purchases.forEach(p => {
    const vendor = (p.EntityRef || {}).name || p.PaymentType || '';
    if (p.Credit === true) { ccCreditCount++; addCost('credit_card_credit', p, vendor, { sign: -1 }); }
    else addCost('purchase', p, vendor);
  });

  // Credit Memos and Refund Receipts resolve their posting account through
  // the line item's IncomeAccountRef — see salesCostRow's own comment for
  // why. Confirmed against the same register: April's "Non Operating Loss"
  // was short exactly $102,634.48, three Credit Memos ("TN Waived Invoices
  // Write Off") this sync never fetched at all before now.
  const items = await qboAll(realm, token, 'Item', '');
  const itemAccount = {};
  items.forEach(it => {
    const ref = it.IncomeAccountRef || {};
    if (ref.value) itemAccount[String(it.Id)] = { id: String(ref.value), name: ref.name || '' };
  });
  const addSalesCost = (kind, t) => {
    const { row, lines } = salesCostRow(kind, t, itemAccount);
    billRows.push(row);
    billLines.push(...lines);
  };
  creditMemos.forEach(cm => addSalesCost('credit_memo', cm));
  refundReceipts.forEach(rr => addSalesCost('refund_receipt', rr));

  // Bank interest never appears via Bill/Purchase/JournalEntry/CreditMemo/
  // RefundReceipt — confirmed by its total absence from every one of those
  // (zero rows) despite a real, non-zero "Interest earned" balance every
  // single month. It's recorded as a Deposit, a fifth entity type this sync
  // had never fetched. depositRow's own comment explains the Entity guard
  // that keeps bundled customer payments from double-counting here.
  let depositLineCount = 0;
  deposits.forEach(dep => {
    const { row, lines } = depositRow(dep);
    billRows.push(row);
    billLines.push(...lines);
    depositLineCount += lines.length;
  });

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
        item_name: '',
        account_id: (d.AccountRef || {}).value ? String(d.AccountRef.value) : null,
        account_name: (d.AccountRef || {}).name || '',
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
  console.log(`  ${bills.length} bills · ${purchases.length - ccCreditCount} card charges · ${ccCreditCount} cc credits · ` +
    `${journals.length} journals · ${creditMemos.length} credit memos · ${refundReceipts.length} refund receipts · ` +
    `${deposits.length} deposits (${depositLineCount} counted lines) · ` +
    `${billLines.length} lines · ${openBills.length} unpaid ` +
    `(${(openBills.reduce((s, b) => s + b.balance, 0) / 100).toLocaleString()})`);

  // ---- vendor payments ----
  // Same hazard as customer payments: a payment in the window can settle a bill from
  // before it. Bills are cheap to re-fetch by id, but a Purchase is already paid and
  // never appears in a BillPayment, so only 'bill:' ids need recovering.
  const billPmts = await qboAll(realm, token, 'BillPayment', `TxnDate >= '${from}'`);
  let bpRows = billPmts.flatMap(splitBillPaymentLines);

  const haveBill = new Set(billRows.map(b => b.id));
  const missingBills = [...new Set(bpRows.map(b => b.bill_id)
    .filter(id => id && !haveBill.has(id)))].map(id => id.replace(/^bill:/, ''));
  if (missingBills.length) {
    console.log(`  fetching ${missingBills.length} earlier bill(s) referenced by payments…`);
    const extra = [];
    for (let i = 0; i < missingBills.length; i += 100) {
      const ids = missingBills.slice(i, i + 100).map(x => `'${x}'`).join(',');
      const q = await qboQuery(realm, token, `SELECT * FROM Bill WHERE Id IN (${ids})`);
      (q.Bill || []).forEach(b => extra.push({
        id: `bill:${b.Id}`, kind: 'bill', vendor_name: (b.VendorRef || {}).name || '',
        issued_on: day(b.TxnDate),
        due_on: day(b.DueDate) || deriveDueDate(day(b.TxnDate), (b.SalesTermRef || {}).name),
        balance: cents(b.Balance), terms: (b.SalesTermRef || {}).name || '',
        total: cents(b.TotalAmt), synced_at: new Date().toISOString()
      }));
    }
    await sbUpsert('bills', extra);
    extra.forEach(b => haveBill.add(b.id));
    console.log(`  recovered ${extra.length} of ${missingBills.length}`);
  }

  let bpOrphaned = 0;
  bpRows = bpRows.map(b => {
    if (b.bill_id && !haveBill.has(b.bill_id)) { bpOrphaned++; return { ...b, bill_id: null }; }
    return b;
  });

  await sbDelete(`bill_payments?paid_on=gte.${from}`);
  await sbUpsert('bill_payments', bpRows);
  console.log(`  ${billPmts.length} bill payments \u2192 ${bpRows.length} rows` +
    (bpOrphaned ? ` (${bpOrphaned} unlinked)` : ''));

  // ---- attribution coverage, so a broken match map is visible immediately ----
  const links = await sbGet('qbo_project_links?select=qbo_project_id');
  const known = new Set(links.map(l => String(l.qbo_project_id)));
  const unmatched = new Set(invRows.map(r => r.qbo_project_id).filter(p => p && !known.has(p)));
  if (unmatched.size) {
    console.log(`  \u26a0 ${unmatched.size} QuickBooks project(s) on invoices have no client link yet — ` +
      `their revenue is stored but unattributed until matched.`);
  }

  // New payments change the collection curves, so recompute them as part of the run
  // rather than trusting someone to remember. Failure here is reported but does not
  // fail the sync: stale curves are worse than fresh ones but far better than no data.
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/refresh_payment_behaviour`, {
      method: 'POST', headers: sb, body: '{}'
    });
    if (!r.ok) throw new Error(`${r.status}: ${(await r.text()).slice(0, 200)}`);
    console.log('  payment behaviour curves refreshed');
  } catch (e) {
    console.log('  \u26a0 curve refresh failed (sync data is fine): ' + (e.message || e));
  }

  // Records today's real bank position and cashflow_forecast()'s current
  // prediction for every future period, so the forecast can eventually be
  // checked against what actually happened (067). Same non-fatal pattern.
  try {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/rpc/snapshot_forecast`, {
      method: 'POST', headers: sb, body: '{}'
    });
    if (!r.ok) throw new Error(`${r.status}: ${(await r.text()).slice(0, 200)}`);
    console.log('  forecast snapshot recorded');
  } catch (e) {
    console.log('  \u26a0 forecast snapshot failed (sync data is fine): ' + (e.message || e));
  }

  await sbPatchState({
    last_run_at: new Date().toISOString(),
    last_run_log: {
      from, accounts: accounts.length,
      accounts_total: accounts.length, banks: banks.length,
      customers: customers.length, projects: nProjects,
      invoices: invRows.length, invoice_lines: invLines.length, invoices_open: openInv.length,
      invoices_no_due: noDue,
      payments: payments.length, payment_links: payRows.length, payments_unlinked: unlinked,
      bills: bills.length, purchases: purchases.length - ccCreditCount, journals: journals.length,
      credit_card_credits: ccCreditCount, credit_memos: creditMemos.length, refund_receipts: refundReceipts.length,
      deposits: deposits.length, deposit_lines: depositLineCount,
      bill_lines: billLines.length, bills_open: openBills.length,
      bill_payments: billPmts.length, bill_payment_links: bpRows.length, payments_orphaned: orphaned, bill_payments_orphaned: bpOrphaned,
      unmatched_projects: unmatched.size
    }
  });
  console.log('\u2714 Done.');
}
