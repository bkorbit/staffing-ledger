// Migration syntax floor — run: node scripts/check-sql.mjs
//
// Migrations here are pasted into the Supabase SQL editor by hand, so a
// trivial mistake costs a round trip and, worse, can leave a migration half
// applied. This catches the one class of error that is invisible to reading:
// a string literal that never closes.
//
// It exists because 086 shipped with  'QuickBooks' account_type: …'  inside a
// comment body — an apostrophe that should have been doubled. Postgres read it
// as the end of the literal and choked on the next word. Counting quotes does
// NOT find this: the stray quote makes the file's total even again as often as
// not, and a regex that stops at the first semicolon trips over the semicolons
// inside comment prose. Only walking the file as SQL works.
//
// Deliberately not a SQL parser. It tracks exactly three things — line
// comments, single-quoted strings with '' escapes, and $$-quoted bodies — and
// reports a file that ends anywhere other than in code.
import { readdirSync, readFileSync } from 'fs';

export function unterminated(sql) {
  let i = 0, state = 'code', line = 1, opened = 0;
  while (i < sql.length) {
    const c = sql[i];
    if (c === '\n') line++;
    if (state === 'code') {
      if (sql.startsWith('--', i)) { state = 'comment'; i += 2; continue; }
      if (sql.startsWith('$$', i)) { state = 'dollar'; opened = line; i += 2; continue; }
      if (c === "'") { state = 'string'; opened = line; i++; continue; }
      i++;
    } else if (state === 'comment') {
      if (c === '\n') state = 'code';
      i++;
    } else if (state === 'string') {
      // '' inside a string is an escaped apostrophe, not the end of it
      if (c === "'" && sql[i + 1] === "'") { i += 2; continue; }
      if (c === "'") { state = 'code'; i++; continue; }
      i++;
    } else {
      if (sql.startsWith('$$', i)) { state = 'code'; i += 2; continue; }
      i++;
    }
  }
  return state === 'code' ? null : { state, opened };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const dir = new URL('../db/', import.meta.url);
  const files = readdirSync(dir).filter(f => f.endsWith('.sql')).sort();
  let bad = 0;
  for (const f of files) {
    const hit = unterminated(readFileSync(new URL(f, dir), 'utf8'));
    if (hit) {
      bad++;
      console.log(`${f}: unterminated ${hit.state === 'dollar' ? '$$ block' : 'string literal'} ` +
        `opened on line ${hit.opened}` +
        (hit.state === 'string' ? " — an apostrophe inside a literal must be doubled ('')" : ''));
    }
  }
  console.log(bad ? `\n${bad} of ${files.length} migration(s) will not parse` : `sql checks clean: ${files.length} migrations parse`);
  process.exit(bad ? 1 : 0);
}
