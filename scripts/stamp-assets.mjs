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

const dir = new URL('../app/', import.meta.url);
let files = 0, stamps = 0, unchanged = 0;
const seen = new Set();
for (const f of readdirSync(dir).filter(f => f.endsWith('.html')).sort()) {
  const path = new URL(f, dir);
  const before = readFileSync(path, 'utf8');
  let n = 0;
  const after = before.replace(/(\.\/assets\/[\w./-]+\?v=)([0-9a-f]{7,40})/g, (_, head, old) => {
    n++; if (old !== sha) stamps++; else unchanged++;
    seen.add(head.slice('./assets/'.length, -'?v='.length));
    return head + sha;
  });
  if (!n) { console.error(`✖ app/${f} has no ?v= stamp at all — check it by hand.`); process.exit(1); }
  if (after !== before) writeFileSync(path, after);
  files++;
}
console.log(`stamped ${stamps} reference(s) to ${sha} across ${files} page(s) (${unchanged} already current)`);
console.log(`assets: ${[...seen].sort().join(', ')}`);
