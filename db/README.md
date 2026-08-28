# Database

`001_init.sql` is the initial schema. Apply it to a clean Supabase project via the
SQL editor, or with `psql` against the connection string.

## Conventions

- **Money is BIGINT cents.** Never float.
- **A month is a DATE on the 1st**, enforced by CHECK constraints.
- **Mutable tables carry `set_by` / `set_at`.** Either a human or a sync may write any
  field; what is forbidden is doing it silently.
- **SYNC-OWNED tables** (marked in the SQL) are read by the app and written only by a
  sync. Corrections happen in the source system.

## What the constraints enforce

| Rule | Constraint |
|---|---|
| A won or active deal must have a flight | `deals_check1` |
| Flight dates must be first-of-month | `deals_flight_start_check`, `deals_flight_end_check` |
| Flight end cannot precede start | `deals_check` |
| One assignment per staff/deal/month | `assignments_staff_id_deal_id_month_key` |
| A client with deals cannot be deleted | `deals_client_id_fkey` (restrict) |

The first is the important one: the old system fell back to a close date when campaign
dates were missing, turning a six-month deal into a one-month spike. That is now
impossible to store.

## Local testing

```sh
apt-get install -y postgresql
su postgres -c "/usr/lib/postgresql/16/bin/initdb -D /tmp/pgdata -A trust"
su postgres -c "/usr/lib/postgresql/16/bin/pg_ctl -D /tmp/pgdata -o '-k /tmp -p 5433' start"
su postgres -c "psql -h /tmp -p 5433 -c 'create role authenticated;' -c 'create database app;'"
su postgres -c "psql -h /tmp -p 5433 -d app -v ON_ERROR_STOP=1 -f db/001_init.sql"
```
