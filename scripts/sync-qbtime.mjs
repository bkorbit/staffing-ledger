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
const INTERNAL_NAMES = ['internal', 'internal time', 'non-billable', 'nonbillable', 'non billable', 'admin', 'overhead'];
const MONTHS_BACK = 2; // sync current month + 2 previous

if (!QBTIME_TOKEN) fail('Missing QBTIME_TOKEN secret.');
if (!SERVICE_KEY) fail('Missing SUPABASE_SERVICE_ROLE_KEY secret.');

function fail(msg) { console.error('✖ ' + msg); process.exit(1); }
function uid() { return Math.random().toString(36).slice(2, 10); }
function monthKeyOf(dateStr) { return dateStr.slice(0, 7); } // 'YYYY-MM-DD' -> 'YYYY-MM'
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
function rootJobcodeName(id, jobcodes) {
  let jc = jobcodes[id];
  let guard = 0;
  while (jc && jc.parent_id && jc.parent_id !== 0 && jobcodes[jc.parent_id] && guard < 10) {
    jc = jobcodes[jc.parent_id];
    guard++;
  }
  return jc ? String(jc.name || '').trim() : '';
}

async function pullTimesheets(startDate, endDate) {
  const entries = []; // {person, customer, month, hours}
  const users = {};
  const jobcodes = {};
  let page = 1;

  for (;;) {
    const data = await qbFetch('/timesheets', { start_date: startDate, end_date: endDate, page });
    const sup = data.supplemental_data || {};
    Object.assign(users, sup.users || {});
    Object.assign(jobcodes, sup.jobcodes || {});
    const sheets = Object.values((data.results || {}).timesheets || {});
    for (const ts of sheets) {
      const u = users[ts.user_id];
      const person = u ? `${u.first_name || ''} ${u.last_name || ''}`.trim() : '';
      const customer = rootJobcodeName(ts.jobcode_id, jobcodes);
      const hours = (ts.duration || 0) / 3600;
      if (!person || !customer || hours <= 0 || !ts.date) continue;
      entries.push({ person, customer, month: monthKeyOf(ts.date), hours });
    }
    if (!data.more) break;
    page++;
    if (page > 50) break; // safety valve
  }
  return entries;
}

// ---------- Supabase ----------

const sbHeaders = {
  apikey: SERVICE_KEY,
  Authorization: 'Bearer ' + SERVICE_KEY,
  'Content-Type': 'application/json',
};

async function loadLedger() {
  const res = await fetch(`${SUPABASE_URL}/rest/v1/ledger_state?id=eq.${WORKSPACE_ID}&select=data`, { headers: sbHeaders });
  if (!res.ok) fail(`Supabase read failed (${res.status}): ${await res.text()}`);
  const rows = await res.json();
  return rows.length ? rows[0].data || {} : null;
}

async function saveLedger(state, rowExists) {
  const body = JSON.stringify(rowExists
    ? { data: state, updated_at: new Date().toISOString() }
    : { id: WORKSPACE_ID, data: state, updated_at: new Date().toISOString() });
  const url = rowExists
    ? `${SUPABASE_URL}/rest/v1/ledger_state?id=eq.${WORKSPACE_ID}`
    : `${SUPABASE_URL}/rest/v1/ledger_state`;
  const res = await fetch(url, { method: rowExists ? 'PATCH' : 'POST', headers: sbHeaders, body });
  if (!res.ok) fail(`Supabase write failed (${res.status}): ${await res.text()}`);
}

// ---------- Sync ----------

async function main() {
  const now = new Date();
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - MONTHS_BACK, 1));
  const startDate = isoDate(start);
  const endDate = isoDate(now);
  console.log(`Pulling QuickBooks Time timesheets ${startDate} → ${endDate}…`);

  const entries = await pullTimesheets(startDate, endDate);
  console.log(`Fetched ${entries.length} timesheet entries.`);

  // Aggregate: month -> personName|customer -> hours
  const agg = {};
  for (const e of entries) {
    const key = e.person.toLowerCase() + '|' + e.customer.toLowerCase();
    if (!agg[e.month]) agg[e.month] = {};
    if (!agg[e.month][key]) agg[e.month][key] = { person: e.person, customer: e.customer, hours: 0 };
    agg[e.month][key].hours += e.hours;
  }

  const existing = await loadLedger();
  const rowExists = existing !== null;
  const state = Object.assign({ staff: [], projects: [], assignments: {}, actuals: {}, demand: {} }, existing || {});
  if (!state.actuals) state.actuals = {};

  const staffByName = {};
  state.staff.forEach(s => staffByName[(s.name || '').trim().toLowerCase()] = s);
  const projByName = {};
  state.projects.forEach(p => projByName[(p.name || '').trim().toLowerCase()] = p);

  const newStaff = [], newProjects = [];
  const monthsSynced = Object.keys(agg).sort();

  for (const mk of monthsSynced) {
    const monthActuals = {}; // full-month replace: QB Time is the source of truth for these months
    for (const { person, customer, hours } of Object.values(agg[mk])) {
      let staff = staffByName[person.toLowerCase()];
      if (!staff) {
        staff = { id: uid(), name: person, department: '', employmentType: 'fulltime', annualCost: 0, hourlyCost: 0, weeklyCapacity: 40 };
        state.staff.push(staff);
        staffByName[person.toLowerCase()] = staff;
        newStaff.push(person);
      }
      let projectId;
      if (INTERNAL_NAMES.includes(customer.toLowerCase())) {
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

  await saveLedger(state, rowExists);

  console.log('✔ Synced months:', monthsSynced.join(', ') || '(none)');
  if (newStaff.length) console.log('  New people created (set hourly cost in the Team tab):', [...new Set(newStaff)].join(', '));
  if (newProjects.length) console.log('  New projects created (set revenue in the Projects tab):', [...new Set(newProjects)].join(', '));
}

main().catch(e => fail(e.stack || String(e)));
