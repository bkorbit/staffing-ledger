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
eq(m.promotionBlocker({company:'A',campaign_start:'2026-08-01',campaign_end:'2026-09-01'}),null,'no blocklist arg -> unblocked, backward compatible');
eq(m.promotionBlocker({company:'IMG',campaign_start:'2026-08-01',campaign_end:'2026-09-01'},new Set(['img'])),'company name blocked (see Clients tab)','blocked name (029) held at the door even with complete dates');
eq(m.promotionBlocker({company:'  IMG  ',campaign_start:'2026-08-01',campaign_end:'2026-09-01'},new Set(['img'])),'company name blocked (see Clients tab)','blocklist match runs through the same nameKey normalization');
eq(m.promotionBlocker({company:'Other Co',campaign_start:'2026-08-01',campaign_end:'2026-09-01'},new Set(['img'])),null,'a blocklist with unrelated names does not block this deal');

console.log('jobcode');
eq(m.jobcodeFromName('26akrn260101 Visit Akron World Cup'),'26akrn260101','extracts');
eq(m.jobcodeFromName('Visit Akron AOR'),null,'absent -> null');

console.log(`\n${pass} passed, ${fail} failed`);




// ---- flightFromItems: the auto-flighting at the promotion door ----
{
  const F=m.flightFromItems;
  const fl=F([{name:'Paid Search Media',amount:'180000'},{name:'Paid Search Fee',amount:'21600'}],'2026-09-01','2026-11-01');
  eq(fl.lines.length===1&&fl.lines[0].kind==='search',true,'search media+fee -> one search line');
  eq(fl.lines[0].fee_pct,12,'fee percent derived from the pair');
  eq(Object.values(fl.lines[0].months).reduce((a,b)=>a+b,0),18000000,'budget spread preserves every cent');
  eq(Object.keys(fl.lines[0].months).length,3,'spread across all 3 flight months');
  const r=F([{name:'Creative Retainer',amount:'90000'}],'2026-01-01','2026-06-01');
  eq(r.lines[0].kind==='retainer'&&r.lines[0].amount===1500000,true,'retainer flat becomes $/month');
  const u=F([{name:'Programmatic Media',amount:'500000'},{name:'Mystery',amount:'5'}],'2026-01-01','2026-02-01');
  eq(u.lines.length===0&&/unmapped/.test(u.reason),true,'one unmapped item -> no lines, a reason');
  const feeOnly=F([{name:'Programmatic Buying Fee',amount:'575000'}],'2026-06-01','2026-11-01');
  eq(feeOnly.lines[0].kind==='retainer'&&feeOnly.lines[0].amount===Math.round(57500000/6),true,'fee w/o media -> flat monthly');
  eq(F([],'2026-01-01','2026-03-01').reason,'no line items','empty items -> skeleton with reason');
}
console.log(`flighting: ${pass} passed, ${fail} failed (cumulative)`);
process.exit(fail?1:0);
