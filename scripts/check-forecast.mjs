// Forecast page checks — run: node scripts/check-forecast.mjs
// 1. the module script parses
// 2. renderTable() references nothing that exists only inside render() —
//    property accesses (r.cogs) and string/template contents don't count
import { readFileSync, writeFileSync } from 'fs';
import { execSync } from 'child_process';

const html = readFileSync(new URL('../app/forecast.html', import.meta.url), 'utf8');
const src = html.match(/<script type="module">([\s\S]*?)<\/script>/)[1];

// -- 1. syntax
const stub = src.replace(/import[^;]*from '.\/assets\/shell.js[^']*';/,
  'const boot=()=>{},fmt$=()=>{},esc=()=>{},barChart=()=>{};');
writeFileSync('/tmp/_fc_check.mjs', stub);
execSync('node --check /tmp/_fc_check.mjs', { stdio: 'inherit' });

// -- 2. scope: render-locals must not leak into renderTable as bare identifiers
const rStart  = src.indexOf('function render() {');
const rtStart = src.indexOf('function renderTable() {');
const rtEnd   = src.indexOf('\n  }', src.indexOf("el.querySelectorAll('tr.deallist')")) + 4;
const renderBody = src.slice(rStart, rtStart);
const rtBody     = src.slice(rtStart, rtEnd);

const renderLocals = new Set([...renderBody.matchAll(/const (\w+)\s*=/g)].map(m => m[1]));
const rtLocals     = new Set([...rtBody.matchAll(/(?:const|let|function)\s+(\w+)/g)].map(m => m[1]));
const moduleLevel  = new Set([...src.slice(0, rStart).matchAll(/(?:const|let|function)\s+(\w+)/g)].map(m => m[1]));

let bad = 0;
// scan CODE only: strip comments, then string/template contents (keep ${...} code)
const codeOnly = body => body
  .replace(/\/\/[^\n]*/g, '')
  .replace(/`(?:[^`\\$]|\\.|\$(?!\{)|\$\{[^}]*\})*`/g, m =>
    [...m.matchAll(/\$\{([^}]*)\}/g)].map(x => x[1]).join(';'))
  .replace(/'(?:[^'\\]|\\.)*'/g, "''")
  .replace(/"(?:[^"\\]|\\.)*"/g, '""');
const rtCode = codeOnly(rtBody);
for (const v of renderLocals) {
  if (rtLocals.has(v) || moduleLevel.has(v)) continue;
  const re = new RegExp(String.raw`(?<![.\w'"])${v}\b(?!\s*:)`);
  if (re.test(rtCode)) { console.log('renderTable references render-local:', v); bad = 1; }
}
if (bad) { console.log('SCOPE LEAK'); process.exit(1); }

// -- 3. retired table-field names: clientRow/dealRow aggregates renamed in the
//    four-column restructure; plRows (rowFor) and the chart keep the old names
for (const dead of ['agg.revenue','agg.cogs','agg.fcCogs','agg.forecastGP','agg.actualGP',
                    'cr.revenue','cr.cogs','cr.forecastGP','cr.actualGP',
                    'totals.revenue','totals.cogs','totals.forecastGP','totals.actualGP']) {
  if (src.includes(dead)) { console.log('retired field still read:', dead); bad = 1; }
}
if (bad) { console.log('RETIRED KEYS'); process.exit(1); }
console.log('forecast checks clean: syntax ok, renderTable self-contained, no retired keys');

// -- 4. every other page's module script parses too. The scope/retired-key
//    audits above are forecast.html-specific; a syntax error anywhere else
//    is just as much a blank page in production.
import { readdirSync } from 'fs';
const appDir = new URL('../app/', import.meta.url);
for (const f of readdirSync(appDir).filter(f => f.endsWith('.html') && f !== 'forecast.html')) {
  const m = readFileSync(new URL(f, appDir), 'utf8').match(/<script type="module">([\s\S]*?)<\/script>/);
  if (!m) continue;
  // every import line, not just the first — pages may import shell.js AND a
  // shared module (capacity.js, scope-math.js); a second import left in
  // place would parse fine but hide nothing, and a stubbed first import next
  // to a real second one is not what the browser runs either
  const stubbed = m[1].replace(/import\s*\{([^}]*)\}\s*from '[^']*';/g, (_, names) =>
    'const ' + names.split(',').map(n => n.trim().split(/\s+as\s+/).pop()).filter(Boolean).map(n => `${n}=()=>{}`).join(',') + ';');
  writeFileSync('/tmp/_page_check.mjs', stubbed);
  try { execSync('node --check /tmp/_page_check.mjs', { stdio: 'pipe' }); }
  catch (e) { console.log(`SYNTAX ERROR in app/${f}:\n` + e.stderr.toString()); process.exit(1); }
  // 5. no two function declarations share a name in one scope. It parses —
  //    the later one silently wins — and 106 shipped exactly that: a server
  //    helper named act() replaced the button handler act(), and every
  //    "+ retainer" / remove / band button on Scoping died. Scope = the chain
  //    of enclosing function-ish declarations by indentation (a declaration
  //    at a shallower indent closes everything deeper), so two helpers with
  //    one name inside two different outer functions are fine.
  const seen = new Set(); const stack = [];
  for (const line of m[1].split('\n')) {
    const d = line.match(/^(\s*)(?:export\s+)?(?:async\s+)?function\s+(\w+)\s*\(/)
           || line.match(/^(\s*)(?:const|let|var)\s+(\w+)\s*=\s*(?:async\s*)?(?:function\b|\([^)]*\)\s*=>|\w+\s*=>)/);
    if (!d) continue;
    const indent = d[1].length, name = d[2], isFn = /function\s+\w+\s*\(/.test(line);
    while (stack.length && stack[stack.length - 1].indent >= indent) stack.pop();
    const key = stack.map(x => x.name).join('/') + '/' + indent + ':' + name;
    if (isFn && seen.has(key)) { console.log(`DUPLICATE FUNCTION in app/${f}: ${name}() is declared twice in the same scope — the later one silently replaces the first`); process.exit(1); }
    seen.add(key); stack.push({ indent, name });
  }
}
console.log('page checks clean: every app/*.html module script parses, no duplicate function names');
