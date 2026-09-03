// Full run against stubbed HubSpot and Supabase. What this file can still
// prove changed with 078: promotion itself is a database function now
// (promote_approval), called by the Approve button in the browser and, for
// anything still queued, by this sync. The deals/promotions/deal_lines writes
// are no longer PostgREST round trips a stub can observe — they happen inside
// Postgres, and db/078_fixture_test.sql is what proves they are correct.
//
// So the scenarios here are the sync's half of the contract:
//  - the mirror is written in full, and won-ness/pipeline are read correctly
//  - every queued approval gets exactly ONE promote_approval call, with the
//    right argument name, AFTER the mirror has been replaced (the function
//    reads pipeline_deals, so a stale mirror would promote stale data)
//  - each of the function's four answers is translated into the run log
//    correctly: promoted, already-promoted (stale), held back, and flighted vs
//    left-as-a-skeleton
//  - a promote_approval call that FAILS outright does not abort the run — the
//    remaining approvals are still attempted and the matcher still runs
//  - the sync never deletes promotion_approvals itself any more: consuming an
//    approval is the function's job, inside the same transaction as the write
//  - an already-promoted deal still gets its name (unconditionally) and
//    jobcode (only if null) refreshed from the fresh mirror
import http from 'node:http';

const writes={}, deletes=[], rpc=[], promoteCalls=[], seq=[];

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
      {id:'D1',properties:{dealname:'Akron World Cup',job_code:'26akrn260101',amount:'120000',dealstage:'won-stage',pipeline:'sales',
        closedate:'2026-08-01',campaign_start_date:'2026-09-14',campaign_end_date:'2026-12-20'},
       associations:{companies:{results:[{id:'C1'}]}}},
      {id:'D2',properties:{dealname:'MMGY Retainer',amount:'50000',dealstage:'won-stage',pipeline:'sales',
        closedate:'2026-08-10',campaign_start_date:'2027-01-05',campaign_end_date:'2027-06-15'},
       associations:{companies:{results:[{id:'C2'}]}}},
      {id:'D3',properties:{dealname:'Dateless Deal',amount:'90000',dealstage:'won-stage',pipeline:'sales',closedate:'2026-08-15'},
       associations:{companies:{results:[{id:'C2'}]}}},
      {id:'D4',properties:{dealname:'Already Promoted Deal (Renewed)',job_code:'26mmgy260701',amount:'70000',dealstage:'won-stage',pipeline:'sales',
        campaign_start_date:'2026-07-01',campaign_end_date:'2026-10-01'},
       associations:{companies:{results:[{id:'C2'}]}}},
      {id:'D5',properties:{dealname:'Open Proposal',amount:'40000',dealstage:'open-stage',pipeline:'sales'},
       associations:{companies:{results:[{id:'C2'}]}}},
      {id:'D6',properties:{dealname:'Placed: Jane Doe',amount:'25000',dealstage:'placed',pipeline:'recruiting',
        campaign_start_date:'2026-09-01',campaign_end_date:'2026-12-01'},
       associations:{companies:{results:[{id:'C2'}]}}}
    ]}));
    if(req.url.includes('/companies/batch/read')) return res.end(JSON.stringify({results:[
      {id:'C1',properties:{name:'Visit Akron'}},{id:'C2',properties:{name:'MMGY'}}]}));
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
    // D4 is already through the door
    if(req.method==='GET'&&table==='promotions') return res.end(JSON.stringify([{hubspot_deal_id:'D4'}]));
    // the already-promoted deal, with a stale name and no jobcode yet — the
    // refresh step should patch both from the fresh mirror
    if(req.method==='GET'&&table==='deals') return res.end(JSON.stringify([
      {id:'uuid-existing-d4', hubspot_deal_id:'D4', name:'Already Promoted Deal', jobcode:null}]));
    // five human decisions still queued: D1 promotes and flights, D2 promotes
    // as a skeleton, D3 is held back, D4 already went through the door in the
    // browser, and DX makes promote_approval itself fail
    if(req.method==='GET'&&table==='promotion_approvals') return res.end(JSON.stringify([
      {hubspot_deal_id:'D1', client_id:'client-akron', qbo_project_id:'proj-akron', approved_by:'boris@elitemedia.group'},
      {hubspot_deal_id:'D2', client_id:'client-mmgy', qbo_project_id:'proj-mmgy-retainer', approved_by:'boris@elitemedia.group'},
      {hubspot_deal_id:'D3', client_id:'client-mmgy', qbo_project_id:'proj-dateless', approved_by:'boris@elitemedia.group'},
      {hubspot_deal_id:'D4', client_id:'client-mmgy', qbo_project_id:'proj-mmgy', approved_by:'boris@elitemedia.group'},
      {hubspot_deal_id:'DX', client_id:'client-mmgy', qbo_project_id:'proj-x', approved_by:'boris@elitemedia.group'}
    ]));
    if(req.method==='GET') return res.end('[]');
    if(req.method==='DELETE'){deletes.push(req.url);res.statusCode=204;return res.end();}
    if(req.method==='POST'&&req.url.includes('/rpc/')){
      rpc.push(req.url);
      if(req.url.includes('match_deals'))
        return res.end(JSON.stringify([{method:'qb-link',matched:0},{method:'jobcode',matched:0},{method:'unmatched',matched:0}]));
      if(req.url.includes('promote_approval')){
        const arg=JSON.parse(b); promoteCalls.push(arg); seq.push('promote:'+arg.p_hubspot_deal_id);
        // one canned answer per shape promote_approval can return
        const A={
          // D1: promotes and flights its line items
          D1:{ok:true,already:false,deal_id:'uuid-d1',deal_name:'Akron World Cup',flighted:true,lines:1,reason:null},
          // D2: promotes, but nothing mappable -> skeleton + reason
          D2:{ok:true,already:false,deal_id:'uuid-d2',deal_name:'MMGY Retainer',flighted:false,lines:0,reason:'no line items'},
          // D3: dates went missing in HubSpot after approval -> held back
          D3:{ok:false,held_back:true,deal_name:'Dateless Deal',reason:'no campaign start date'},
          // D4: the browser's call already landed -> stale approval, consumed
          D4:{ok:true,already:true,deal_id:'uuid-existing-d4',reason:'already promoted'}
        }[arg.p_hubspot_deal_id];
        if(!A){res.statusCode=500;return res.end('{"message":"boom"}');}
        return res.end(JSON.stringify(A));
      }
      return res.end('[]');}
    if(req.method==='POST'){
      const rows=JSON.parse(b);
      (writes[table]=writes[table]||[]).push(...rows);
      seq.push('write:'+table);
      if(req.headers.prefer&&req.headers.prefer.includes('representation')){
        let seq=0;
        return res.end(JSON.stringify(rows.map(r=>({...r,id:'uuid-new-'+(++seq)}))));
      }
      res.statusCode=204;return res.end();
    }
    if(req.method==='PATCH'){
      const row=JSON.parse(b);
      (writes[table]=writes[table]||[]).push({...row, _patchUrl:req.url});
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

check((writes.pipeline_deals||[]).length===6,'all 6 deals mirrored');
const d6m=(writes.pipeline_deals||[]).find(d=>d.hubspot_deal_id==='D6')||{};
check(d6m.is_won===true&&d6m.pipeline==='Recruiting','placed candidate is recognised as won, in the Recruiting pipeline');
check(!(writes.clients||[]).length,'the sync never creates a client itself — that decision happens in the gate before an approval exists');

// ---- promotion is the database's job now; the sync only asks
check(!(writes.deals||[]).some(d=>d.hubspot_deal_id),'the sync inserts NO deal rows itself any more');
check(!(writes.promotions||[]).length,'the sync inserts NO promotion rows itself any more');
check(!(writes.deal_lines||[]).length&&!(writes.deal_line_months||[]).length,
  'the sync inserts NO deal lines itself any more — flighting moved into promote_approval');
check(!deletes.some(u=>u.includes('promotion_approvals')),
  'the sync never deletes an approval itself — the function consumes it inside the same transaction as the write');

check(promoteCalls.length===5,'promote_approval called once per queued approval: got '+promoteCalls.length);
check(promoteCalls.every(c=>typeof c.p_hubspot_deal_id==='string'),
  'called with the parameter name PostgREST needs (p_hubspot_deal_id)');
check(JSON.stringify(promoteCalls.map(c=>c.p_hubspot_deal_id).sort())===JSON.stringify(['D1','D2','D3','D4','DX']),
  'every queued approval was attempted, none skipped');
check(new Set(promoteCalls.map(c=>c.p_hubspot_deal_id)).size===promoteCalls.length,
  'no approval attempted twice in one run');

// order matters: promote_approval reads pipeline_deals, so the mirror must be
// fully replaced before any promotion is attempted — otherwise it would
// promote against last night's data
const lastMirror=seq.lastIndexOf('write:pipeline_deals');
const firstPromote=seq.findIndex(e=>e.startsWith('promote:'));
check(lastMirror>=0&&firstPromote>lastMirror,
  `the mirror is fully written before the first promotion (mirror@${lastMirror} < promote@${firstPromote})`);

check(rpc.some(u=>u.includes('match_deals_to_projects')),
  'the matcher still runs as a residual fill-gaps pass, even though one promotion failed outright');

// ---- the run log: each of the function's answers translated correctly
const state=(writes.sync_state||[]);
const log=(state[state.length-1]||{}).last_run_log||{};
check(log.ok===true,'the run is recorded as successful — a single bad approval is not a failed sync');
check(log.promoted===2,'2 promoted (D1 flighted, D2 as a skeleton): got '+log.promoted);
check(log.flighted===1,'1 of them flighted from line items: got '+log.flighted);
check((log.unflighted||[]).some(u=>/MMGY Retainer: no line items/.test(u)),
  'the skeleton is named in the run log with the reason it stayed one');
check((log.held_back||[]).some(h=>/Dateless Deal: no campaign start date/.test(h)),
  'the held-back deal is named with the reason the function gave');
check((log.held_back||[]).some(h=>/^DX: promote_approval failed/.test(h)),
  'an RPC that fails outright is logged against its deal, not swallowed');
check((log.held_back||[]).length===2,'exactly 2 held back (D3 by the function, DX by the failure): got '+(log.held_back||[]).length);
check(log.approvals_pending===2,'2 approvals left queued for the next run (D3, DX): got '+log.approvals_pending);
check('name_jobcode_refreshed' in log,'the run log still carries the refresh counter');

// ---- the refresh pass is untouched by any of this
const refreshedD4=(writes.deals||[]).find(d=>d._patchUrl&&d._patchUrl.includes('uuid-existing-d4'));
check(!!refreshedD4,'already-promoted D4 got a refresh PATCH');
check(refreshedD4&&refreshedD4.name==='Already Promoted Deal (Renewed)','D4\'s stale name refreshed unconditionally from the mirror');
check(refreshedD4&&refreshedD4.jobcode==='26mmgy260701','D4\'s null jobcode filled from the mirror');

console.log(bad?'\nE2E FAILED':'\nall e2e checks passed');
hub.close();supa.close();process.exit(bad);
