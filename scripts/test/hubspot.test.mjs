process.env.NODE_ENV='test';
process.env.HUBSPOT_TOKEN='x'; process.env.SUPABASE_SERVICE_ROLE_KEY='x'; process.env.SUPABASE_URL='http://x';
const m = await import('../sync-hubspot.mjs');
let pass=0, fail=0;
const eq=(a,b,n)=>{const A=JSON.stringify(a),B=JSON.stringify(b);
  if(A===B){pass++;} else {fail++;console.log(`  FAIL ${n}: got ${A} want ${B}`);}};

console.log('hsDate');
eq(m.hsDate('2026-09-15'),'2026-09-15','plain date');
eq(m.hsDate('2026-09-15T00:00:00Z'),'2026-09-15','iso timestamp');
eq(m.hsDate('1789430400000'),'2026-09-15','epoch millis');
eq(m.hsDate(''),null,'empty');
eq(m.hsDate(null),null,'null');
eq(m.hsDate('soon'),null,'garbage -> null, never guessed');

console.log('nameKey');
eq(m.nameKey('  Visit  Akron '),'visit akron','whitespace and case collapse');
eq(m.nameKey('MMGY'),'mmgy','simple');
eq(m.nameKey(null),'','null');

console.log('jobcode');
eq(m.jobcodeFromName('26akrn260101 Visit Akron World Cup'),'26akrn260101','extracts');
eq(m.jobcodeFromName('Visit Akron AOR'),null,'absent -> null');
eq(m.jobcodeFromName('24o2kl1107240 O2KL - Analytics Retainer'),'24o2kl1107240','short code with an embedded digit (o2kl) still extracts');

console.log(`\n${pass} passed, ${fail} failed`);

// ---- the auto-flighting at the promotion door, and the write-time
// re-validation that used to be promotionBlocker(), now live in SQL:
// promote_approval() / hs_flight_lines() (db/078). They moved so that ONE
// implementation of the money math exists instead of a JS copy and a SQL copy
// drifting apart. Their cases — the ones that were here, plus adversarial
// shapes the JS never covered — are db/078_fixture_test.sql, which runs
// against a real database. Nothing in this file should reimplement them.
process.exit(fail?1:0);
