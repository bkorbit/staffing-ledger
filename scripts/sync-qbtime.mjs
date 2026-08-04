// Sync QuickBooks Time (TSheets) hours into the EMG Staffing Assignments ledger.
//
// Runs nightly via GitHub Actions (.github/workflows/sync-qbtime.yml).
// Pulls timesheets for the current month plus the two previous months,
// aggregates them by person + customer + month, and REPLACES those months'
// actuals in the Supabase ledger_state row — mirroring what the manual
// "Import hour tracking data" flow does, including internal-hours mapping
// and auto-creating unknown people/projects.
//
// Required environment (GitHub repo secrets):
//   QBTIME_TOKEN               – QuickBooks Time API access token
//   SUPABASE_SERVICE_ROLE_KEY  – Supabase service-role key (bypasses RLS; server-side only)

const QBTIME_TOKEN = process.env.QBTIME_TOKEN;
const SERVICE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = 'https://bdtzpeazcjgnsxodwzpz.supabase.co';
const WORKSPACE_ID = 'default';

const QB_BASE = 'https://rest.tsheets.com/api/v1';
const INTERNAL_ID = '__internal__';
const TIMEOFF_ID = '__timeoff__';
// EMG-internal work: consumes time but is real work
const INTERNAL_NAMES = ['emg', 'internal', 'internal time', 'non-billable', 'nonbillable', 'non billable', 'admin', 'overhead'];
// Not-working time: PTO/sick/holiday — reduces capacity in the tool
const TIMEOFF_NAMES = ['pto', 'sick', 'sick day', 'vacation', 'holiday', 'company holiday', 'unpaid time off', 'time off'];
const TIMEOFF_JOBCODE_TYPES = new Set(['pto', 'paid_break', 'unpaid_break', 'unpaid_time_off']);
// People to never import from QuickBooks Time (case-insensitive, full name match)
const EXCLUDED_PEOPLE = new Set(['hannah hoffman']);
// QuickBooks Time owns all actuals from this date forward: every sync pulls the
// full window and replaces those months, so QBT corrections/deletions flow through.
const SYNC_FROM = '2026-04-01';

if (!QBTIME_TOKEN) fail('Missing QBTIME_TOKEN secret.');
if (!SERVICE_KEY) fail('Missing SUPABASE_SERVICE_ROLE_KEY secret.');

function fail(msg) { console.error('✖ ' + msg); process.exit(1); }
function uid() { return Math.random().toString(36).slice(2, 10); }
function monthKeyOf(dateStr) { return dateStr.slice(0, 7); } // 'YYYY-MM-DD' -> 'YYYY-MM'
function weekKeyOf(dateStr) { // 'YYYY-MM-DD' -> that week's Monday 'YYYY-MM-DD'
  const [y, m, d] = dateStr.split('-').map(Number);
  const dt = new Date(Date.UTC(y, m - 1, d));
  dt.setUTCDate(dt.getUTCDate() - ((dt.getUTCDay() + 6) % 7));
  return dt.toISOString().slice(0, 10);
}
function isoDate(d) { return d.toISOString().slice(0, 10); }

// ---------- QuickBooks Time ----------

async function qbFetch(path, params) {
  const url = new URL(QB_BASE + path);
  Object.entries(params || {}).forEach(([k, v]) => url.searchParams.set(k, v));
  const res = await fetch(url, { headers: { Authorization: 'Bearer ' + QBTIME_TOKEN } });
  if (!res.ok) fail(`QuickBooks Time API ${path} returned ${res.status}: ${await res.text()}`);
  return res.json();
}

// Resolve a jobcode to its top-level parent (the customer), walking parent_id links.
// PTO/break-type jobcodes resolve to 'Internal' so time off never becomes a fake customer.
function rootJobcodeName(id, jobcodes) {
  let jc = jobcodes[id];
  let guard = 0;
  while (jc && jc.parent_id && jc.parent_id !== 0 && jobcodes[jc.parent_id] && guard < 10) {
    jc = jobcodes[jc.parent_id];
    guard++;
  }
  if (!jc) return '';
  if (TIMEOFF_JOBCODE_TYPES.has(String(jc.type || '').toLowerCase())) return 'Time off';
  return String(jc.name || '').trim();
}

// Pull every jobcode up front. Relying on each page's supplemental_data means a child
// jobcode whose parent happens not to appear on that page resolves to the sub-jobcode
// name instead of the customer, splitting one account across several names.
async function fetchJobcodes() {
  const map = {};
  let page = 1;
  try {
    for (;;) {
      const data = await qbFetch('/jobcodes', { page, per_page: 200, active: 'both' });
      const list = Object.values((data.results || {}).jobcodes || {});
      for (const jc of list) map[jc.id] = jc;
      if (!data.more) break;
      page++;
      if (page > 200) { console.log('  ⚠ jobcode pagination hit the 200-page guard.'); break; }
    }
    console.log(`  Loaded ${Object.keys(map).length} jobcodes.`);
  } catch (e) {
    console.log('  (jobcode prefetch failed, falling back to per-page data:', e.message + ')');
  }
  return map;
}

async function fetchGroups() {
  const map = {}; // group_id -> group name
  let page = 1;
  try {
    for (;;) {
      const data = await qbFetch('/groups', { page, per_page: 200 });
      const groups = Object.values((data.results || {}).groups || {});
      for (const g of groups) map[g.id] = String(g.name || '').trim();
      if (!data.more) break;
      page++;
      if (page > 20) break;
    }
  } catch (e) {
    console.log('  (groups fetch failed — new people will be created without a department:', e.message + ')');
  }
  return map;
}

async function pullTimesheets(startDate, endDate) {
  const entries = []; // {person, customer, month, week, hours, dept}
  const users = {};
  const jobcodes = Object.assign({}, JOBCODES);
  let page = 1;
  // Every hour QuickBooks Time returned, and every hour we dropped and why. Without this
  // the sync can silently under-report and look like it worked.
  const stat = { sheets: 0, rawHours: 0, kept: 0, keptHours: 0,
                 noPerson: 0, noPersonHours: 0, noCustomer: 0, noCustomerHours: 0,
                 zero: 0, excluded: 0, excludedHours: 0, noDate: 0,
                 unknownJobcodes: new Set(), unknownUsers: new Set(), truncated: false };

  for (;;) {
    // per_page must be explicit: the API defaults to 50 rows, so without it the old
    // 50-page guard capped the entire window at ~2,500 timesheets.
    const data = await qbFetch('/timesheets', { start_date: startDate, end_date: endDate, page, per_page: 200 });
    const sup = data.supplemental_data || {};
    Object.assign(users, sup.users || {});
    Object.assign(jobcodes, sup.jobcodes || {});
    const sheets = Object.values((data.results || {}).timesheets || {});
    for (const ts of sheets) {
      const hours = (ts.duration || 0) / 3600;
      stat.sheets++; stat.rawHours += hours;
      const u = users[ts.user_id];
      const person = u ? `${u.first_name || ''} ${u.last_name || ''}`.trim() : '';
      const dept = u && u.group_id ? (GROUP_NAMES[u.group_id] || '') : '';
      const customer = rootJobcodeName(ts.jobcode_id, jobcodes);
      if (!ts.date) { stat.noDate++; continue; }
      if (!person) { stat.noPerson++; stat.noPersonHours += hours; stat.unknownUsers.add(String(ts.user_id)); continue; }
      if (EXCLUDED_PEOPLE.has(person.toLowerCase())) { stat.excluded++; stat.excludedHours += hours; continue; }
      if (!customer) { stat.noCustomer++; stat.noCustomerHours += hours; stat.unknownJobcodes.add(String(ts.jobcode_id)); continue; }
      if (hours <= 0) { stat.zero++; continue; }
      stat.kept++; stat.keptHours += hours;
      entries.push({ person, customer, month: monthKeyOf(ts.date), week: weekKeyOf(ts.date), hours, dept });
    }
    if (!data.more) break;
    page++;
    if (page > 400) { stat.truncated = true; break; }
  }

  console.log(`  Pages read: ${page}. Timesheets seen: ${stat.sheets} (${stat.rawHours.toFixed(2)}h raw).`);
  console.log(`  Imported: ${stat.kept} entries (${stat.keptHours.toFixed(2)}h).`);
  const dropped = stat.rawHours - stat.keptHours;
  if (dropped > 0.01) {
    console.log(`  ⚠ Dropped ${dropped.toFixed(2)}h:`);
    if (stat.excludedHours > 0) console.log(`      ${stat.excludedHours.toFixed(2)}h — excluded people (${[...EXCLUDED_PEOPLE].join(', ')})`);
    if (stat.noCustomerHours > 0) console.log(`      ${stat.noCustomerHours.toFixed(2)}h — jobcode did not resolve to a customer (ids: ${[...stat.unknownJobcodes].slice(0, 15).join(', ')})`);
    if (stat.noPersonHours > 0) console.log(`      ${stat.noPersonHours.toFixed(2)}h — unknown user (ids: ${[...stat.unknownUsers].slice(0, 15).join(', ')})`);
    if (stat.zero) console.log(`      ${stat.zero} entries with zero duration (still running, or deleted)`);
    if (stat.noDate) console.log(`      ${stat.noDate} entries with no date`);
  }
  if (stat.truncated) console.log('  ✖ PAGINATION GUARD HIT — results were truncated. Raise the page limit.');
  return entries;
}

// ---------- Supabase ----------

const sbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: 'Bearer ' + SERVICE_KEY,
  'Content-Type': 'application/json',
};

let loadedVersion = null;
async function loadLedger() {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/ledger_state?id=eq.${WORKSPACE_ID}&select=data,version`, { headers: sbHeaders });
  if (!res.ok) fail(`Supabase read failed (${res.status}): ${await res.text()}`);
  const rows = await res.json();
  if (rows.length) { loadedVersion = typeof rows[0].version === 'number' ? rows[0].version : 0; return rows[0].data || {}; }
  loadedVersion = null;
  return null;
}

async function saveLedger(state, rowExists) {
  if (!rowExists) {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/ledger_state`, {
      method: 'POST', headers: sbHeaders,
      body: JSON.stringify({ id: WORKSPACE_ID, data: state, version: 1, updated_at: new Date().toISOString() })
    });
    if (!res.ok) fail(`Supabase insert failed (${res.status}): ${await res.text()}`);
    return;
  }
  // Conditional PATCH on the loaded version; if a human saved during the sync, reload+reapply.
  const next = (loadedVersion || 0) + 1;
  const url = `${SUPABASE_URL}/rest/v1/ledger_state?id=eq.${WORKSPACE_ID}&version=eq.${loadedVersion}`;
  const res = await fetch(url, {
    method: 'PATCH', headers: { ...sbHeaders, Prefer: 'return=representation' },
    body: JSON.stringify({ data: state, version: next, updated_at: new Date().toISOString() })
  });
  if (!res.ok) fail(`Supabase write failed (${res.status}): ${await res.text()}`);
  const rows = await res.json();
  if (!rows.length) {
    // Version moved under us — a human saved mid-sync. This sync's data was built
    // from month-replace logic, so just skip this run's write rather than risk a
    // stale overwrite; tomorrow's run (or a manual dispatch) will reconcile.
    console.log('⚠ Ledger changed during sync (concurrent edit) — skipping write to avoid overwriting newer data. Re-run the sync.');
    process.exitCode = 0;
  }
}

// ---------- Sync ----------

let GROUP_NAMES = {};
let JOBCODES = {};

async function main() {
  GROUP_NAMES = await fetchGroups();
  JOBCODES = await fetchJobcodes();
  const now = new Date();
  const startDate = SYNC_FROM;
  const endDate = isoDate(now);
  console.log(`Pulling QuickBooks Time timesheets ${startDate} → ${endDate}…`);

  const entries = await pullTimesheets(startDate, endDate);
  const byMonth = {};
  for (const e of entries) byMonth[e.month] = (byMonth[e.month] || 0) + e.hours;
  console.log('Hours per month (compare these against the QuickBooks Time report):');
  Object.keys(byMonth).sort().forEach(mk => console.log(`    ${mk}: ${byMonth[mk].toFixed(2)}h`));

  // Aggregate: month -> personName|customer -> hours (and the same by week)
  const agg = {};
  const aggW = {};
  for (const e of entries) {
    const key = e.person.toLowerCase() + '|' + e.customer.toLowerCase();
    if (!agg[e.month]) agg[e.month] = {};
    if (!agg[e.month][key]) agg[e.month][key] = { person: e.person, customer: e.customer, dept: e.dept || '', hours: 0 };
    agg[e.month][key].hours += e.hours;
    if (e.dept && !agg[e.month][key].dept) agg[e.month][key].dept = e.dept;
    if (!aggW[e.week]) aggW[e.week] = {};
    if (!aggW[e.week][key]) aggW[e.week][key] = { person: e.person, customer: e.customer, hours: 0 };
    aggW[e.week][key].hours += e.hours;
  }

  const existing = await loadLedger();
  const rowExists = existing !== null;
  const state = Object.assign({ staff: [], projects: [], assignments: {}, actuals: {}, demand: {} }, existing || {});
  if (!state.actuals) state.actuals = {};
  if (!state.actualsW) state.actualsW = {};

  const staffByName = {};
  state.staff.forEach(s => staffByName[(s.name || '').trim().toLowerCase()] = s);
  const projByName = {};
  state.projects.forEach(p => projByName[(p.name || '').trim().toLowerCase()] = p);

  const newStaff = [], newProjects = [];
  const monthsSynced = Object.keys(agg).sort();

  for (const mk of monthsSynced) {
    const monthActuals = {}; // full-month replace: QB Time is the source of truth for these months
    for (const { person, customer, dept, hours } of Object.values(agg[mk])) {
      let staff = staffByName[person.toLowerCase()];
      if (!staff) {
        staff = { id: uid(), name: person, department: dept || '', employmentType: 'fulltime', annualCost: 0, hourlyCost: 0, weeklyCapacity: 40 };
        state.staff.push(staff);
        staffByName[person.toLowerCase()] = staff;
        newStaff.push(person + (dept ? ' (' + dept + ')' : ''));
      } else if (!staff.department && dept) {
        staff.department = dept;   // backfill blanks only — never overwrite a department you set
      }
      let projectId;
      if (TIMEOFF_NAMES.includes(customer.toLowerCase())) {
        projectId = TIMEOFF_ID;
      } else if (INTERNAL_NAMES.includes(customer.toLowerCase())) {
        projectId = INTERNAL_ID;
      } else {
        let proj = projByName[customer.toLowerCase()];
        if (!proj) {
          proj = { id: uid(), name: customer, monthlyRevenue: 0, revenueOverrides: {}, startMonth: '', endMonth: '' };
          state.projects.push(proj);
          projByName[customer.toLowerCase()] = proj;
          newProjects.push(customer);
        }
        projectId = proj.id;
      }
      const k = staff.id + '__' + projectId;
      monthActuals[k] = Math.round(((monthActuals[k] || 0) + hours) * 100) / 100;
    }
    state.actuals[mk] = monthActuals;
  }

  // Weekly actuals: synced months own their weeks — clear then rewrite
  const resolveKey = (person, customer) => {
    const staff = staffByName[person.toLowerCase()];
    const c = customer.toLowerCase();
    const pid = TIMEOFF_NAMES.includes(c) ? TIMEOFF_ID
      : INTERNAL_NAMES.includes(c) ? INTERNAL_ID
      : (projByName[c] || {}).id;
    return staff && pid ? staff.id + '__' + pid : null;
  };
  const monthsSet = new Set(monthsSynced);
  const weekOverlapsSynced = wk => {
    const [y, m, d] = wk.split('-').map(Number);
    const sunday = new Date(Date.UTC(y, m - 1, d + 6));
    return monthsSet.has(wk.slice(0, 7)) || monthsSet.has(sunday.toISOString().slice(0, 7));
  };
  Object.keys(state.actualsW).forEach(wk => { if (weekOverlapsSynced(wk)) delete state.actualsW[wk]; });
  for (const wk of Object.keys(aggW)) {
    const weekActuals = {};
    for (const { person, customer, hours } of Object.values(aggW[wk])) {
      const k = resolveKey(person, customer);
      if (!k) continue;
      weekActuals[k] = Math.round(((weekActuals[k] || 0) + hours) * 100) / 100;
    }
    if (Object.keys(weekActuals).length) state.actualsW[wk] = weekActuals;
  }

  await saveLedger(state, rowExists);

  console.log('✔ Synced months:', monthsSynced.join(', ') || '(none)');
  if (newStaff.length) console.log('  New people created (set hourly cost in the Team tab):', [...new Set(newStaff)].join(', '));
  if (newProjects.length) console.log('  New projects created (set revenue in the Projects tab):', [...new Set(newProjects)].join(', '));
}

main().catch(e => fail(e.stack || String(e)));
