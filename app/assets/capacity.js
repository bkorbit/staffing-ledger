// Capacity helpers shared by Hour Planning and Scoping — the ONE place both
// pages read "how loaded is this person this month" from, so a cell can never
// be amber on one page and green on the other.
//
// The numbers themselves come from the server (staff_capacity, db/095:
// weekly_capacity / 5 × business days employed × target utilization %, the
// same business-day rule Team Hours uses). This module only classifies and
// formats them; it never recomputes capacity from a comp period.
//
// Must NOT import shell.js — a second module instance would create a second
// Supabase client (see CLAUDE.md, detail-charts.js).

// Four bands, mirroring Team Hours' capacity chip: over = planned beyond the
// person's full capacity (planning > cap / util, i.e. more than 100% of their
// real hours); high = at or beyond the utilization target (the planning
// ceiling); normal = the working middle; under = less than half the target.
export function loadStatus(plannedHours, capacityRow) {
  if (!capacityRow || !(capacityRow.capacity_hours > 0)) return plannedHours > 0 ? 'over' : 'under';
  const cap = +capacityRow.capacity_hours;                       // target-utilization ceiling
  const util = +(capacityRow.utilization_pct ?? 80);
  const full = util > 0 ? cap / (util / 100) : cap;              // 100% of real hours
  if (plannedHours > full + 0.005) return 'over';
  if (plannedHours >= cap - 0.005) return 'high';
  if (plannedHours < cap * 0.5) return 'under';
  return 'normal';
}

export const statusPill = s => ({ over: 'bad', high: 'warn', normal: 'good', under: 'good' })[s] || 'good';
export const statusLabel = s => ({ over: 'over capacity', high: 'at target', normal: 'on plan', under: 'under-planned' })[s] || '';

// Free hours after a planned load, clamped so a display never shows "-0.00".
export function freeAfter(plannedHours, capacityRow) {
  if (!capacityRow) return null;
  const f = +capacityRow.capacity_hours - plannedHours;
  return Math.abs(f) < 0.005 ? 0 : f;
}

export const fmtH = h => (h == null || isNaN(h)) ? '—'
  : (Math.round(h * 100) / 100).toLocaleString(undefined, { maximumFractionDigits: 2 }) + 'h';

// Month helpers every planning grid needs (first-of-month ISO strings).
export const MO = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
export const mLabel = ymd => MO[+ymd.slice(5, 7) - 1] + ' ' + ymd.slice(2, 4);
export const shiftM = (m, n) => {
  const [y, mm] = m.slice(0, 7).split('-').map(Number);
  return new Date(Date.UTC(y, mm - 1 + n, 1)).toISOString().slice(0, 10);
};
export function monthsBetween(from, to) {
  const out = [];
  for (let m = from.slice(0, 7) + '-01'; m <= to.slice(0, 7) + '-01'; m = shiftM(m, 1)) out.push(m);
  return out;
}
export const thisMonth = () => { const d = new Date(); return `${d.getUTCFullYear()}-${String(d.getUTCMonth() + 1).padStart(2, '0')}-01`; };
