-- ============================================================================
--  047 — seed suta_rates with public per-state reference data.
--
--  ⚠️  wage_base is solid — it's set by state law, not experience-rated, and
--  sourced from published 2026 state wage-base tables. rate is a much
--  weaker placeholder than workers_comp_rates' own seed (043): SUTA rates
--  are experience-rated PER EMPLOYER based on unemployment-claims history,
--  so even a correct "new employer" rate is almost certainly NOT what an
--  established employer like EMG actually pays in any given state — your
--  real rate is on your state's annual rate determination notice. Treat
--  every rate here as a placeholder to replace, more so than workers' comp.
--
--  15 states are seeded with wage_base only (rate left null, falls back to
--  settings.suta_rate) because their published "new employer" rate isn't a
--  single clean number — it's set by industry classification or a
--  graduated schedule instead: AR, IL, LA, MD, MN, MO, MT, ND, NM, SC, UT,
--  WA, WV, WI, WY.
--
--  Mississippi is skipped entirely — no wage_base could be confirmed from
--  public sources at time of writing.
--
--  Sourced August 2026 from published state new-employer rate/wage-base
--  summaries; re-check periodically, these reset on each state's own
--  schedule (usually annually).
-- ============================================================================

insert into suta_rates (state, wage_base, rate, set_by) values
  ('AL', 8000,  2.7,   'migration-047-seed'),
  ('AK', 54200, 1.5,   'migration-047-seed'),
  ('AZ', 8000,  2.0,   'migration-047-seed'),
  ('AR', 7000,  null,  'migration-047-seed'),
  ('CA', 7000,  3.4,   'migration-047-seed'),
  ('CO', 30600, 3.05,  'migration-047-seed'),
  ('CT', 27000, 1.9,   'migration-047-seed'),
  ('DE', 14500, 1.0,   'migration-047-seed'),
  ('DC', 9000,  2.7,   'migration-047-seed'),
  ('FL', 7000,  2.7,   'migration-047-seed'),
  ('GA', 9500,  2.7,   'migration-047-seed'),
  ('HI', 64500, 2.4,   'migration-047-seed'),
  ('ID', 58300, 1.0,   'migration-047-seed'),
  ('IL', 14250, null,  'migration-047-seed'),
  ('IN', 9500,  2.5,   'migration-047-seed'),
  ('IA', 20400, 1.0,   'migration-047-seed'),
  ('KS', 15100, 1.75,  'migration-047-seed'),
  ('KY', 12000, 2.7,   'migration-047-seed'),
  ('LA', 7000,  null,  'migration-047-seed'),
  ('ME', 12000, 2.54,  'migration-047-seed'),
  ('MD', 8500,  null,  'migration-047-seed'),
  ('MA', 15000, 2.13,  'migration-047-seed'),
  ('MI', 9000,  2.7,   'migration-047-seed'),
  ('MN', 44000, null,  'migration-047-seed'),
  ('MO', 9000,  null,  'migration-047-seed'),
  ('MT', 47300, null,  'migration-047-seed'),
  ('NE', 9000,  1.25,  'migration-047-seed'),
  ('NV', 43700, 2.95,  'migration-047-seed'),
  ('NH', 14000, 2.7,   'migration-047-seed'),
  ('NJ', 44800, 2.8,   'migration-047-seed'),
  ('NM', 34800, null,  'migration-047-seed'),
  ('NY', 17600, 4.1,   'migration-047-seed'),
  ('NC', 34200, 1.0,   'migration-047-seed'),
  ('ND', 46600, null,  'migration-047-seed'),
  ('OH', 9500,  2.85,  'migration-047-seed'),
  ('OK', 25000, 1.5,   'migration-047-seed'),
  ('OR', 56700, 2.4,   'migration-047-seed'),
  ('PA', 10000, 3.822, 'migration-047-seed'),
  ('RI', 30800, 1.21,  'migration-047-seed'),
  ('SC', 14000, null,  'migration-047-seed'),
  ('SD', 15000, 1.75,  'migration-047-seed'),
  ('TN', 7000,  2.7,   'migration-047-seed'),
  ('TX', 9000,  2.7,   'migration-047-seed'),
  ('UT', 50700, null,  'migration-047-seed'),
  ('VT', 15400, 1.0,   'migration-047-seed'),
  ('VA', 8000,  2.5,   'migration-047-seed'),
  ('WA', 78200, null,  'migration-047-seed'),
  ('WV', 9500,  null,  'migration-047-seed'),
  ('WI', 14000, null,  'migration-047-seed'),
  ('WY', 33800, null,  'migration-047-seed')
on conflict (state) do nothing;
