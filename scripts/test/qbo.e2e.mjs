// End-to-end run of the whole sync against stubbed QuickBooks and Supabase.
// No network. Catches undefined variables, key-shape errors and bad table names —
// the three things that have actually broken this sync in practice.
import http from 'node:http';

const writes = {};              // table -> rows written
const qboHits = [];

const qbo = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url);
  qboHits.push(url.slice(0, 90));
  const entity = (url.match(/FROM\s+(\w+)/i) || [])[1];
  const fixtures = {
    Account: [{ Id:'1', Name:'Chase Operating', AccountType:'Bank', CurrentBalance:125000.50 },
              { Id:'2', Name:'Media Buys', AccountType:'Cost of Goods Sold', CurrentBalance:0 },
              { Id:'3', Name:'Payroll Expenses', AccountType:'Expense', CurrentBalance:0 },
              { Id:'4', Name:'Rent', AccountType:'Expense', CurrentBalance:0 }],
    Customer:[{ Id:'100', DisplayName:'Visit Akron', FullyQualifiedName:'Visit Akron' },
              { Id:'101', DisplayName:'26akrn260101 Visit Akron - World Cup', Job:true,
                FullyQualifiedName:'Visit Akron:26akrn260101 Visit Akron - World Cup',
                ParentRef:{value:'100'} }],
    Invoice: [{ Id:'900', DocNumber:'INV-1', TxnDate:'2026-01-31', DueDate:'2026-03-16',
                SalesTermRef:{name:'Net 45'}, CustomerRef:{value:'101'}, TotalAmt:50000, Balance:0,
                Line:[{Id:'1',LineNum:1,DetailType:'SalesItemLineDetail',Amount:50000,
                       SalesItemLineDetail:{ItemRef:{value:'7',name:'Paid Search Fee'},Qty:1,UnitPrice:50000}}] }],
    Payment: [{ Id:'500', TxnDate:'2026-03-10', TotalAmt:50000,
                Line:[{Amount:50000, LinkedTxn:[{TxnId:'900',TxnType:'Invoice'}]}] }],
    Bill:    [{ Id:'600', TxnDate:'2026-02-01', DueDate:'2026-03-03', TotalAmt:20000, Balance:20000,
                VendorRef:{name:'Trade Desk'}, SalesTermRef:{name:'Net 30'},
                Line:[{Id:'1',LineNum:1,Amount:20000,
                       AccountBasedExpenseLineDetail:{AccountRef:{value:'2',name:'Media Buys'},CustomerRef:{value:'101'}}}] }],
    Purchase:[{ Id:'700', TxnDate:'2026-02-05', TotalAmt:900, PaymentType:'CreditCard',
                Line:[{Id:'1',LineNum:1,Amount:900,
                       AccountBasedExpenseLineDetail:{AccountRef:{value:'4',name:'Rent'}}}] }],
    // journal rows deliberately lack qbo_customer_name — the PGRST102 shape trap
    JournalEntry:[{ Id:'800', TxnDate:'2026-02-28', DocNumber:'JE-2',
                Line:[{Id:'1',LineNum:1,Amount:400,
                       JournalEntryLineDetail:{PostingType:'Debit',AccountRef:{value:'4',name:'Rent'}}}] }],
    BillPayment:[{ Id:'650', TxnDate:'2026-03-01', TotalAmt:20000,
                Line:[{Amount:20000, LinkedTxn:[{TxnId:'600',TxnType:'Bill'}]}] }]
  };
  res.setHeader('content-type','application/json');
  if (url.includes('COUNT(*)')) return res.end(JSON.stringify({QueryResponse:{totalCount:1}}));
  const startPos = +((url.match(/STARTPOSITION\s+(\d+)/i)||[])[1] || 1);
  res.end(JSON.stringify({ QueryResponse: startPos > 1 ? {} : { [entity]: fixtures[entity] || [] } }));
});

const sb = http.createServer((req, res) => {
  let b=''; req.on('data',c=>b+=c);
  req.on('end',()=>{
    const table=(req.url.match(/rest\/v1\/([a-z_]+)/)||[])[1];
    if (req.method==='GET' && table==='sync_state') {
      res.setHeader('content-type','application/json');
      return res.end(JSON.stringify([{id:'quickbooks',realm_id:'999',refresh_token:'RT1-x',import_from:'2025-01-01'}]));
    }
    if (req.method==='GET') { res.setHeader('content-type','application/json'); return res.end('[]'); }
    if (req.method==='POST' && b) {
      const rows=JSON.parse(b);
      (writes[table]=writes[table]||[]).push(...rows);
      const shapes=new Set(rows.map(r=>Object.keys(r).sort().join('|')));
      if (shapes.size>1) { console.log(`  !! ${table}: ${shapes.size} different key shapes in one batch`); process.exitCode=1; }
    }
    res.statusCode=204; res.end();
  });
});

const token = http.createServer((req,res)=>{
  res.setHeader('content-type','application/json');
  res.end(JSON.stringify({access_token:'at', refresh_token:'RT1-x'}));
});

await new Promise(r=>qbo.listen(46001,r));
await new Promise(r=>sb.listen(46002,r));
await new Promise(r=>token.listen(46003,r));

process.env.SUPABASE_URL='http://127.0.0.1:46002';
process.env.SUPABASE_SERVICE_ROLE_KEY='k';
process.env.QBO_CLIENT_ID='c'; process.env.QBO_CLIENT_SECRET='s';
process.env.QBO_BASE_URL='http://127.0.0.1:46001';
process.env.QBO_TOKEN_URL='http://127.0.0.1:46003';

await import('../sync-qbo.mjs');
await new Promise(r=>setTimeout(r,3000));

console.log('\n--- tables written ---');
const expect=['qbo_accounts','qbo_projects','invoices','invoice_lines','payments','bills','bill_lines','bill_payments'];
let missing=[];
expect.forEach(t=>{
  const n=(writes[t]||[]).length;
  console.log(`  ${t.padEnd(16)} ${n}`);
  if(!n) missing.push(t);
});
if (missing.length){ console.log('\nMISSING WRITES: '+missing.join(', ')); process.exitCode=1; }
else console.log('\nall expected tables written');
const noId=(writes.bill_lines||[]).filter(l=>!l.account_id);
console.log(noId.length? 'LINES WITHOUT account_id: '+noId.length : 'every bill line carries an account_id');
if (noId.length) process.exitCode=1;
qbo.close(); sb.close(); token.close();
