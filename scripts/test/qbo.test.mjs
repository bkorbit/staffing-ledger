process.env.NODE_ENV='test';
process.env.QBO_CLIENT_ID='x'; process.env.QBO_CLIENT_SECRET='x';
process.env.SUPABASE_SERVICE_ROLE_KEY='x'; process.env.SUPABASE_URL='http://x';
const m = await import('../sync-qbo.mjs');
let pass=0, fail=0;
const eq=(a,b,n)=>{const A=JSON.stringify(a),B=JSON.stringify(b);
  if(A===B){pass++;} else {fail++;console.log(`  FAIL ${n}\n    got ${A}\n    want ${B}`);}};

console.log('netDaysFromTerms');
eq(m.netDaysFromTerms('Net 45'),45,'Net 45');
eq(m.netDaysFromTerms('NET30'),30,'NET30');
eq(m.netDaysFromTerms('net  60'),60,'spaces');
eq(m.netDaysFromTerms('Due on receipt'),0,'due on receipt');
eq(m.netDaysFromTerms('2/10 Net 30'),30,'discount terms');
eq(m.netDaysFromTerms('15 days'),15,'bare days');
eq(m.netDaysFromTerms('Custom arrangement'),null,'unreadable -> null');
eq(m.netDaysFromTerms(''),null,'empty -> null');
eq(m.netDaysFromTerms(null),null,'null -> null');

console.log('deriveDueDate');
eq(m.deriveDueDate('2026-08-31','Net 45'),'2026-10-15','Aug 31 + net45 crosses to Oct');
eq(m.deriveDueDate('2026-01-31','Net 30'),'2026-03-02','Jan 31 + 30 in a non-leap year');
eq(m.deriveDueDate('2026-08-15','Due on receipt'),'2026-08-15','receipt = same day');
eq(m.deriveDueDate('2026-08-15','gibberish'),null,'unreadable -> null, never guessed');
eq(m.deriveDueDate(null,'Net 30'),null,'no issue date -> null');

console.log('splitPaymentLines');
eq(m.splitPaymentLines({Id:'900',TxnDate:'2026-09-10',TotalAmt:5000,
  Line:[{Amount:3000,LinkedTxn:[{TxnId:'11',TxnType:'Invoice'}]},
        {Amount:2000,LinkedTxn:[{TxnId:'12',TxnType:'Invoice'}]}]}),
 [{id:'900:0:0',invoice_id:'11',paid_on:'2026-09-10',amount:300000},
  {id:'900:1:0',invoice_id:'12',paid_on:'2026-09-10',amount:200000}],
 'one payment across two invoices splits');
eq(m.splitPaymentLines({Id:'901',TxnDate:'2026-09-11',TotalAmt:750,Line:[]}),
 [{id:'901',invoice_id:null,paid_on:'2026-09-11',amount:75000}],
 'unlinked deposit kept so cash still reconciles');
eq(m.splitPaymentLines({Id:'902',TxnDate:'2026-09-12',TotalAmt:0,Line:[]}),[],'zero payment dropped');

console.log('splitBillPaymentLines');
eq(m.splitBillPaymentLines({Id:'BP1',TxnDate:'2026-09-20',TotalAmt:1200,
  Line:[{Amount:1200,LinkedTxn:[{TxnId:'55',TxnType:'Bill'}]}]}),
 [{id:'BP1:0:0',bill_id:'bill:55',paid_on:'2026-09-20',amount:120000}],
 'bill payment links with bill: prefix matching bills.id');

console.log('lineProject');
eq(m.lineProject({AccountBasedExpenseLineDetail:{CustomerRef:{value:'77'}}}),'77','account-based');
eq(m.lineProject({ItemBasedExpenseLineDetail:{CustomerRef:{value:'88'}}}),'88','item-based');
eq(m.lineProject({AccountBasedExpenseLineDetail:{}}),null,'none -> null');

console.log('jobcodeFromName');
eq(m.jobcodeFromName('26hawt260810'),'26hawt260810','bare code');
eq(m.jobcodeFromName('Internal'),null,'no code -> null');
eq(m.jobcodeFromName('24o2kl1107240'),'24o2kl1107240','short code with an embedded digit (o2kl) still matches');

console.log(`\n${pass} passed, ${fail} failed`);
process.exit(fail?1:0);
