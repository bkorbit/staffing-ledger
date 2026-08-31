process.env.NODE_ENV='test';
process.env.QBTIME_TOKEN='x';
process.env.SUPABASE_SERVICE_ROLE_KEY='x'; process.env.SUPABASE_URL='http://x';
const m = await import('../sync-qbtime.mjs');
let pass=0, fail=0;
const eq=(a,b,n)=>{const A=JSON.stringify(a),B=JSON.stringify(b);
  if(A===B){pass++;} else {fail++;console.log(`  FAIL ${n}\n    got ${A}\n    want ${B}`);}};

console.log('jobcodeFromName');
eq(m.jobcodeFromName('26hawt260810'),'26hawt260810','bare code');
eq(m.jobcodeFromName('Client Name (26hawt260810)'),'26hawt260810','embedded in a longer name');
eq(m.jobcodeFromName('EMG:26hawt260810'),'26hawt260810','embedded after a colon');
eq(m.jobcodeFromName('Internal'),null,'no code -> null');
eq(m.jobcodeFromName(''),null,'empty -> null');
eq(m.jobcodeFromName(null),null,'null -> null');
eq(m.jobcodeFromName('26h1234'),null,'letters run too short (min 3) -> null');
eq(m.jobcodeFromName('2024ab12345'),null,'a contiguous run with no internal word boundary never matches, even though a substring looks right -> null');
eq(m.jobcodeFromName('24o2kl1107240'),'24o2kl1107240','short code with an embedded digit (o2kl) still matches, shortest split wins');
eq(m.jobcodeFromName('O2KL - Analytics Retainer (24o2kl1107240)'),'24o2kl1107240','digit-in-code, embedded in a longer name');

console.log('jobcodeChain');
const jobcodes = {
  1: { id: 1, name: 'Acme Corp', parent_id: 0, type: 'regular' },
  2: { id: 2, name: 'Acme Corp:26acme260101', parent_id: 1, type: 'regular' },
  3: { id: 3, name: 'PTO', parent_id: 0, type: 'pto' },
  4: { id: 4, name: 'Internal', parent_id: 0, type: 'regular' },
  5: { id: 5, name: 'Design', parent_id: 4, type: 'regular' },
};
eq(m.jobcodeChain(2, jobcodes), { child: 'Acme Corp:26acme260101', parent: 'Acme Corp', childType: 'regular' }, 'project under a customer');
eq(m.jobcodeChain(1, jobcodes), { child: 'Acme Corp', parent: '', childType: 'regular' }, 'top-level customer, no parent');
eq(m.jobcodeChain(3, jobcodes), { child: 'Time off', parent: '', childType: 'pto' }, 'pto-typed jobcode substitutes the placeholder name');
eq(m.jobcodeChain(5, jobcodes), { child: 'Design', parent: 'Internal', childType: 'regular' }, 'sub-jobcode under Internal');
eq(m.jobcodeChain(999, jobcodes), { child: '', parent: '', childType: '' }, 'unknown id -> all blank, never throws');

console.log('classifyEntry');
const dealByJobcode = new Map([['26acme260101', { id: 'deal-1', client_id: 'client-1' }]]);
eq(m.classifyEntry({ childName: 'Acme Corp:26acme260101', parentName: 'Acme Corp', childType: 'regular' }, dealByJobcode),
  { type: 'billable', dealId: 'deal-1', clientId: 'client-1' }, 'child jobcode carries the code, matches a deal');
eq(m.classifyEntry({ childName: 'Acme Corp', parentName: '', childType: 'regular' }, dealByJobcode),
  { type: 'internal' }, 'a real customer name with no embedded code at all -> internal, not unmatched');
eq(m.classifyEntry({ childName: '26acme260101', parentName: 'Acme Corp', childType: 'regular' }, new Map()),
  { type: 'unmatched', code: '26acme260101' }, 'real-looking code but no deal carries it — flagged, not silently dropped');
eq(m.classifyEntry({ childName: 'Time off', parentName: '', childType: 'pto' }, dealByJobcode),
  { type: 'timeoff', kind: 'pto' }, 'typed time-off prefers the QuickBooks Time type over the placeholder name');
eq(m.classifyEntry({ childName: 'Sick Day', parentName: 'Acme Corp', childType: 'regular' }, dealByJobcode),
  { type: 'timeoff', kind: 'Sick Day' }, 'name-matched time-off with no special type uses the child name');
eq(m.classifyEntry({ childName: 'Planning', parentName: 'Vacation', childType: 'regular' }, dealByJobcode),
  { type: 'timeoff', kind: 'Vacation' }, 'parent name matches time-off even though the child name does not');
eq(m.classifyEntry({ childName: 'Design', parentName: 'Internal', childType: 'regular' }, dealByJobcode),
  { type: 'internal' }, 'parent name matches the internal list');
eq(m.classifyEntry({ childName: 'Admin', parentName: '', childType: 'regular' }, dealByJobcode),
  { type: 'internal' }, 'child name matches the internal list directly (no jobcode to even try)');
eq(m.classifyEntry({ childName: '', parentName: '', childType: '' }, dealByJobcode),
  { type: 'internal' }, 'unresolvable jobcode (id not found upstream) falls back to internal, never throws');

console.log('planStaffUpdates');
eq(m.planStaffUpdates(
  [{ qbtimeUserId: '1', person: 'Jane Doe', dept: 'Creative' }],
  []
), { newStaffRows: [{ name: 'Jane Doe', department: 'Creative', qbtime_user_id: '1', active: true }],
     newStaffNames: ['Jane Doe (Creative)'], deptBackfills: [], qbIdBackfills: [] },
  'no candidates at all -> plain new-row insert, unchanged from before this feature');
eq(m.planStaffUpdates(
  [{ qbtimeUserId: '1', person: 'Jane Doe', dept: 'Creative' }],
  [{ id: 'staff-1', name: 'Jane Doe', department: null, qbtime_user_id: null, active: true }]
), { newStaffRows: [], newStaffNames: [], deptBackfills: [{ id: 'staff-1', department: 'Creative' }],
     qbIdBackfills: [{ id: 'staff-1', qbtime_user_id: '1', name: 'Jane Doe' }] },
  'hand-created row with no qbtime_user_id yet, exact name match -> linked instead of duplicated, blank dept backfilled too');
eq(m.planStaffUpdates(
  [{ qbtimeUserId: '1', person: 'JANE doe ', dept: null }],
  [{ id: 'staff-1', name: ' Jane Doe', department: 'Creative', qbtime_user_id: null, active: true }]
), { newStaffRows: [], newStaffNames: [], deptBackfills: [],
     qbIdBackfills: [{ id: 'staff-1', qbtime_user_id: '1', name: 'JANE doe ' }] },
  'match is case-insensitive and trims whitespace on both sides; existing department never touched when the sync has none to offer');
eq(m.planStaffUpdates(
  [{ qbtimeUserId: '1', person: 'Jane Doe', dept: null }],
  [{ id: 'staff-1', name: 'Jane Doe', department: null, qbtime_user_id: '999', active: true }]
), { newStaffRows: [{ name: 'Jane Doe', department: null, qbtime_user_id: '1', active: true }],
     newStaffNames: ['Jane Doe'], deptBackfills: [], qbIdBackfills: [] },
  'a same-named row that already has a DIFFERENT qbtime_user_id is never a backup-match candidate -> genuinely new person gets a new row');
eq(m.planStaffUpdates(
  [{ qbtimeUserId: '1', person: 'Jane Doe', dept: null }],
  [
    { id: 'staff-1', name: 'Jane Doe', department: null, qbtime_user_id: null, active: true },
    { id: 'staff-2', name: 'Jane Doe', department: null, qbtime_user_id: null, active: false }
  ]
), { newStaffRows: [{ name: 'Jane Doe', department: null, qbtime_user_id: '1', active: true }],
     newStaffNames: ['Jane Doe'], deptBackfills: [], qbIdBackfills: [] },
  'two real people happen to share a name and BOTH are unlinked -> genuinely ambiguous, left alone (falls through to new row) rather than guessing which one is right');
eq(m.planStaffUpdates(
  [
    { qbtimeUserId: '1', person: 'Jane Doe', dept: null },
    { qbtimeUserId: '2', person: 'Jane Doe', dept: 'Analytics' }
  ],
  [{ id: 'staff-1', name: 'Jane Doe', department: null, qbtime_user_id: null, active: true }]
), { newStaffRows: [{ name: 'Jane Doe', department: 'Analytics', qbtime_user_id: '2', active: true }],
     newStaffNames: ['Jane Doe (Analytics)'],
     deptBackfills: [],
     qbIdBackfills: [{ id: 'staff-1', qbtime_user_id: '1', name: 'Jane Doe' }] },
  'exactly one candidate but TWO distinct QBT ids share that name in the same run -> only the first claims it, the second gets a real new row, never double-claimed');

console.log('mergeIntoRanges');
eq(m.mergeIntoRanges([]), [], 'empty -> no ranges');
eq(m.mergeIntoRanges([['2026-03-10',8]]), [{starts_on:'2026-03-10',ends_on:'2026-03-10',hours:8}], 'single day -> one one-day range');
eq(m.mergeIntoRanges([['2026-03-10',8],['2026-03-11',8],['2026-03-12',8]]),
  [{starts_on:'2026-03-10',ends_on:'2026-03-12',hours:24}], 'three consecutive full days merge into one range, hours summed');
eq(m.mergeIntoRanges([['2026-03-12',8],['2026-03-10',8],['2026-03-11',8]]),
  [{starts_on:'2026-03-10',ends_on:'2026-03-12',hours:24}], 'unsorted input still merges and sums correctly');
eq(m.mergeIntoRanges([['2026-03-10',8],['2026-03-11',8],['2026-03-14',4]]),
  [{starts_on:'2026-03-10',ends_on:'2026-03-11',hours:16},{starts_on:'2026-03-14',ends_on:'2026-03-14',hours:4}],
  'a real gap starts a new range, each range keeps its own hours sum');
eq(m.mergeIntoRanges([['2026-02-27',8],['2026-02-28',8],['2026-03-01',8]]),
  [{starts_on:'2026-02-27',ends_on:'2026-03-01',hours:24}], 'a range spanning a month boundary (28-day Feb) merges correctly');
eq(m.mergeIntoRanges([['2026-03-10',4],['2026-03-10',4],['2026-03-11',8]]),
  [{starts_on:'2026-03-10',ends_on:'2026-03-11',hours:16}],
  'two entries on the same day sum (not de-duplicated to one) — e.g. two separate time-off codes logged the same day');
eq(m.mergeIntoRanges([['2026-03-10',4],['2026-03-11',8],['2026-03-12',8]]),
  [{starts_on:'2026-03-10',ends_on:'2026-03-12',hours:20}],
  'a half-day mixed with full days in one merged range only shows up in the total (20h), not per-day');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail?1:0);
