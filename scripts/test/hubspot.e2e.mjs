// Full run against stubbed HubSpot and Supabase. The scenarios that matter,
// post-redesign (promotion is now a human decision recorded in
// promotion_approvals, not an automatic door the sync decides on its own):
//  - an approved deal promotes: deal row created with the approval's client +
//    QBO project, promotion recorded with the real approver, approval consumed
//  - a second, independent approval for a different deal promotes too
//  - an approved deal whose HubSpot campaign dates are missing is held back —
//    not promoted, its approval stays queued (not deleted)
//  - an approval for an ALREADY-promoted deal is recognised as stale, deleted,
//    and does not create a duplicate deal/promotion
//  - an already-promoted deal gets its name (unconditionally) and jobcode
//    (only if it was null) refreshed from the fresh HubSpot mirror
//  - a deal nobody has approved yet is mirrored and never promoted, regardless
//    of pipeline — the sync no longer decides eligibility, it only consumes
//    approvals
import http from 'node:http';

const writes={}, deletes=[], rpc=[];

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
    // four human decisions sitting in the queue: D1 and D2 are clean approvals,
    // D3's dates are missing (held back at write time), D4's is stale (already
    // promoted — should be consumed and deleted without a duplicate)
    if(req.method==='GET'&&table==='promotion_approvals') return res.end(JSON.stringify([
      {hubspot_deal_id:'D1', client_id:'client-akron', qbo_project_id:'proj-akron', approved_by:'boris@elitemedia.group'},
      {hubspot_deal_id:'D2', client_id:'client-mmgy', qbo_project_id:'proj-mmgy-retainer', approved_by:'boris@elitemedia.group'},
      {hubspot_deal_id:'D3', client_id:'client-mmgy', qbo_project_id:'proj-dateless', approved_by:'boris@elitemedia.group'},
      {hubspot_deal_id:'D4', client_id:'client-mmgy', qbo_project_id:'proj-mmgy', approved_by:'boris@elitemedia.group'}
    ]));
    if(req.method==='GET') return res.end('[]');
    if(req.method==='DELETE'){deletes.push(req.url);res.statusCode=204;return res.end();}
    if(req.method==='POST'&&req.url.includes('/rpc/')){rpc.push(req.url);
      return res.end(req.url.includes('match_deals')
        ? JSON.stringify([{method:'qb-link',matched:0},{method:'jobcode',matched:0},{method:'unmatched',matched:0}])
        : '[]');}
    if(req.method==='POST'){
      const rows=JSON.parse(b);
      (writes[table]=writes[table]||[]).push(...rows);
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
check(!(writes.clients||[]).length,'the sync never creates a client itself anymore — that decision happens in the gate before an approval exists');

const dealRows=(writes.deals||[]).filter(d=>d.hubspot_deal_id);
check(dealRows.length===2,'exactly 2 deals promoted (D1, D2 — clean approvals): got '+dealRows.length);
const d1=dealRows.find(d=>d.hubspot_deal_id==='D1')||{};
check(d1.flight_start==='2026-09-14'&&d1.flight_end==='2026-12-20','D1 flight keeps HubSpot exact dates: '+d1.flight_start+'..'+d1.flight_end);
check(d1.jobcode==='26akrn260101','D1 jobcode carried from the mirror');
check(d1.client_id==='client-akron'&&d1.qbo_project_id==='proj-akron','D1 gets the approval\'s client + project, not an auto-guess');
check(d1.set_by==='boris@elitemedia.group','D1\'s set_by is the real approver, not hubspot-sync');

const proms=(writes.promotions||[]);
check(proms.length===2,'2 promotions recorded (D1, D2)');
const p1=proms.find(p=>p.hubspot_deal_id==='D1')||{};
check(p1.promoted_by==='boris@elitemedia.group','promoted_by is the real approver, not the literal string hubspot-sync');
check(p1.source_payload&&p1.source_payload.amount===12000000,'as-sold amount preserved in the promotion snapshot');
check(!proms.find(p=>p.hubspot_deal_id==='D4'),'stale D4 approval did not create a second promotion');
check(!dealRows.find(d=>d.hubspot_deal_id==='D4'),'stale D4 approval did not create a duplicate deal row');
check(!dealRows.find(d=>d.hubspot_deal_id==='D3'),'D3 (dateless) held back — not promoted despite having an approval');
check(!dealRows.find(d=>d.hubspot_deal_id==='D6'),'D6 never promoted — nobody approved it, regardless of pipeline');

check(deletes.some(u=>u.includes('promotion_approvals')&&u.includes('D1')),'D1 approval consumed (deleted) after promoting');
check(deletes.some(u=>u.includes('promotion_approvals')&&u.includes('D2')),'D2 approval consumed (deleted) after promoting');
check(deletes.some(u=>u.includes('promotion_approvals')&&u.includes('D4')),'D4 stale approval deleted (cleanup) even though nothing was promoted');
check(!deletes.some(u=>u.includes('promotion_approvals')&&u.includes('D3')),'D3 approval stays queued — held back, not consumed, so it can promote once dates are fixed');

const refreshedD4=(writes.deals||[]).find(d=>d._patchUrl&&d._patchUrl.includes('uuid-existing-d4'));
check(!!refreshedD4,'already-promoted D4 got a refresh PATCH');
check(refreshedD4&&refreshedD4.name==='Already Promoted Deal (Renewed)','D4\'s stale name refreshed unconditionally from the mirror');
check(refreshedD4&&refreshedD4.jobcode==='26mmgy260701','D4\'s null jobcode filled from the mirror');

check(rpc.some(u=>u.includes('match_deals_to_projects')),'matcher still runs as a residual fill-gaps pass');
const state=(writes.sync_state||[]);
const lastState=state[state.length-1]||{};
check('flighted' in (lastState.last_run_log||{}), 'run log carries the flighted counter');
check((lastState.last_run_log||{}).held_back&&lastState.last_run_log.held_back.some(s=>s.includes('Dateless Deal')),
  'run log names the dateless deal under held_back, with its reason');

console.log(bad?'\nE2E FAILED':'\nall e2e checks passed');
hub.close();supa.close();process.exit(bad);
