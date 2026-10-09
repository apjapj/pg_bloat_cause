# Scenario fixtures

One script per cause of bloat. Each builds real dead rows, leaves them in place together with whatever
is causing them, and prints three things side by side: what the usual hand-written query reports,
what `pgstattuple` measures, and the evidence for the cause. They exist so that the extension, when it
is written, has something to be right about, and so that every claim in the top-level README can be
checked against a run rather than taken on trust.

No extension SQL exists yet. These scripts use only PostgreSQL itself and `pgstattuple`.

## Running them

```bash
export PGHOST=127.0.0.1 PGPORT=5618 PGUSER=postgres PGPASSWORD=...
./scenarios/run.sh                     # all of them, teardown between each, output in scenarios/out/
./scenarios/s1_idle_in_transaction.sh  # one, left in place for you to look at
./scenarios/teardown.sh                # remove everything any scenario left behind
```

Run them on a **scratch server**. A horizon holder pins the whole cluster, not one database, and s7
burns 110,000 transaction ids. They need a superuser, `pgstattuple`, `max_prepared_transactions > 0`
for s4, and `wal_level = logical` for s2. Set `BC_CONTAINER` to the server's Docker container name
and s7 also reads its log.

**Starting a throwaway server for them.** Pass the settings as `postgres -c` arguments to `docker run`,
which is how the runs below were made:

```bash
docker run -d --rm --name bc-scen-14 -p 127.0.0.1:5614:5432 -e POSTGRES_PASSWORD=test pg-dev-infra-pg14 \
  postgres -c wal_level=logical -c max_prepared_transactions=10 \
           -c log_autovacuum_min_duration=0 -c autovacuum_naptime=10s
```

The two obvious alternatives both fail with these images: `ALTER SYSTEM` followed by `pg_ctl
restart`, and editing `postgresql.conf` then signalling the postmaster. The image's entrypoint exits
when the server stops, so the container goes with it and the change never takes effect.

## What each one proves

| Scenario | Builds | What it shows | Runs on |
|---|---|---|---|
| `s1_idle_in_transaction` | 100,000 rows updated while a session sits idle in transaction holding an xid | VACUUM removes **0** of the 100,000 dead rows; the holder is named with its xid age. On 14, autovacuum had run during the hold and also removed nothing, so a recent `last_autovacuum` makes the table look healthy | 14, 18 |
| `s2_logical_slot` | an inactive logical slot, 100,000 dead rows in a user table, 300 temporary-table cycles | **A logical slot does not hold back a user table.** VACUUM removed all 100,000 dead rows of `s2_orders` and could not remove 6,000 in `pg_attribute`. The slot has `xmin` NULL and only `catalog_xmin` set | 14, 18 (needs `wal_level = logical`) |
| `s3_standby_feedback` | nothing | Skipped: needs a primary and a standby, and the matrix images are single servers | none yet |
| `s4_prepared_transaction` | 100,000 rows updated after a prepared transaction took an xid | VACUUM removes 0 of 100,000; the gid, its xid age and owner are named. On 14 the usual query said 83,296 dead and 115,934 live after autovacuum's estimate, against 100,000 and 100,000 measured | 14, 18 |
| `s5_autovacuum_disabled` | two identical tables, half of each updated, one with `autovacuum_enabled = false` | The control was autovacuumed to 0 dead; the disabled one kept 50,000, against a trigger threshold of 20,050 | 14, 18 |
| `s6_thresholds_too_high` | per-table thresholds of 5,000,000 plus 0.5 per row, three rounds of updates | No autovacuum ran (`autovacuum_count` 0). The usual query said **199,996** dead rows (66.7%); `pgstattuple` measured **66,667** (20.8%) | 14, 18 |
| `s7_autovacuum_vs_lock` | an open `LOCK TABLE ... SHARE UPDATE EXCLUSIVE` with no xid, then 110,000 burned xids | Part 1: an ordinary autovacuum **does not wait**. No worker in `pg_stat_activity`, 5 `skipping vacuum ... lock not available` log lines in 40 s. Part 2: at `age(relfrozenxid)` 110,005 an anti-wraparound autovacuum **does** wait, with `wait_event_type = Lock` | 14, 18 |
| `s8_non_hot_updates` | four 20,000-row tables, every row updated once | See the table below. `n_tup_newpage_upd` cannot tell an indexed-column update from a full page | 14 (without newpage), 18 |
| `s9_two_causes` | `autovacuum_enabled = false` and a horizon holder on one table | Manual VACUUM removes 0 of 100,000, so the holder ranks first; the disabled autovacuum only matters once it is gone | 14, 18 |

Every run above was on PostgreSQL 14.24 and 18.6, in throwaway containers built from the
pg_lock_tree matrix images (`pg-dev-infra-pg14`, `pg-dev-infra-pg18`), started with `wal_level =
logical`, `max_prepared_transactions = 10`, `log_autovacuum_min_duration = 0` and **`autovacuum_naptime
= 10s`**. The short naptime makes the waits in s5 to s7 forty seconds instead of four minutes; nothing
else depends on it. The two versions agreed on every count above except where a row says otherwise.

### s8: what the counters can and cannot say

| table | why it is not HOT | `n_tup_upd` | `n_tup_hot_upd` | `n_tup_newpage_upd` (18) |
|---|---|---|---|---|
| `s8_plain_room` | it is HOT (fillfactor 50, unindexed column) | 20,000 | 20,000 | 0 |
| `s8_plain_full` | no room on the page (fillfactor 100) | 20,000 | 0 | 20,000 |
| `s8_indexed_room` | indexed column changed (fillfactor 70) | 20,000 | 0 | 11,000 |
| `s8_indexed_full` | indexed column changed (fillfactor 100) | 20,000 | 0 | 20,000 |

`s8_indexed_full` and `s8_plain_full` are identical in every counter, but their causes differ and so
do their fixes (stop indexing the column, or lower `fillfactor`). `n_tup_newpage_upd` counts where the
new row version landed, not why the update could not be HOT. What it does give is a lower bound: in
`s8_indexed_room`, 9,000 non-HOT updates stayed on their own page, and a non-HOT update that stays on
its page can only have been caused by an indexed column. So the finding can say "at least N of these
are from an indexed column" on 16 and later, and must not say more. On 14 and 15 the column does not
exist and the finding says it cannot separate the two.

## What surprised me, and what it changed

- **The headline example was wrong** (s2). The top-level README blamed a logical slot for 40% dead
  rows in `orders`. A logical slot holds `catalog_xmin` only. It does bloat the catalogs and retain
  WAL, and both are worth reporting, but not as the cause of a user table's dead rows. The README
  example now names a session.
- **Autovacuum does not wait on a lock** (s7). It skips the table, so "a worker waiting on this table"
  finds nothing in the common case. The evidence is a stale `last_autovacuum`, a conflicting lock in
  `pg_locks`, and a log line only if `log_autovacuum_min_duration >= 0`. Only the anti-wraparound case
  waits, and that is the urgent one.
- **A per-table vacuum threshold is not the whole threshold** (s6). The first draft set only the
  dead-row threshold, and the insert-based trigger (13 and later) ran autovacuum anyway, which removed
  the update's dead rows too. A threshold finding has to compute both.
- **The usual query misleads in both directions.** It overstated dead rows threefold in s6 (199,996
  against 66,667) and understated them in s4 on 14 (83,296 against 100,000, after autovacuum
  re-estimated). The s6 gap is consistent with in-page pruning removing earlier row versions as later
  updates arrived, which I did not isolate. A finding built on `n_dead_tup` alone needs the `measured` versus
  `estimated` marking the top-level README already proposes.
- **A recent `last_autovacuum` does not mean the table was cleaned** (s1 on 14). It ran during the
  hold and removed nothing.
- **Two fixture bugs of my own, both fixed.** The first `ANALYZE` ran in the same session as the
  insert, whose statistics flushed afterwards, so the usual query reported 200,000 live rows in a
  100,000-row table. And s7's first draft changed a reloption while its own holder had the table
  locked, so it blocked on itself.
