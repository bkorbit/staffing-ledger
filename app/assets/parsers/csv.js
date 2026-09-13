// A small RFC-4180 CSV reader for the benchmark uploads — no CDN, no bundler.
// Handles quoted fields with doubled quotes, embedded newlines, CR/LF/CRLF, a
// UTF-8 BOM, and picks the delimiter (comma / tab / semicolon) from the first
// non-empty line. Numbers strip currency symbols, thousands separators and %;
// "(1,234)" is negative; "--" and blanks are 0. Dates become first-of-month
// ISO strings because the benchmark grain is deal × department × MONTH.

export function parseCSV(text) {
  let s = String(text || '');
  if (s.charCodeAt(0) === 0xFEFF) s = s.slice(1);
  const firstLine = (s.split(/\r?\n/).find(l => l.trim().length) || '');
  const counts = { ',': (firstLine.match(/,/g) || []).length, '\t': (firstLine.match(/\t/g) || []).length, ';': (firstLine.match(/;/g) || []).length };
  const delim = Object.entries(counts).sort((a, b) => b[1] - a[1])[0][0];
  const rows = []; let row = [], field = '', q = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) {
      if (c === '"') { if (s[i + 1] === '"') { field += '"'; i++; } else q = false; }
      else field += c;
    } else if (c === '"') q = true;
    else if (c === delim) { row.push(field); field = ''; }
    else if (c === '\n' || c === '\r') {
      if (c === '\r' && s[i + 1] === '\n') i++;
      row.push(field); field = '';
      if (row.some(f => f.trim() !== '')) rows.push(row);
      row = [];
    } else field += c;
  }
  if (field !== '' || row.length) { row.push(field); if (row.some(f => f.trim() !== '')) rows.push(row); }
  return rows;
}

export function parseNum(v) {
  if (v === null || v === undefined) return 0;
  let s = String(v).trim();
  if (!s || s === '--' || s === '—' || s === '-') return 0;
  const neg = /^\(.*\)$/.test(s) || /^-/.test(s);
  s = s.replace(/[()]/g, '').replace(/[^0-9.,-]/g, '');
  // "1.234,56" (EU) vs "1,234.56" / "(1,234)" (US): a comma is the decimal
  // separator only when it is the last separator AND is not followed by
  // exactly three digits (a thousands group)
  const lastComma = s.lastIndexOf(','), lastDot = s.lastIndexOf('.');
  const afterComma = lastComma >= 0 ? s.slice(lastComma + 1) : '';
  if (lastComma > lastDot && afterComma.length !== 3) s = s.replace(/\./g, '').replace(',', '.'); else s = s.replace(/,/g, '');
  const n = parseFloat(s.replace(/-/g, ''));
  if (!Number.isFinite(n)) return 0;
  return neg ? -n : n;
}

const MONTHS = { jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, sept: 9, oct: 10, nov: 11, dec: 12 };
export function toMonth(v) {
  if (v === null || v === undefined) return null;
  const s = String(v).trim();
  let m;
  if ((m = s.match(/^(\d{4})[-/.](\d{1,2})(?:[-/.](\d{1,2}))?/))) return `${m[1]}-${String(+m[2]).padStart(2, '0')}-01`;
  if ((m = s.match(/^(\d{1,2})[-/.](\d{1,2})[-/.](\d{4})/))) return `${m[3]}-${String(+m[1]).padStart(2, '0')}-01`;   // US M/D/YYYY
  if ((m = s.match(/^([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})/))) { const mo = MONTHS[m[1].slice(0, 3).toLowerCase()]; if (mo) return `${m[3]}-${String(mo).padStart(2, '0')}-01`; }
  if ((m = s.match(/^(\d{1,2})\s+([A-Za-z]{3,9})\.?\s+(\d{4})/))) { const mo = MONTHS[m[2].slice(0, 3).toLowerCase()]; if (mo) return `${m[3]}-${String(mo).padStart(2, '0')}-01`; }
  if ((m = s.match(/^([A-Za-z]{3,9})\s+(\d{4})$/))) { const mo = MONTHS[m[1].slice(0, 3).toLowerCase()]; if (mo) return `${m[2]}-${String(mo).padStart(2, '0')}-01`; }
  const d = new Date(s);
  if (!isNaN(d)) return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-01`;
  return null;
}

// header row = the first row that contains every one of the `must` names
// (case-insensitive, trimmed) — platform exports often start with a title
// block before the real header
export function findHeader(rows, must) {
  const norm = h => String(h || '').trim().toLowerCase();
  for (let i = 0; i < Math.min(rows.length, 40); i++) {
    const hs = rows[i].map(norm);
    if (must.every(group => (Array.isArray(group) ? group : [group]).some(g => hs.includes(g.toLowerCase())))) return i;
  }
  return -1;
}

// column index by any of several names; -1 when none present
export function col(headers, names) {
  const hs = headers.map(h => String(h || '').trim().toLowerCase());
  for (const n of names) { const i = hs.indexOf(n.toLowerCase()); if (i >= 0) return i; }
  for (const n of names) { const i = hs.findIndex(h => h.includes(n.toLowerCase())); if (i >= 0) return i; }
  return -1;
}
