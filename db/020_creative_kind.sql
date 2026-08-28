-- ============================================================================
--  020 — 'creative' becomes a line kind.
--
--  Creative work is tracked in its own right. It bills like a retainer (flat per
--  flight month) or like hourly (rate x hours), so the kind carries a structure
--  marker in `label`: 'creative:retainer' or 'creative:hourly'. The revenue math
--  reuses the retainer / hourly formulas by that marker.
--
--  'custom' stays in the enum (Postgres enums can't drop values without a table
--  rewrite) but the UI no longer offers it — existing custom lines still read.
-- ============================================================================

alter type line_kind add value if not exists 'creative';

comment on type line_kind is
  'retainer, search, social, programmatic, hourly, creative — plus legacy custom. '
  'Creative''s billing structure lives in deal_lines.label as creative:retainer '
  'or creative:hourly.';
