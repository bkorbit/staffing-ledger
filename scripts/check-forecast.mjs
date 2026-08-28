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
console.log('forecast checks clean: syntax ok, renderTable self-contained');
