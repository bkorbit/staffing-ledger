-- ============================================================================
--  004 — payment behaviour curves
--
--  Turns settled invoices into a collection-lag curve per client, plus a global
--  fallback. This is the input that makes a cashflow forecast worth having: your
--  median invoice settles 3 days past terms, but the p90 is 80 days, so the risk
--  is entirely in the spread rather than in any systematic lateness.
--
--  81 clients, 31 with six or more settled invoices. The other 50 have too little
--  history to trust on their own but too much to ignore, so rather than a cutoff —
--  which would treat five invoices as unknowable and six as gospel — each client's
--  curve is pulled toward the global one in proportion to how little data it has:
--
--      weight = n / (n + K)
--
--  With K = 6: three invoices leans two-thirds global, twelve leans two-thirds own,
--  fifty is essentially self-determined. No cliff anywhere.
-- ============================================================================

create or replace function refresh_payment_behaviour(shrink_k numeric default 6)
returns table (curve_scope text, rows_written int) as $$
begin
  delete from payment_behaviour where payment_behaviour.scope in ('client', 'global');

  -- The global curve: every settled invoice in the book. Also the prior that thin
  -- clients are pulled toward.
  insert into payment_behaviour (scope, ref, sample_n, p25_lag, median_lag, p75_lag,
                                 p90_lag, mean_lag, median_days_late, pct_on_time, computed_at)
  select 'global', 'all', count(*),
         percentile_cont(0.25) within group (order by days_to_settle)::int,
         percentile_cont(0.50) within group (order by days_to_settle)::int,
         percentile_cont(0.75) within group (order by days_to_settle)::int,
         percentile_cont(0.90) within group (order by days_to_settle)::int,
         round(avg(days_to_settle), 1),
         percentile_cont(0.50) within group (order by days_late)::int,
         round(100.0 * count(*) filter (where days_late <= 0) / nullif(count(*), 0), 1),
         now()
  from v_invoice_settlement
  where days_to_settle is not null;

  insert into payment_behaviour (scope, ref, sample_n, p25_lag, median_lag, p75_lag,
                                 p90_lag, mean_lag, median_days_late, pct_on_time, computed_at)
  with g as (select * from payment_behaviour pbg where pbg.scope = 'global'),
  raw as (
    select client_key,
           count(*) as n,
           percentile_cont(0.25) within group (order by days_to_settle) as p25,
           percentile_cont(0.50) within group (order by days_to_settle) as p50,
           percentile_cont(0.75) within group (order by days_to_settle) as p75,
           percentile_cont(0.90) within group (order by days_to_settle) as p90,
           avg(days_to_settle)                                          as mean,
           percentile_cont(0.50) within group (order by days_late)      as late,
           100.0 * count(*) filter (where days_late <= 0) / count(*)    as on_time
    from v_invoice_settlement
    where days_to_settle is not null and client_key is not null
    group by client_key
  )
  select 'client', raw.client_key, raw.n,
         round(w * raw.p25  + (1 - w) * g.p25_lag)::int,
         round(w * raw.p50  + (1 - w) * g.median_lag)::int,
         round(w * raw.p75  + (1 - w) * g.p75_lag)::int,
         round(w * raw.p90  + (1 - w) * g.p90_lag)::int,
         round(w * raw.mean + (1 - w) * g.mean_lag, 1),
         round(w * raw.late + (1 - w) * g.median_days_late)::int,
         round(w * raw.on_time + (1 - w) * g.pct_on_time, 1),
         now()
  from raw
  cross join g
  cross join lateral (select raw.n::numeric / (raw.n + shrink_k) as w) wt;

  return query
    select pb.scope::text, count(*)::int
    from payment_behaviour pb
    where pb.scope in ('client', 'global')
    group by pb.scope;
end;
$$ language plpgsql;

comment on function refresh_payment_behaviour is
  'Recomputes collection-lag curves from v_invoice_settlement. Client curves are '
  'shrunk toward the global curve by n/(n+K) so sparse history degrades smoothly '
  'instead of falling off a cliff. Safe to run any time; it replaces its own output.';

-- Readable view: the curve alongside how much of it is the client''s own data, so a
-- number can always be challenged rather than merely trusted.
create or replace view v_client_payment_curve as
select
  pb.ref                                as client_key,
  coalesce(q.name, pb.ref)              as client_name,
  pb.sample_n                           as settled_invoices,
  round(pb.sample_n::numeric / (pb.sample_n + 6) * 100)::int || '%' as own_data,
  pb.p25_lag, pb.median_lag, pb.p75_lag, pb.p90_lag,
  pb.median_days_late, pb.pct_on_time,
  pb.computed_at
from payment_behaviour pb
left join qbo_projects q on q.id = pb.ref
where pb.scope = 'client';
