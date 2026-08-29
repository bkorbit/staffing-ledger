// QuickBooks Time (TSheets) -> Postgres.
//
// Writes the effort domain the schema has carried since 001_init.sql and nobody
// ever wired up: staff, time_entries (actual hours, DAY grain), and time_off.
// Never touches assignments (human-planned hours) or comp_periods (human-entered
// pay) — this sync only writes what QuickBooks Time itself observed.
//
// The previous version of this file pointed at the deprecated Supabase project
// (bdtzpeazcjgnsxodwzpz — see CLAUDE.md) and wrote into a single JSON-blob table,
// `ledger_state`, that only ever existed there. That table and that project are
// both gone from this platform; every current sync reads SUPABASE_URL from the
// environment instead (see sync-qbo.mjs), and this one now matches.
//
// Attribution: QuickBooks Time's jobcodes are two levels — a parent (the
// overarching customer) and a child (the sub-customer / project). The child
// jobcode's own name is expected to carry the same embedded code QuickBooks
// Online project names do ('26hawt260810' — see jobcodeFromName below). Matching
// tries the child level first, then falls back to the parent level, then falls
// back to the internal/time-off name lists for anything that still isn't a real
// client jobcode.
//
// That code is looked up against qbo_projects.jobcode, NOT deals.jobcode — QBO
// data is project-based (a customer's actual sub-customer/"project" is what
// carries invoices, bills, and the jobcode), and deals.jobcode is only a partial,
// human-data-entry-dependent mirror of it (backfilled at promotion time from
// HubSpot's job_code field, or left null). The real deal <-> project claim is
// deals.qbo_project_id, set by match_deals_to_projects() (db/010) — which also
// matches some deals via an exact QB-link id with no jobcode involved at all.
// Going straight to deals.jobcode would silently under-match every deal claimed
// via that QB-link rung, or any deal whose jobcode was never backfilled, even
// though its QBO project is already correctly claimed.
//
// Env: QBTIME_TOKEN, SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY
// State: sync_state where id='qbtime' — import_from, last_run_at, last_run_log.
//   No refresh token: QuickBooks Time's token is long-lived, generated once in
//   its own admin settings, unlike QBO's rotating OAuth refresh token.

const QBTIME_TOKEN = process.env.QBTIME_TOKEN;
const SERVICE_KEY  = process.env.SUPABASE_SERVICE_ROLE_KEY;
const SUPABASE_URL = process.env.SUPABASE_URL;
const QB_BASE   = process.env.QBTIME_BASE_URL || 'https://rest.tsheets.com/api/v1';
const STATE_ID  = 'qbtime';

const INTERNAL_NAMES = ['emg', 'internal', 'internal time', 'non-billable', 'nonbillable', 'non billable', 'admin', 'overhead'];
const TIMEOFF_NAMES = ['pto', 'sick', 'sick day', 'vacation', 'holiday', 'company holiday', 'unpaid time off', 'time off'];
const TIMEOFF_JOBCODE_TYPES = new Set(['pto', 'paid_break', 'unpaid_break', 'unpaid_time_off']);
// Full name match, case-insensitive — people whose QuickBooks Time hours should
// never be imported at all.
const EXCLUDED_PEOPLE = new Set(['hannah hoffman']);

function preflight() {
  const missing = [];
  if (!QBTIME_TOKEN) missing.push('QBTIME_TOKEN — repo secret, a QuickBooks Time API token');
  if (!SERVICE_KEY)  missing.push('SUPABASE_SERVICE_ROLE_KEY — repo secret (the sb_secret_… key)');
  if (!SUPABASE_URL) missing.push('SUPABASE_URL — repo variable, e.g. https://xxxx.supabase.co');
  if (!missing.length) return;
  console.error('\n✖ Cannot run. ' + missing.length + ' missing:');
  missing.forEach((m, i) => console.error(`   ${i + 1}. ${m}`));
  process.exit(1);
}
preflight();

const fail = m => { throw new Error(m); };

async function die(stage, err) {
  const msg = err && err.message ? err.message : String(err);
  console.error(`✖ [${stage}] ${msg}`);
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

function day(v) { return (v === undefined || v === null || v === '') ? null : String(v).slice(0, 10); }
function isoDate(d) { return d.toISOString().slice(0, 10); }

// Same regex as sync-qbo.mjs/sync-hubspot.mjs — the shared jobcode convention.
// Kept as a local copy rather than a shared import: the two QuickBooks syncs
// already each carry their own copy, and a shared module is a bigger refactor
// than this rewrite calls for.
export function jobcodeFromName(name) {
  const m = String(name || '').match(/\b\d{2}[a-z]{3,6}\d{5,8}\b/i);
  return m ? m[0] : null;
}

// One timesheet entry (already resolved to childName/parentName/childType) ->
// where its hours belong. Pure and exported so adversarial fixtures can pin
// down the priority order without a live QuickBooks Time connection: type
// beats name, child beats parent, a real jobcode beats the internal bucket.
// `dealByJobcode` maps a lowercased jobcode to the deal that CLAIMS the QBO
// project carrying it (see the join built in main()) — matching is
// case-insensitive to agree with match_deals_to_projects()'s own
// `lower(q.jobcode) = lower(d.jobcode)` equality.
export function classifyEntry(e, dealByJobcode) {
  const lowerChild = (e.childName || '').toLowerCase(), lowerParent = (e.parentName || '').toLowerCase();
  const childIsTimeoffType = !!(e.childType && TIMEOFF_JOBCODE_TYPES.has(e.childType));
  if (childIsTimeoffType || TIMEOFF_NAMES.includes(lowerChild) || TIMEOFF_NAMES.includes(lowerParent)) {
    // Prefer QuickBooks Time's own type ('pto', 'paid_break', …) when that's
    // what actually matched — the name at that point is just the generic
    // 'Time off' placeholder jobcodeChain substitutes in, not a real kind.
    const kind = childIsTimeoffType ? e.childType
      : TIMEOFF_NAMES.includes(lowerChild) ? e.childName : e.parentName;
    return { type: 'timeoff', kind };
  }
  if (!INTERNAL_NAMES.includes(lowerChild) && !INTERNAL_NAMES.includes(lowerParent)) {
    const code = jobcodeFromName(e.childName) || jobcodeFromName(e.parentName);
    if (code) {
      const deal = dealByJobcode.get(code.toLowerCase());
      if (deal) return { type: 'billable', dealId: deal.id, clientId: deal.client_id };
      return { type: 'unmatched', code };
    }
  }
  return { type: 'internal' };
}

// A sorted set of 'YYYY-MM-DD' strings -> contiguous [start, end] ranges, so a
// week of PTO becomes one time_off row instead of seven. Pure and exported for
// the same reason as classifyEntry — the off-by-one risk here (a single day,
// a run that starts the array, two ranges separated by exactly one gap day)
// is exactly what adversarial fixtures catch and a one-row fixture would miss.
export function mergeIntoRanges(days) {
  const sorted = [...new Set(days)].sort();
  if (!sorted.length) return [];
  const ranges = [];
  let start = sorted[0], prev = sorted[0];
  for (let i = 1; i <= sorted.length; i++) {
    const d = sorted[i];
    const gap = d ? (new Date(d) - new Date(prev)) / 86400000 : Infinity;
    if (gap > 1) { ranges.push([start, prev]); start = d; }
    prev = d;
  }
  return ranges;
}

/* -------------------------------------------------------------- Supabase -- */

const sb = { apikey: SERVICE_KEY, Authorization: 'Bearer ' + SERVICE_KEY, 'Content-Type': 'application/json' };

async function sbGet(path) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: sb });
  if (!r.ok) fail(`Supabase GET ${path} → ${r.status}: ${await r.text()}`);
  return r.json();
}
async function sbDelete(path) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { method: 'DELETE', headers: sb });
  if (!r.ok) fail(`Supabase DELETE ${path} → ${r.status}: ${await r.text()}`);
}
async function sbInsert(table, rows) {
  if (!rows.length) return;
  for (let i = 0; i < rows.length; i += 500) {
    const chunk = rows.slice(i, i + 500);
    const r = await fetch(`${SUPABASE_URL}/rest/v1/${table}`, {
      method: 'POST', headers: { ...sb, Prefer: 'return=minimal' }, body: JSON.stringify(chunk)
    });
    if (!r.ok) fail(`Supabase insert ${table} → ${r.status}: ${(await r.text()).slice(0, 500)}`);
  }
}
async function sbPatchState(patch) {
  const r = await fetch(`${SUPABASE_URL}/rest/v1/sync_state?id=eq.${STATE_ID}`, {
    method: 'PATCH', headers: { ...sb, Prefer: 'return=minimal' },
    body: JSON.stringify({ ...patch, updated_at: new Date().toISOString() })
  });
  if (!r.ok) fail(`Supabase state write → ${r.status}: ${await r.text()}`);
}

/* ---------------------------------------------------------- QuickBooks Time -- */

async function qbFetch(path, params) {
  const url = new URL(QB_BASE + path);
  Object.entries(params || {}).forEach(([k, v]) => url.searchParams.set(k, v));
  const res = await fetch(url, { headers: { Authorization: 'Bearer ' + QBTIME_TOKEN } });
  if (!res.ok) fail(`QuickBooks Time API ${path} returned ${res.status}: ${await res.text()}`);
  return res.json();
}

async function fetchJobcodes() {
  const map = {};
  let page = 1;
  for (;;) {
    const data = await qbFetch('/jobcodes', { page, per_page: 200, active: 'both' });
    const list = Object.values((data.results || {}).jobcodes || {});
    for (const jc of list) map[jc.id] = jc;
    if (!data.more) break;
    page++;
    if (page > 200) { console.log('  ⚠ jobcode pagination hit the 200-page guard.'); break; }
  }
  console.log(`  Loaded ${Object.keys(map).length} jobcodes.`);
  return map;
}

async function fetchGroups() {
  const map = {};
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

// The child (this jobcode) and parent (one level up) names, each resolved past
// PTO/break jobcode types to a plain label. Two levels only: QuickBooks Time's own
// hierarchy is customer -> project, and Boris confirmed that's the whole chain —
// there is no third level to walk.
export function jobcodeChain(id, jobcodes) {
  const jc = jobcodes[id];
  if (!jc) return { child: '', parent: '', childType: '' };
  const nameOf = j => TIMEOFF_JOBCODE_TYPES.has(String(j.type || '').toLowerCase())
    ? 'Time off' : String(j.name || '').trim();
  const parentJc = jc.parent_id && jc.parent_id !== 0 ? jobcodes[jc.parent_id] : null;
  return { child: nameOf(jc), parent: parentJc ? nameOf(parentJc) : '', childType: String(jc.type || '').toLowerCase() };
}

async function pullTimesheets(startDate, endDate) {
  const entries = []; // {qbtimeUserId, person, dept, date, hours, jobcode, childName, parentName, childType}
  const users = {};
  const jobcodes = Object.assign({}, JOBCODES);
  let page = 1;
  const stat = { sheets: 0, rawHours: 0, kept: 0, keptHours: 0,
                 noPerson: 0, noPersonHours: 0, excluded: 0, excludedHours: 0,
                 zero: 0, noDate: 0, truncated: false };

  for (;;) {
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
      if (!ts.date) { stat.noDate++; continue; }
      if (!person) { stat.noPerson++; stat.noPersonHours += hours; continue; }
      if (EXCLUDED_PEOPLE.has(person.toLowerCase())) { stat.excluded++; stat.excludedHours += hours; continue; }
      if (hours <= 0) { stat.zero++; continue; }
      const chain = jobcodeChain(ts.jobcode_id, jobcodes);
      stat.kept++; stat.keptHours += hours;
      entries.push({
        qbtimeUserId: String(ts.user_id), person, dept, date: ts.date, hours,
        childName: chain.child, parentName: chain.parent, childType: chain.childType
      });
    }
    if (!data.more) break;
    page++;
    if (page > 400) { stat.truncated = true; break; }
  }

  console.log(`  Pages read: ${page}. Timesheets seen: ${stat.sheets} (${stat.rawHours.toFixed(2)}h raw).`);
  console.log(`  Kept: ${stat.kept} entries (${stat.keptHours.toFixed(2)}h).`);
  const dropped = stat.rawHours - stat.keptHours;
  if (dropped > 0.01) {
    console.log(`  ⚠ Dropped ${dropped.toFixed(2)}h:`);
    if (stat.excludedHours > 0) console.log(`      ${stat.excludedHours.toFixed(2)}h — excluded people (${[...EXCLUDED_PEOPLE].join(', ')})`);
    if (stat.noPersonHours > 0) console.log(`      ${stat.noPersonHours.toFixed(2)}h — unknown user`);
    if (stat.zero) console.log(`      ${stat.zero} entries with zero duration (still running, or deleted)`);
    if (stat.noDate) console.log(`      ${stat.noDate} entries with no date`);
  }
  if (stat.truncated) console.log('  ✖ PAGINATION GUARD HIT — results were truncated. Raise the page limit.');
  return entries;
}

/* -------------------------------------------------------------------- sync -- */

let GROUP_NAMES = {};
let JOBCODES = {};

async function main() {
  let stateRows;
  try { stateRows = await sbGet(`sync_state?id=eq.${STATE_ID}&select=*`); }
  catch (e) { console.error('✖ [db-read] ' + (e.message || e)); process.exit(1); }
  if (!stateRows.length) fail(`No sync_state row for '${STATE_ID}'. Run db/001_init.sql.`);
  const importFrom = day(stateRows[0].import_from) || '2025-01-01';

  GROUP_NAMES = await fetchGroups();
  JOBCODES = await fetchJobcodes();
  const startDate = importFrom;
  const endDate = isoDate(new Date());
  console.log(`Pulling QuickBooks Time timesheets ${startDate} → ${endDate}…`);
  const entries = await pullTimesheets(startDate, endDate);

  // ---- staff: upsert by qbtime_user_id (unique), never id — new rows let
  // Postgres assign their id via the column default, so nothing here has to
  // generate one. Existing rows only get a blank department backfilled, never
  // an overwrite of one a human already set.
  const existingStaff = await sbGet('staff?select=id,name,department,qbtime_user_id,active');
  const existingByQbId = new Map(existingStaff.filter(s => s.qbtime_user_id).map(s => [s.qbtime_user_id, s]));
  const newStaffRows = [];
  const newStaffNames = [];
  const deptBackfills = []; // {id, department} — patched individually, one column
  const seenUserIds = new Set(entries.map(e => e.qbtimeUserId));
  for (const uid of seenUserIds) {
    const e = entries.find(x => x.qbtimeUserId === uid);
    const existing = existingByQbId.get(uid);
    if (!existing) {
      newStaffRows.push({ name: e.person, department: e.dept || null, qbtime_user_id: uid, active: true });
      newStaffNames.push(e.person + (e.dept ? ` (${e.dept})` : ''));
    } else if (!existing.department && e.dept) {
      deptBackfills.push({ id: existing.id, department: e.dept });
    }
  }
  // A plain insert, not an upsert: every row here is genuinely new (its
  // qbtime_user_id matched nothing above), so there is no conflict to resolve
  // and no risk of the union-of-keys shaping in sbUpsert nulling out a column
  // on an existing row.
  await sbInsert('staff', newStaffRows);
  if (newStaffNames.length) console.log('  New people created (set comp on the Team page):', [...new Set(newStaffNames)].join(', '));
  // Individual single-column PATCHes, not a batch upsert — sbUpsert normalizes
  // every row in a batch to the same columns, which would null out name/active
  // on an existing person if this were merged with the insert above.
  for (const { id, department } of deptBackfills) {
    const r = await fetch(`${SUPABASE_URL}/rest/v1/staff?id=eq.${id}`, {
      method: 'PATCH', headers: { ...sb, Prefer: 'return=minimal' }, body: JSON.stringify({ department })
    });
    if (!r.ok) fail(`Supabase department backfill (staff ${id}) → ${r.status}: ${await r.text()}`);
  }

  // Re-fetch: new rows' ids were just assigned by Postgres, and a partial-column
  // upsert (department only) would otherwise leave this script's own view of
  // 'existing' rows stale.
  const staffByQbId = new Map(
    (await sbGet('staff?select=id,name,department,qbtime_user_id,active'))
      .filter(s => s.qbtime_user_id).map(s => [s.qbtime_user_id, s])
  );

  // ---- jobcode -> qbo_project_id -> deal_id -> client_id lookup ----
  // qbo_projects.jobcode is the source of truth (parsed off every QBO project's
  // name — see sync-qbo.mjs); deals.jobcode is only a partial mirror of it, so
  // this goes through the real claim, deals.qbo_project_id, instead. Only
  // won/active deals receive new actual hours — a pipeline, closed, or lost
  // deal shouldn't accumulate logged time against it going forward.
  const projects = await sbGet(`qbo_projects?jobcode=not.is.null&select=id,jobcode`);
  const projectIdByJobcode = new Map();
  for (const p of projects) {
    const code = p.jobcode.toLowerCase();
    if (projectIdByJobcode.has(code)) {
      console.log(`  ⚠ jobcode '${p.jobcode}' matches more than one QuickBooks project — keeping the first, check qbo_projects.jobcode for a duplicate.`);
      continue;
    }
    projectIdByJobcode.set(code, p.id);
  }
  const deals = await sbGet(`deals?qbo_project_id=not.is.null&status=in.(won,active)&select=id,client_id,qbo_project_id`);
  const dealByProjectId = new Map(deals.map(d => [d.qbo_project_id, d]));
  const dealByJobcode = new Map();
  for (const [code, projectId] of projectIdByJobcode) {
    const deal = dealByProjectId.get(projectId);
    if (deal) dealByJobcode.set(code, deal);
  }

  // ---- classify + aggregate to one row per staff+deal(or bucket)+day ----
  const dayEntries = new Map(); // 'staffId|dealId|date' -> {staffId, dealId, clientId, department, hours}
  const timeOffDays = new Map(); // 'staffId|kind' -> Set(dates)
  const unmatchedJobcodes = new Map(); // code -> hours, seen but no deal carries it
  const internalHours = { count: 0, hours: 0 };

  for (const e of entries) {
    const staff = staffByQbId.get(e.qbtimeUserId);
    const c = classifyEntry(e, dealByJobcode);
    if (c.type === 'timeoff') {
      const key = staff.id + '|' + c.kind;
      if (!timeOffDays.has(key)) timeOffDays.set(key, new Set());
      timeOffDays.get(key).add(e.date);
      continue;
    }
    if (c.type === 'unmatched') unmatchedJobcodes.set(c.code, (unmatchedJobcodes.get(c.code) || 0) + e.hours);
    const dealId = c.type === 'billable' ? c.dealId : null;
    const clientId = c.type === 'billable' ? c.clientId : null;
    if (!dealId) { internalHours.count++; internalHours.hours += e.hours; }
    const key = staff.id + '|' + (dealId || 'internal') + '|' + e.date;
    if (!dayEntries.has(key)) {
      dayEntries.set(key, { staffId: staff.id, dealId, clientId, department: e.dept || null, date: e.date, hours: 0 });
    }
    dayEntries.get(key).hours += e.hours;
  }

  if (unmatchedJobcodes.size) {
    console.log(`  ⚠ ${unmatchedJobcodes.size} jobcode(s) looked like a real project code but matched no won/active deal's claimed QBO project:`);
    [...unmatchedJobcodes.entries()].sort((a, b) => b[1] - a[1]).slice(0, 20)
      .forEach(([code, hrs]) => console.log(`      ${code}: ${hrs.toFixed(2)}h`));
  }
  console.log(`  Internal/non-billable/unmatched: ${internalHours.count} entries (${internalHours.hours.toFixed(2)}h) — written with deal_id null.`);

  // ---- time_entries: SYNC-OWNED, day grain. Replace the whole synced window. ----
  await sbDelete(`time_entries?source=eq.qbtime&worked_on=gte.${startDate}&worked_on=lte.${endDate}`);
  // Raising import_from (Settings) means "don't trust hours before this date at
  // all", not just "stop pulling new ones" — so anything already synced before
  // the current cutoff is purged too, every run, not only the day it moves.
  await sbDelete(`time_entries?source=eq.qbtime&worked_on=lt.${startDate}`);
  const teRows = [...dayEntries.values()].map(d => ({
    id: `qbtime:${d.staffId}:${d.dealId || 'internal'}:${d.date}`,
    staff_id: d.staffId, deal_id: d.dealId, client_id: d.clientId,
    worked_on: d.date, hours: Math.round(d.hours * 100) / 100,
    department: d.department, source: 'qbtime', synced_at: new Date().toISOString()
  }));
  await sbInsert('time_entries', teRows);
  console.log(`  Wrote ${teRows.length} time_entries rows (${startDate}→${endDate}).`);

  // ---- time_off: merge consecutive days per staff+kind into ranges, replace window ----
  // Scoped to set_by='qbtime-sync' throughout — time_off has no source column
  // like time_entries does, so this is what keeps a future human-entered
  // time-off row (a different set_by) from ever being touched by this sync.
  const existingOff = await sbGet(`time_off?set_by=eq.qbtime-sync&starts_on=lte.${endDate}&ends_on=gte.${startDate}&select=id`);
  if (existingOff.length) await sbDelete(`time_off?id=in.(${existingOff.map(r => r.id).join(',')})`);
  // Same cutoff-purge reasoning as time_entries above.
  const staleOff = await sbGet(`time_off?set_by=eq.qbtime-sync&ends_on=lt.${startDate}&select=id`);
  if (staleOff.length) await sbDelete(`time_off?id=in.(${staleOff.map(r => r.id).join(',')})`);
  const offRows = [];
  for (const [key, daySet] of timeOffDays) {
    const [staffId, kind] = key.split('|');
    for (const [starts_on, ends_on] of mergeIntoRanges([...daySet])) {
      offRows.push({ staff_id: staffId, starts_on, ends_on, kind, set_by: 'qbtime-sync' });
    }
  }
  await sbInsert('time_off', offRows);
  console.log(`  Wrote ${offRows.length} time_off range(s).`);

  await sbPatchState({
    import_from: startDate, // unchanged; kept explicit so a manual edit to widen the window is visible in the diff
    last_run_at: new Date().toISOString(),
    last_run_log: { ok: true, entries: teRows.length, timeOffRanges: offRows.length, unmatchedJobcodes: unmatchedJobcodes.size, at: new Date().toISOString() }
  });
  console.log('✔ Synced.');
}

if (process.env.NODE_ENV !== 'test') main().catch(e => die('unhandled', e));
