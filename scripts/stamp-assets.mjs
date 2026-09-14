// Re-stamp every ?v= in app/*.html with the current short SHA.
//
// Run immediately before committing a deploy:  node scripts/stamp-assets.mjs
// (it takes the sha from `git rev-parse --short HEAD`, i.e. the commit the
// deploy is built ON — the same convention every "Stamp assets." commit has
// used, where the stamp names the previous commit and the stamping itself is
// the next one).
//
// Why this exists: the stamp is what stops GitHub Pages' CDN serving a cached
// shell.js next to fresh HTML. It was hand-edited, and it once froze for a
// dozen deploys — users ran old code and we debugged ghosts (CLAUDE.md habit
// 5). A hand-edited sed also only ever touched the two filenames someone
// remembered; this rewrites EVERY ?v= in every page, so a newly added asset
// (assets/vendor/supabase-js.min.mjs, assets/detail-charts.js, the parsers)
// cannot be left behind on an old stamp.
//
// app/forecast.html's own HTML is still not stamped — nothing can stamp the
// URL you type. ?fresh=1 remains the manual buster for a stale page.

import { readFileSync, writeFileSync, readdirSync } from 'node:fs';
import { execSync } from 'node:child_process';

const sha = (process.argv[2] || execSync('git rev-parse --short HEAD').toString()).trim();
if (!/^[0-9a-f]{7,40}$/.test(sha)) {
  console.error(`✖ "${sha}" is not a commit sha — nothing stamped.`);
  process.exit(1);
}

// Every file that can reference another asset with a stamp: the pages, and the
// modules themselves. shell.js imports the vendored supabase bundle and the
// parsers import each other — those stamps were hand-written once and then
// stood still through every deploy after, which is the same frozen-stamp
// failure habit 5 is about, just one level further in.
const root = new URL('../app/', import.meta.url);
const targets = [];
const walk = (dir, rel) => {
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    if (entry.isDirectory()) { walk(new URL(entry.name + '/', dir), rel + entry.name + '/'); continue; }
    if (/\.(html|js)$/.test(entry.name)) targets.push({ url: new URL(entry.name, dir), name: rel + entry.name });
  }
};
walk(root, '');

let stamps = 0, unchanged = 0, files = 0;
const pagesWithout = [];
const seen = new Set();
for (const t of targets) {
  const before = readFileSync(t.url, 'utf8');
  let n = 0;
  const after = before.replace(/(\.[\w./-]*\/[\w./-]+\?v=)([0-9a-f]{7,40})/g, (_, head, old) => {
    n++; if (old !== sha) stamps++; else unchanged++;
    seen.add(head.replace(/^\.\.?\//, '').slice(0, -'?v='.length));
    return head + sha;
  });
  if (after !== before) writeFileSync(t.url, after);
  if (!n && t.name.endsWith('.html')) pagesWithout.push(t.name);
  files++;
}
if (pagesWithout.length) {
  console.error(`✖ no ?v= stamp at all in: ${pagesWithout.join(', ')} — check by hand.`);
  process.exit(1);
}
console.log(`stamped ${stamps} reference(s) to ${sha} across ${files} file(s) (${unchanged} already current)`);
console.log(`assets referenced: ${[...seen].sort().join(', ')}`);
