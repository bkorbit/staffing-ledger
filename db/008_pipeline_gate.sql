-- ============================================================================
--  008 — pipelines are not all sales
--
--  The HubSpot portal turned out to contain two pipelines: the sales pipeline
--  (Prospecting → Closed Won) and a recruiting pipeline (Recruiting Started →
--  Candidate Placed). Both have a probability-1.0 terminal stage, so "probability
--  = 1 means won" would have promoted 34 candidate placements as revenue deals —
--  through a one-way door.
--
--  Two changes. The mirror now records which pipeline each deal belongs to. And
--  promotion is gated by an explicit allow-list of pipeline labels in settings:
--  a pipeline not on the list has its won deals mirrored, counted, and reported,
--  but never promoted. The empty default promotes nothing — the door opens per
--  pipeline by a person, deliberately, once.
-- ============================================================================

alter table pipeline_deals add column if not exists pipeline text;

insert into settings (key, value, set_by) values
  ('hubspot_promote_pipelines', '[]', 'seed')
on conflict (key) do nothing;

comment on column pipeline_deals.pipeline is
  'HubSpot pipeline label. Promotion only fires for pipelines named in the '
  'hubspot_promote_pipelines setting.';
