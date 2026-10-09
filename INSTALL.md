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

Nothing is open by default: the view has no grant and the two functions are not executable by PUBLIC,
the same convention as pg_lock_tree. A monitoring role needs three grants:

```sql
GRANT SELECT ON bloat_cause TO monitoring;
GRANT EXECUTE ON FUNCTION bloat_cause_findings(interval, bigint),
                          bloat_cause_text(interval, bigint) TO monitoring;
GRANT pg_read_all_stats TO monitoring;       -- to see other users' sessions
```

**Why EXECUTE as well as SELECT.** PostgreSQL checks a function called inside a view against the role
*using* the view, not the view's owner, so `SELECT ON bloat_cause` alone still fails on
`bloat_cause_findings()`.

**Why `pg_read_all_stats`.** Without it a role sees other users' sessions with `backend_xmin` and
`xact_start` hidden, so a session holding a table's dead rows back is invisible to it. Measured on
PostgreSQL 18 with one table, one holder and one role: with the grant the table read "held back by
session ... (idle in transaction)"; without it, the cause read "autovacuum is disabled on this table".
So for a role without `pg_read_all_stats`, every row carries a "not established" note saying a session
holding these rows back would not appear, and the cause it gives is only what it can establish.
`test/01_bloat_cause.sql` asserts that as a real role, alongside a role with no grants being refused.

**Why not SECURITY DEFINER**, as pg_lock_tree's `lock_tree_sample()` is. That function writes, and needs
its owner's rights to. These only read, and as definer they would show other users' sessions to any role
granted EXECUTE, bypassing `pg_read_all_stats`, and the note telling a role what it cannot see could never
fire. So they run with the caller's rights and say what those rights hide.

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
