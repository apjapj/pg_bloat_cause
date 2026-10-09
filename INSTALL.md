# Installing pg_bloat_cause

**For: whoever installs it and whoever grants a monitoring role access to it.**

## Requirements

| | |
|---|---|
| PostgreSQL | **14 or later.** On 13 and earlier `CREATE EXTENSION` refuses, and says why. 14 reaches upstream end of life on 2026-11-12 and stays supported until PostgreSQL 19 is stable. Tested on 14 and 18. |
| Preloaded libraries | None. Pure SQL, no restart. |
| Privileges to install | A superuser, for `CREATE EXTENSION`. |
| Optional | Nothing in 0.1. `pgstattuple` will be used by a later, explicit measuring function if it is installed; it is never required and never runs implicitly. |

## Install

```bash
git clone https://github.com/apjapj/pg_bloat_cause.git
cd pg_bloat_cause
sudo make install            # copies the control file and pg_bloat_cause--0.1.sql
```

```sql
CREATE EXTENSION pg_bloat_cause;
SELECT * FROM bloat_cause_text();
```

## Grants for a monitoring role

Two grants, and the second one is not optional in practice:

```sql
GRANT SELECT ON bloat_cause TO monitoring;   -- the view; the functions are executable by PUBLIC
GRANT pg_read_all_stats TO monitoring;       -- to see other users' sessions
```

Without `pg_read_all_stats` a role sees other users' sessions with `backend_xmin` and `xact_start`
hidden, so a session holding a table's dead rows back is invisible to it, and the finding drops to the
next cause down. Measured on PostgreSQL 18 with one table, one holder and one role: with the grant the
table read "held back by session ... (idle in transaction)"; without it, "autovacuum is disabled on this
table". 0.1 does not let that pass silently: for a role without `pg_read_all_stats`, every row carries a
"not established" note saying sessions holding rows back would not appear. But the right fix is the
grant.

Nothing else is needed. `pg_locks`, `pg_prepared_xacts` and `pg_replication_slots` are readable by any
role, and `pg_relation_size()` needs no privilege on the table.

## What it reads, and what it never does

It reads `pg_stat_user_tables`, `pg_class`, `pg_stat_activity`, `pg_locks`, `pg_prepared_xacts`,
`pg_replication_slots` and `pg_stat_replication`. It writes nothing, runs no VACUUM, keeps no history
and sends no `NOTIFY` in 0.1; every function in it is `STABLE` or `IMMUTABLE`, and the test suite
asserts that none is `VOLATILE`.

## Tests

```bash
make prove                     # pgTAP: the objects, read-only, the estimate label, one finding (needs pgtap)
./scenarios/run.sh             # every cause against a real fixture, asserting the finding (see scenarios/README.md)
make lint                      # every figure the docs link to evidence is in that evidence file
```

The scenarios need a scratch server, and s3 a hot standby of it; `scenarios/standby.sh` builds a pair
from the pg_lock_tree matrix images and `scenarios/install-extension.sh` copies this extension into them,
checking each copy by md5.
