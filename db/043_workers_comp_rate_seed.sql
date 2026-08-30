-- ============================================================================
--  043 — seed workers_comp_rates (042) with public reference rates so the
--  table isn't empty on day one, per-state, editable afterward exactly like
--  every other row in that table (Settings' existing add/update/delete UI).
--
--  ⚠️  THESE ARE PUBLIC AVERAGE/ADVISORY RATES FOR NCCI CLASS 8810 (CLERICAL
--  OFFICE EMPLOYEES) — NOT EMG'S ACTUAL CONTRACTED RATE. A real premium also
--  reflects your carrier, your experience modification factor (claims
--  history), and any schedule credits/debits — this seed is a reasonable
--  starting point to replace state-by-state as you confirm each one against
--  EMG's real policy declarations pages, not a number to trust as final.
--  Sourced August 2026 (each state's own most-recent effective-date rate);
--  re-check periodically since these are reset on their own schedule per
--  state, typically annually.
--
--  Three states are deliberately NOT seeded here — all are "monopolistic
--  state fund" states where employers buy coverage directly from a state
--  fund rather than a private carrier under NCCI, so a directly-comparable
--  "$ per $100 of payroll" figure either isn't publicly confirmable or
--  (Washington) uses a fundamentally different basis:
--    - North Dakota (ND) — WSI's own classification manual, rate not found
--      in public search results at time of writing.
--    - Washington (WA) — L&I prices per HOUR WORKED, not per $100 of
--      payroll — a straight percentage figure here would misrepresent the
--      real basis entirely, not just be an approximation.
--    - Wyoming (WY) — Wyoming DWS's own manual, rate not found in public
--      search results at time of writing.
--  All three fall back to the flat settings.workers_comp_rate (041) until
--  someone looks up (or, for WA, works out a payroll-equivalent for) the
--  real number. Ohio (OH) IS seeded — its BWC "base rate" is a different
--  concept from an NCCI manual rate (before Ohio's own experience/discount
--  adjustments), included with that caveat rather than left out entirely.
-- ============================================================================

insert into workers_comp_rates (state, rate, set_by) values
  ('IN', 0.20, 'migration-043-seed'),
  ('TX', 0.20, 'migration-043-seed'),
  ('UT', 0.21, 'migration-043-seed'),
  ('VA', 0.21, 'migration-043-seed'),
  ('AR', 0.22, 'migration-043-seed'),
  ('CO', 0.22, 'migration-043-seed'),
  ('AZ', 0.23, 'migration-043-seed'),
  ('SD', 0.23, 'migration-043-seed'),
  ('TN', 0.23, 'migration-043-seed'),
  ('ID', 0.24, 'migration-043-seed'),
  ('KS', 0.24, 'migration-043-seed'),
  ('MS', 0.24, 'migration-043-seed'),
  ('NE', 0.24, 'migration-043-seed'),
  ('NC', 0.24, 'migration-043-seed'),
  ('KY', 0.25, 'migration-043-seed'),
  ('NM', 0.25, 'migration-043-seed'),
  ('SC', 0.25, 'migration-043-seed'),
  ('GA', 0.26, 'migration-043-seed'),
  ('IA', 0.26, 'migration-043-seed'),
  ('MD', 0.26, 'migration-043-seed'),
  ('MO', 0.26, 'migration-043-seed'),
  ('NV', 0.26, 'migration-043-seed'),
  ('AL', 0.27, 'migration-043-seed'),
  ('MN', 0.27, 'migration-043-seed'),
  ('NH', 0.27, 'migration-043-seed'),
  ('OR', 0.27, 'migration-043-seed'),
  ('WV', 0.27, 'migration-043-seed'),
  ('DE', 0.28, 'migration-043-seed'),
  ('ME', 0.28, 'migration-043-seed'),
  ('MI', 0.28, 'migration-043-seed'),
  ('RI', 0.28, 'migration-043-seed'),
  ('VT', 0.28, 'migration-043-seed'),
  ('WI', 0.28, 'migration-043-seed'),
  ('FL', 0.29, 'migration-043-seed'),
  ('MT', 0.29, 'migration-043-seed'),
  ('DC', 0.30, 'migration-043-seed'),
  ('IL', 0.30, 'migration-043-seed'),
  ('MA', 0.30, 'migration-043-seed'),
  ('OK', 0.30, 'migration-043-seed'),
  ('CT', 0.31, 'migration-043-seed'),
  ('LA', 0.31, 'migration-043-seed'),
  ('HI', 0.32, 'migration-043-seed'),
  ('PA', 0.32, 'migration-043-seed'),
  ('NJ', 0.33, 'migration-043-seed'),
  ('CA', 0.34, 'migration-043-seed'),
  ('AK', 0.36, 'migration-043-seed'),
  ('NY', 0.36, 'migration-043-seed'),
  ('OH', 0.0466, 'migration-043-seed')
on conflict (state) do nothing;
