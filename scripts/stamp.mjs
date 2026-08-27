// Stamp index.html with the build id and the time it was committed.
//
// Run immediately before committing: node scripts/stamp.mjs
// The tag reads "build b0827-1943 · 27 Aug 2026 19:43 UTC" — the code is compact enough
// to quote when reporting a problem, the date and time are there to be read.
//
// Times are UTC on purpose. GitHub Actions runs in UTC and so does the sandbox this is
// usually built from; a local timezone would make two stamps look out of order.

import { readFileSync, writeFileSync } from 'node:fs';

const FILE = 'index.html';
const MONTHS = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
const pad = n => String(n).padStart(2, '0');

const d = new Date();
const id = `b${pad(d.getUTCMonth() + 1)}${pad(d.getUTCDate())}-${pad(d.getUTCHours())}${pad(d.getUTCMinutes())}`;
const when = `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]} ${d.getUTCFullYear()} ` +
             `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())} UTC`;
const stamp = `build ${id} · ${when}`;

let html = readFileSync(FILE, 'utf8');

// Match whatever is currently between the ver-tag markers, so the format can change
// without this needing to know the previous one.
// div or span — the tag has moved between the two as the header was reworked.
const re = /(<(div|span) class="ver-tag">)([\s\S]*?)(<\/\2>)/;
if (!re.test(html)) {
  console.error('✖ No element with class="ver-tag" found in ' + FILE + ' — nothing stamped.');
  process.exit(1);
}
const before = html.match(re)[3];
html = html.replace(re, `$1${stamp}$4`);
writeFileSync(FILE, html);

console.log(`  was: ${before}`);
console.log(`  now: ${stamp}`);
