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

console.log('monthStart');
eq(m.monthStart('2026-08-14'),'2026-08-01','mid-month truncates');
eq(m.monthStart(null),null,'null passes through');

console.log('nameKey');
eq(m.nameKey('  Visit  Akron '),'visit akron','whitespace and case collapse');
eq(m.nameKey('MMGY'),'mmgy','simple');
eq(m.nameKey(null),'','null');

console.log('promotionBlocker');
eq(m.promotionBlocker({company:'A',campaign_start:'2026-08-01',campaign_end:'2026-09-01'}),null,'complete promotes');
eq(m.promotionBlocker({company:null,campaign_start:'2026-08-01',campaign_end:'2026-09-01'}),'no company','company required');
eq(m.promotionBlocker({company:'A',campaign_start:null,campaign_end:'2026-09-01'}),'no campaign start date','start required');
eq(m.promotionBlocker({company:'A',campaign_start:'2026-08-01',campaign_end:null}),'no campaign end date','end required');
eq(m.promotionBlocker({company:'A',campaign_start:'2026-09-01',campaign_end:'2026-08-01'}),'campaign ends before it starts','order checked');

console.log('jobcode');
eq(m.jobcodeFromName('26akrn260101 Visit Akron World Cup'),'26akrn260101','extracts');
eq(m.jobcodeFromName('Visit Akron AOR'),null,'absent -> null');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail?1:0);
