// Unit test for shell.js's instant-repeat-load cache — run: node scripts/test/shell-cache.test.mjs
//
// The cache decides what a page is allowed to show before the network answers,
// so the interesting cases are all about what it must NOT do: never replay a
// write, never keep serving an answer after this browser has written anything,
// never hand back an error response, never let a stale paint stand once the
// real answer differs. It hooks the Supabase client's fetch, so the test drives
// the real client and counts the requests that reach the wire.

import { readFileSync } from 'node:fs';

// ---- a browser, enough of one -------------------------------------------
// localStorage, modelled the way the real one behaves: stored items are
// enumerable own properties (shell.js walks Object.keys to clear the cache),
// the methods are not.
const localStorageStub = {};
Object.defineProperties(localStorageStub, {
  getItem:    { value: k => (Object.prototype.hasOwnProperty.call(localStorageStub, k) ? localStorageStub[k] : null) },
  setItem:    { value: (k, v) => { Object.defineProperty(localStorageStub, k, { value: String(v), enumerable: true, configurable: true, writable: true }); } },
  removeItem: { value: k => { delete localStorageStub[k]; } },
  clear:      { value: () => { for (const k of Object.keys(localStorageStub)) delete localStorageStub[k]; } },
});
globalThis.localStorage = localStorageStub;
const store = { set: (k, v) => localStorage.setItem(k, v), keys: () => Object.keys(localStorageStub),
                clear: () => localStorage.clear() };

let el = null;
const mkEl = () => ({ innerHTML: '', classList: { toggle(){}, add(){}, remove(){} }, style: {},
  querySelector: () => null, querySelectorAll: () => [], appendChild(){}, addEventListener(){}, remove(){} });
globalThis.document = {
  body: mkEl(),
  getElementById: id => (id === 'content' ? el : mkEl()),
  querySelector: () => mkEl(), querySelectorAll: () => [], createElement: () => mkEl(),
  addEventListener(){}, removeEventListener(){},
};
globalThis.window = { __email: null, addEventListener(){}, removeEventListener(){}, innerHeight: 800, innerWidth: 1200,
  location: { reload(){} }, setTimeout, clearTimeout };
globalThis.requestIdleCallback = undefined;

// ---- the wire ------------------------------------------------------------
let wire = [];            // every request that actually left
let answers = {};         // url fragment -> body text
const realFetch = async (url, init) => {
  const u = String(url);
  wire.push({ u, method: (init?.method || 'GET').toUpperCase(), body: init?.body ? String(init.body) : '' });
  if (u.includes('/auth/')) return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  const key = Object.keys(answers).find(k => u.includes(k));
  const body = key ? answers[key] : '[]';
  const status = body === '__500__' ? 500 : 200;
  return new Response(status === 500 ? '{"message":"boom"}' : body, { status, headers: { 'content-type': 'application/json' } });
};
globalThis.fetch = realFetch;

// a live session, so boot() does not render the login gate
const session = { access_token: 'fake.jwt', token_type: 'bearer', refresh_token: 'r',
  expires_at: Math.floor(Date.now() / 1000) + 3600, expires_in: 3600,
  user: { id: 'u1', email: 'boris@elitemedia.group', aud: 'authenticated', app_metadata: {}, user_metadata: {}, created_at: '2026-01-01' } };
store.set('sb-zytmlowigbfchfqcilrr-auth-token', JSON.stringify(session));

const shell = await import('../../app/assets/shell.js');
const { boot, supa } = shell;

// ---- harness -------------------------------------------------------------
let fails = 0;
const ok = (name, cond, detail) => { if (!cond) { fails++; console.log(`FAIL  ${name}${detail ? ' — ' + detail : ''}`); } else console.log(`pass  ${name}`); };
const sleep = ms => new Promise(r => setTimeout(r, ms));

async function load(pageId, main, opts) {
  el = mkEl();
  wire = [];
  await boot(pageId, main, opts);
  return el;
}
const payload = n => JSON.stringify({ plan_month: [{ month: '2026-09-01', gp: n }] });

// ---- 1. a second visit paints before the network ------------------------
answers = { '/rpc/forecast_page': payload(100) };
let seen = [];
const mainFc = async (s) => { const r = await s.rpc('forecast_page', { p_from: '2026-09-01', p_to: '2026-09-01' }); seen.push(r.data.plan_month[0].gp); };
await load('forecast', mainFc, { cache: true });
const firstWire = wire.filter(w => w.u.includes('/rpc/')).length;
await sleep(1600);
await load('forecast', mainFc, { cache: true });
ok('1a. first visit goes to the wire', firstWire === 1, `${firstWire} request(s)`);
ok('1b. second visit paints from the cache (same number, no wait)', seen[1] === 100);
await sleep(50);
ok('1c. and still revalidates in the background', wire.filter(w => w.u.includes('/rpc/')).length === 1);

// ---- 2. a changed answer re-renders the page ----------------------------
await sleep(1600);
answers = { '/rpc/forecast_page': payload(250) };
seen = [];
await load('forecast', mainFc, { cache: true });
await sleep(300);
ok('2a. the stale number is painted first', seen[0] === 100);
ok('2b. then the page is run again with the fresh one', seen[1] === 250, `saw ${JSON.stringify(seen)}`);
ok('2c. and the re-render costs no second round trip', wire.filter(w => w.u.includes('/rpc/')).length === 1);

// ---- 3. a write clears every page's cache -------------------------------
await sleep(1600);
seen = [];
await load('forecast', mainFc, { cache: true });
ok('3a. cached again after the re-render', seen[0] === 250);
await supa.from('deals').update({ name: 'x' }).eq('id', '1');
seen = [];
answers = { '/rpc/forecast_page': payload(999) };
await load('forecast', mainFc, { cache: true });
ok('3b. after a write the page goes back to the wire', seen[0] === 999 && seen.length === 1, `saw ${JSON.stringify(seen)}`);

// ---- 4. a write RPC is never replayed -----------------------------------
await sleep(1600);
answers = { '/rpc/promote_approval': '{"ok":true}', '/rpc/forecast_page': payload(999) };
const mainWrite = async (s) => { await s.rpc('forecast_page', { p_from: 'a', p_to: 'b' }); await s.rpc('promote_approval', { p_hubspot_deal_id: '1' }); };
await load('forecast', mainWrite, { cache: true });
await sleep(1600);
await load('forecast', mainWrite, { cache: true });
const promotes = wire.filter(w => w.u.includes('promote_approval')).length;
ok('4. promote_approval is called for real every time, never served from a cache', promotes === 1, `${promotes} call(s)`);

// ---- 5. an error is never remembered ------------------------------------
await sleep(1600);
store.clear(); store.set('sb-zytmlowigbfchfqcilrr-auth-token', JSON.stringify(session));
answers = { '/rpc/labor_page': '__500__' };
const mainErr = async (s) => { await s.rpc('labor_page', { p_from: 'a', p_to: 'b' }); };
await load('labor', mainErr, { cache: true });
await sleep(1600);
answers = { '/rpc/labor_page': JSON.stringify({ roster: [] }) };
let got = null;
await load('labor', async (s) => { const r = await s.rpc('labor_page', { p_from: 'a', p_to: 'b' }); got = r.data; }, { cache: true });
ok('5. a 500 is not stored, so the next visit asks again', got && Array.isArray(got.roster));

// ---- 6. a page that did not opt in is never cached ----------------------
await sleep(1600);
answers = { '/rpc/accounts_page': '{"accounts":[]}' };
const mainOut = async (s) => { await s.rpc('accounts_page', {}); };
await load('settings', mainOut);
await load('settings', mainOut);
ok('6. an opted-out page always goes to the wire', wire.filter(w => w.u.includes('accounts_page')).length === 1);

// ---- 7. the scope is per page, per user, per build ----------------------
const keys = [...store.keys()].filter(k => k.startsWith('pc:'));
ok('7. cache keys name the page, the user and the build', keys.every(k => k.split('|').length === 3), keys.join(' '));

// ---- 8. rpcParts asks for keys, and copes with a database that has not had
//         db/109 applied yet ----------------------------------------------
await sleep(1600);
store.clear(); store.set('sb-zytmlowigbfchfqcilrr-auth-token', JSON.stringify(session));
answers = { '/rpc/hours_page_parts': JSON.stringify({ staff: [1] }), '/rpc/hours_page': JSON.stringify({ staff: [1, 2] }) };
el = mkEl(); wire = [];
let r = await shell.rpcParts('hours_page', { p_from: 'a', p_to: 'b' }, ['staff']);
ok('8a. rpcParts calls the _parts sibling with p_parts',
   wire.some(w => w.u.includes('hours_page_parts') && w.body.includes('"p_parts":["staff"]')) && r.data.staff.length === 1);
answers = { '/rpc/hours_page': JSON.stringify({ staff: [1, 2] }) };
globalThis.fetch = async (url, init) => {
  if (String(url).includes('hours_page_parts'))
    return new Response('{"message":"Could not find the function public.hours_page_parts(p_from, p_parts, p_to) in the schema cache","code":"PGRST202"}',
      { status: 404, headers: { 'content-type': 'application/json' } });
  return realFetch(url, init);
};
r = await shell.rpcParts('hours_page', { p_from: 'a', p_to: 'b' }, ['staff']);
ok('8b. on a pre-109 database it falls back to the whole payload', r.data && r.data.staff.length === 2, JSON.stringify(r.error || r.data));
globalThis.fetch = realFetch;

// ---- 9. two identical reads in flight at once are ONE request ----------
await sleep(1600);
store.clear(); store.set('sb-zytmlowigbfchfqcilrr-auth-token', JSON.stringify(session));
answers = { '/rpc/cashflow_forecast': '[{"a":1}]' };
el = mkEl(); wire = [];
const two = await Promise.all([
  supa.rpc('cashflow_forecast', { periods: 12 }),
  supa.rpc('cashflow_forecast', { periods: 12 }),
]);
ok('9a. the same read twice at once goes to the wire once',
   wire.filter(w => w.u.includes('cashflow_forecast')).length === 1, `${wire.filter(w => w.u.includes('cashflow_forecast')).length} request(s)`);
ok('9b. and both callers get the answer', two.every(r => r.data && r.data[0].a === 1));
wire = [];
const differ = await Promise.all([
  supa.rpc('cashflow_forecast', { periods: 12 }),
  supa.rpc('cashflow_forecast', { periods: 24 }),
]);
ok('9c. different arguments are still two requests', wire.filter(w => w.u.includes('cashflow_forecast')).length === 2);

// ---- 10. a page mid-edit refuses the re-render --------------------------
await sleep(1600);
store.clear(); store.set('sb-zytmlowigbfchfqcilrr-auth-token', JSON.stringify(session));
answers = { '/rpc/scoping_list': '{"scopes":[1]}' };
let scSeen = [];
const mainSc = async (s) => { const r = await s.rpc('scoping_list'); scSeen.push(JSON.stringify(r.data)); };
await load('scoping', mainSc, { cache: true });
await sleep(1600);
answers = { '/rpc/scoping_list': '{"scopes":[1,2]}' };
let dirty = true;
scSeen = [];
await load('scoping', mainSc, { cache: true, canRerender: () => !dirty });
await sleep(300);
ok('10a. a dirty page is painted from the cache and NOT repainted underneath the user',
   scSeen.length === 1 && scSeen[0] === '{"scopes":[1]}', JSON.stringify(scSeen));
dirty = false; scSeen = [];
await load('scoping', mainSc, { cache: true, canRerender: () => !dirty });
await sleep(300);
ok('10b. and the refusal dropped the stale entry, so the next load is live',
   scSeen.length === 1 && scSeen[0] === '{"scopes":[1,2]}', JSON.stringify(scSeen));

// ---- 11. a read that fails at the network is retried; a write is not ----
await sleep(1600);
store.clear(); store.set('sb-zytmlowigbfchfqcilrr-auth-token', JSON.stringify(session));
let attempts = 0;
globalThis.fetch = async (url, init) => {
  const u = String(url);
  if (u.includes('/rest/v1/')) {
    attempts++;
    if (attempts <= 2) throw new TypeError('Failed to fetch');
  }
  return realFetch(url, init);
};
answers = { '/rpc/labor_page': '{"roster":[]}' };
el = mkEl(); wire = [];
let lp = await supa.rpc('labor_page', { p_from: 'a', p_to: 'b' });
ok('11a. a read survives two "Failed to fetch" in a row', !lp.error && lp.data && Array.isArray(lp.data.roster), JSON.stringify(lp.error));
ok('11b. and it took three attempts, not one', attempts === 3, `${attempts} attempt(s)`);
attempts = 0;
let werr = null;
try { const w = await supa.from('deals').update({ name: 'x' }).eq('id', '1'); werr = w.error; } catch (e) { werr = e; }
ok('11c. a write is NOT retried — it is not safe to repeat', attempts === 1 && !!werr, `${attempts} attempt(s), error ${!!werr}`);
attempts = 0;
globalThis.fetch = async (url, init) => {
  if (String(url).includes('/rest/v1/')) { attempts++; return new Response('', { status: 503 }); }
  return realFetch(url, init);
};
await supa.rpc('labor_page', { p_from: 'a', p_to: 'b' });
ok('11d. a 503 from the gateway is retried too', attempts === 3, `${attempts} attempt(s)`);
globalThis.fetch = realFetch;

console.log(fails ? `\n${fails} failure(s)` : `\nshell cache: all checks pass`);
process.exit(fails ? 1 : 0);
