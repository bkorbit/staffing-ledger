// Full run against stubbed HubSpot and Supabase. The scenarios that matter:
//  - a won, complete deal promotes: client created, deal skeleton, promotion recorded
//  - a second deal for the SAME company reuses the client (matched via nameKey)
//  - a won deal with no campaign dates is skipped WITH a recorded reason
//  - an already-promoted deal does not promote again (the door is one-way)
//  - an open deal is mirrored and never promoted
import http from 'node:http';

const writes={}, deletes=[], rpc=[];
let clientSeq=0;

const hub=http.createServer((req,res)=>{
  let b='';req.on('data',c=>b+=c);
  req.on('end',()=>{
    res.setHeader('content-type','application/json');
    if(req.url.startsWith('/crm/v3/pipelines/deals')) return res.end(JSON.stringify({results:[
      {id:'sales',label:'Sales Pipeline',stages:[
        {id:'won-stage',label:'Closed Won',metadata:{probability:'1.0'}},
        {id:'open-stage',label:'Proposal',metadata:{probability:'0.4'}}]},
      {id:'recruiting',label:'Recruiting',stages:[
        {id:'placed',label:'Candidate Placed',metadata:{probability:'1.0'}}]}]}));
    if(req.url.startsWith('/crm/v3/objects/deals')) return res.end(JSON.stringify({results:[
      {id:'D1',properties:{dealname:'Akron World Cup',job_code:'26akrn260101',qb_project_link:'https://app.qbo.intuit.com/app/customerdetail?nameId=4102',amount:'120000',dealstage:'won-stage',pipeline:'sales',
        closedate:'2026-08-01',campaign_start_date:'2026-09-14',campaign_end_date:'2026-12-20'},
       associations:{companies:{results:[{id:'C1'}]}}},
      {id:'D2',properties:{dealname:'Akron AOR Extension',amount:'50000',dealstage:'won-stage',pipeline:'sales',
        closedate:'2026-08-10',campaign_start_date:'2027-01-05',campaign_end_date:'2027-06-15'},
       associations:{companies:{results:[{id:'C1'}]}}},
      {id:'D3',properties:{dealname:'Dateless Deal',amount:'90000',dealstage:'won-stage',pipeline:'sales',closedate:'2026-08-15'},
       associations:{companies:{results:[{id:'C2'}]}}},
      {id:'D4',properties:{dealname:'Already Promoted Deal',amount:'70000',dealstage:'won-stage',pipeline:'sales',
        campaign_start_date:'2026-07-01',campaign_end_date:'2026-10-01'},
       associations:{companies:{results:[{id:'C2'}]}}},
      {id:'D5',properties:{dealname:'Open Proposal',amount:'40000',dealstage:'open-stage',pipeline:'sales'},
       associations:{companies:{results:[{id:'C2'}]}}},
      {id:'D6',properties:{dealname:'Placed: Jane Doe',amount:'25000',dealstage:'placed',pipeline:'recruiting',
        campaign_start_date:'2026-09-01',campaign_end_date:'2026-12-01'},
       associations:{companies:{results:[{id:'C2'}]}}},
      {id:'D7',properties:{dealname:'Mismatched Deal',amount:'30000',dealstage:'won-stage',pipeline:'sales',
        closedate:'2026-08-20',campaign_start_date:'2026-09-01',campaign_end_date:'2026-10-01'},
       associations:{companies:{results:[{id:'C3'}]}}}
    ]}));
    if(req.url.includes('/companies/batch/read')) return res.end(JSON.stringify({results:[
      {id:'C1',properties:{name:'Visit Akron'}},{id:'C2',properties:{name:'MMGY'}},{id:'C3',properties:{name:'  IMG  '}}]}));
    if(req.url.includes('/line_items/batch/read')) return res.end(JSON.stringify({results:[]}));
    res.end('{}');
  });
});

const supa=http.createServer((req,res)=>{
  let b='';req.on('data',c=>b+=c);
  req.on('end',()=>{
    const table=(req.url.match(/rest\/v1\/([a-z_]+)/)||[])[1];
    res.setHeader('content-type','application/json');
    if(req.method==='GET'&&table==='sync_state') return res.end(JSON.stringify([{id:'hubspot'}]));
    if(req.method==='GET'&&table==='promotions') return res.end(JSON.stringify([{hubspot_deal_id:'D4'}])); // D4 already through the door
    if(req.method==='GET'&&table==='settings') return res.end(JSON.stringify([{value:['Sales Pipeline']}]));
    if(req.method==='GET'&&table==='blocked_company_names') return res.end(JSON.stringify([{name_key:'img'}]));
    if(req.method==='GET') return res.end('[]');
    if(req.method==='DELETE'){deletes.push(req.url);res.statusCode=204;return res.end();}
    if(req.method==='POST'&&req.url.includes('/rpc/')){rpc.push(req.url);
      return res.end(req.url.includes('match_deals')
        ? JSON.stringify([{method:'qb-link',matched:1},{method:'jobcode',matched:0},{method:'unmatched',matched:0}])
        : '[]');}
    if(req.method==='POST'){
      const rows=JSON.parse(b);
      (writes[table]=writes[table]||[]).push(...rows);
      if(req.headers.prefer&&req.headers.prefer.includes('representation')){
        return res.end(JSON.stringify(rows.map(r=>({...r,id:'uuid-'+(++clientSeq)}))));
      }
      res.statusCode=204;return res.end();
    }
    if(req.method==='PATCH'){
      const row=JSON.parse(b);
      (writes[table]=writes[table]||[]).push(row);
      res.statusCode=204;return res.end();
    }
    res.statusCode=204;res.end();
  });
});

await new Promise(r=>hub.listen(46011,r));
await new Promise(r=>supa.listen(46012,r));
process.env.HS_BASE_URL='http://127.0.0.1:46011';
process.env.SUPABASE_URL='http://127.0.0.1:46012';
process.env.SUPABASE_SERVICE_ROLE_KEY='k'; process.env.HUBSPOT_TOKEN='t';

await import('../sync-hubspot.mjs');
await new Promise(r=>setTimeout(r,2500));

let bad=0;
const check=(cond,msg)=>{ console.log((cond?'  ok  ':'  FAIL ')+msg); if(!cond)bad=1; };

check((writes.pipeline_deals||[]).length===7,'all 7 deals mirrored');
const d6m=(writes.pipeline_deals||[]).find(d=>d.hubspot_deal_id==='D6')||{};
check(d6m.is_won===true&&d6m.pipeline==='Recruiting','placed candidate is recognised as won, in the Recruiting pipeline');
check(!(writes.deals||[]).find(d=>d.hubspot_deal_id==='D6'),'recruiting win held at the door — not promoted');
const clients=(writes.clients||[]);
check(clients.length===1,'exactly 1 client created — Akron once, reused; skipped deals create no clients: got '+clients.length);
const dealRows=(writes.deals||[]);
check(dealRows.length===2,'exactly 2 deals promoted (D1, D2): got '+dealRows.length);
const d1=dealRows.find(d=>d.hubspot_deal_id==='D1')||{};
check(d1.flight_start==='2026-09-14'&&d1.flight_end==='2026-12-20','D1 flight keeps HubSpot exact dates: '+d1.flight_start+'..'+d1.flight_end);
check(d1.jobcode==='26akrn260101','D1 jobcode extracted');
const proms=(writes.promotions||[]);
check(proms.length===2,'2 promotions recorded');
check(!proms.find(p=>p.hubspot_deal_id==='D4'),'already-promoted D4 not re-promoted');
check(!dealRows.find(d=>d.hubspot_deal_id==='D3'),'dateless D3 did not promote');
check(!dealRows.find(d=>d.hubspot_deal_id==='D5'),'open D5 did not promote');
check(!dealRows.find(d=>d.hubspot_deal_id==='D7'),'D7 (company "IMG", on the 029 blocklist) held at the door despite complete dates');
check(!clients.find(c=>c.name.trim()==='IMG'),'blocked D7 never created a client for "IMG"');
const state=(writes.sync_state||[]);
const akron2=dealRows.filter(d=>['D1','D2'].includes(d.hubspot_deal_id)).map(d=>d.client_id);
check(akron2.length===2&&akron2[0]===akron2[1],'both Akron deals share one client id');
const p1=proms.find(p=>p.hubspot_deal_id==='D1')||{};
check(p1.source_payload&&p1.source_payload.amount===12000000,'as-sold amount preserved in the promotion snapshot');
const d1m=(writes.pipeline_deals||[]).find(x=>x.hubspot_deal_id==='D1')||{};
check(d1m.jobcode==='26akrn260101','explicit job_code field wins over the name regex');
check((d1m.qbo_link||'').includes('nameId=4102'),'qb_project_link mirrored');
check(rpc.some(u=>u.includes('match_deals_to_projects')),'matcher called after promotion');
// D1 carries no line items in the fixture -> skeleton with reason; add-lines path
// is covered by unit fixtures; here assert the run log carries the counters
const lastState=state[state.length-1]||{};
check('flighted' in (lastState.last_run_log||{}), 'run log carries the flighted counter');
const skipNames=(lastState.last_run_log||{}).skipped_names||{};
check((skipNames['company name blocked (see Clients tab)']||[]).includes('Mismatched Deal'),
  'run log names D7 under the blocked-company skip reason');

console.log(bad?'\nE2E FAILED':'\nall e2e checks passed');
hub.close();supa.close();process.exit(bad);
