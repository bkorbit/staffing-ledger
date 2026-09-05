// End-to-end run of the whole sync against stubbed QuickBooks and Supabase.
// No network. Catches undefined variables, key-shape errors and bad table names —
// the three things that have actually broken this sync in practice.
import http from 'node:http';

const writes = {};              // table -> rows written
const rpcCalls = [];
const qboHits = [];

const qbo = http.createServer((req, res) => {
  const url = decodeURIComponent(req.url);
  qboHits.push(url.slice(0, 90));
  const entity = (url.match(/FROM\s+(\w+)/i) || [])[1];
  const fixtures = {
    Account: [{ Id:'1', Name:'Chase Operating', AccountType:'Bank', CurrentBalance:125000.50 },
              { Id:'2', Name:'Media Buys', AccountType:'Cost of Goods Sold', CurrentBalance:0 },
              { Id:'3', Name:'Payroll Expenses', AccountType:'Expense', CurrentBalance:0 },
              { Id:'4', Name:'Rent', AccountType:'Expense', CurrentBalance:0 },
              // 079/080: an income account an invoice line lands on (revenue) and a
              // liability one it must NOT (a customer deposit — cash, never P&L)
              { Id:'5', Name:'Customer Deposits', AccountType:'Other Current Liability', CurrentBalance:0 },
              { Id:'6', Name:'Paid Search Fee Income', AccountType:'Income', CurrentBalance:0 }],
    // Invoice/CreditMemo/RefundReceipt lines name an ITEM, never an account;
    // QuickBooks resolves the posting account through the item's own
    // IncomeAccountRef. Item 9 deliberately has none — that is the fail-open
    // case, and it must keep its line rather than drop it (080).
    Item:    [{ Id:'7', Name:'Paid Search Fee', IncomeAccountRef:{value:'6',name:'Paid Search Fee Income'} },
              { Id:'8', Name:'Media Deposit',   IncomeAccountRef:{value:'5',name:'Customer Deposits'} },
              { Id:'9', Name:'Unmapped Thing' }],
    Customer:[{ Id:'100', DisplayName:'Visit Akron', FullyQualifiedName:'Visit Akron' },
              { Id:'101', DisplayName:'26akrn260101 Visit Akron - World Cup', Job:true,
                FullyQualifiedName:'Visit Akron:26akrn260101 Visit Akron - World Cup',
                ParentRef:{value:'100'} }],
    Invoice: [{ Id:'900', DocNumber:'INV-1', TxnDate:'2026-01-31', DueDate:'2026-03-16',
                SalesTermRef:{name:'Net 45'}, CustomerRef:{value:'101'}, TotalAmt:62500, Balance:0,
                Line:[{Id:'1',LineNum:1,DetailType:'SalesItemLineDetail',Amount:50000,
                       SalesItemLineDetail:{ItemRef:{value:'7',name:'Paid Search Fee'},Qty:1,UnitPrice:50000}},
                      {Id:'2',LineNum:2,DetailType:'SalesItemLineDetail',Amount:10000,
                       SalesItemLineDetail:{ItemRef:{value:'8',name:'Media Deposit'},Qty:1,UnitPrice:10000}},
                      {Id:'3',LineNum:3,DetailType:'SalesItemLineDetail',Amount:2500,
                       SalesItemLineDetail:{ItemRef:{value:'9',name:'Unmapped Thing'},Qty:1,UnitPrice:2500}}] }],
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
    if (req.method==='POST' && req.url.includes('/rpc/')) {
      rpcCalls.push(req.url.split('/rpc/')[1]);
      res.setHeader('content-type','application/json');
      return res.end('[]');
    }
    if (req.method==='POST' && b) {
      const rows=JSON.parse(b);
      if (!Array.isArray(rows)) { console.log(`  !! non-array POST to ${table}`); process.exitCode=1; }
      else {
        (writes[table]=writes[table]||[]).push(...rows);
        const shapes=new Set(rows.map(r=>Object.keys(r).sort().join('|')));
        if (shapes.size>1) { console.log(`  !! ${table}: ${shapes.size} different key shapes in one batch`); process.exitCode=1; }
      }
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
console.log(rpcCalls.includes('refresh_payment_behaviour')
  ? 'payment curves refreshed as part of the run'
  : (process.exitCode=1, 'CURVE REFRESH WAS NOT CALLED'));
const noId=(writes.bill_lines||[]).filter(l=>!l.account_id);
console.log(noId.length? 'LINES WITHOUT account_id: '+noId.length : 'every bill line carries an account_id');
if (noId.length) process.exitCode=1;

// 079/080: an invoice line's posting account comes from its item, and a line
// whose item has no account KEEPS ITS LINE with a null account. Dropping it
// the way salesCostRow drops a credit-memo line would delete revenue, so the
// count is asserted as hard as the mapping is.
const il=writes.invoice_lines||[];
const byItem=Object.fromEntries(il.map(l=>[l.item_id,l]));
const want=[
  ['3 invoice lines kept, none dropped', il.length===3, `got ${il.length}`],
  ['income item -> its income account', byItem['7'] && byItem['7'].account_id==='6',
     `got ${byItem['7'] && byItem['7'].account_id}`],
  ['deposit item -> its liability account', byItem['8'] && byItem['8'].account_id==='5',
     `got ${byItem['8'] && byItem['8'].account_id}`],
  ['unmapped item -> null account, line kept', byItem['9'] && byItem['9'].account_id===null,
     `got ${byItem['9'] && byItem['9'].account_id}`]
];
want.forEach(([label,ok,detail])=>{
  console.log(ok ? `  ${label}` : `  FAIL ${label} — ${detail}`);
  if (!ok) process.exitCode=1;
});
qbo.close(); sb.close(); token.close();
