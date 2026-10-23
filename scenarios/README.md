# Scenario fixtures

One script per cause of bloat. Each builds real dead rows, leaves them in place together with whatever
is causing them, and prints three things side by side: what the usual hand-written query reports,
what `pgstattuple` measures, and the evidence for the cause. They exist so that the extension, when it
is written, has something to be right about, and so that every claim in the top-level README can be
checked against a run rather than taken on trust.

That last part is kept in [`evidence/`](evidence/): every figure below, and every figure in the
top-level README, is a link to the masked capture that contains it, and `check-evidence.sh` fails if a
linked figure is not in its file. See [Evidence](#evidence) for how the files are made and regenerated.

No extension SQL exists yet. These scripts use only PostgreSQL itself and `pgstattuple`.

## Running them

```bash
export PGHOST=127.0.0.1 PGPORT=5618 PGUSER=postgres PGPASSWORD=...
./scenarios/run.sh                     # all of them, teardown between each, output in scenarios/out/
./scenarios/s1_idle_in_transaction.sh  # one, left in place for you to look at
./scenarios/teardown.sh                # remove everything any scenario left behind
```

s3 also needs a hot standby of the server, given as `BC_STANDBY_PORT`. `scenarios/standby.sh 18 5718 5719`
builds a primary on 5718 and a standby on 5719 from the matrix image (`standby.sh 18 down` removes
them), and the evidence below was made against such pairs. Without `BC_STANDBY_PORT`, s3 is skipped and
says so.

Run them on a **scratch server**. A horizon holder pins the whole cluster, not one database, and s7
burns 110,000 transaction ids. They need a superuser, `pgstattuple`, `max_prepared_transactions > 0`
for s4, `wal_level = logical` for s2, and a hot standby with `hot_standby_feedback = on` for s3. Set `BC_CONTAINER` to the server's Docker container name
and s7 also reads its log.

**Starting a throwaway server for them.** Pass the settings as `postgres -c` arguments to `docker run`,
which is how the runs below were made:

```bash
docker run -d --rm --name bc-scen-14 -p 127.0.0.1:5614:5432 -e POSTGRES_PASSWORD=test internal-tooling-pg14 \
  postgres -c wal_level=logical -c max_prepared_transactions=10 \
           -c log_autovacuum_min_duration=0 -c autovacuum_naptime=10s
```

The two obvious alternatives both fail with these images: `ALTER SYSTEM` followed by `pg_ctl
restart`, and editing `postgresql.conf` then signalling the postmaster. The image's entrypoint exits
when the server stops, so the container goes with it and the change never takes effect.

## What each one proves

| Scenario | Builds | What it shows | Runs on |
|---|---|---|---|
| `s1_idle_in_transaction` | 100,000 rows updated while a session sits idle in transaction holding an xid | VACUUM removes **[0](evidence/s1_idle_in_transaction.pg18.txt)** of the [100,000](evidence/s1_idle_in_transaction.pg18.txt) dead rows ([100000](evidence/s1_idle_in_transaction.pg14.txt) on 14); the holder is named with its xid age | 14, 18 |
| `s2_logical_slot` | an inactive logical slot, 100,000 dead rows in a user table, 300 temporary-table cycles | **A logical slot does not hold back a user table.** VACUUM removed all [100,000](evidence/s2_logical_slot.pg18.txt) dead rows of `s2_orders` ([100000](evidence/s2_logical_slot.pg14.txt) on 14) and could not remove [6,000](evidence/s2_logical_slot.pg18.txt) in `pg_attribute` ([6000](evidence/s2_logical_slot.pg14.txt) on 14). The slot has `xmin` NULL and only `catalog_xmin` set | 14, 18 (needs `wal_level = logical`) |
| `s3_standby_feedback` | a primary and a hot standby with `hot_standby_feedback = on` and a physical slot, a REPEATABLE READ query left open **on the standby**, then 100,000 rows updated on the primary | VACUUM on the primary removes [0](evidence/s3_standby_feedback.pg18.txt) of [100,000](evidence/s3_standby_feedback.pg18.txt) ([100000](evidence/s3_standby_feedback.pg14.txt) on 14). The primary sees the standby's horizon **only on the slot's `xmin`**; the walsender's `backend_xmin` is NULL. Ending the standby's query and nothing else, the same VACUUM then removes all [100000](evidence/s3_standby_feedback.pg18.txt) | 14, 18 (needs a standby: `standby.sh`) |
| `s4_prepared_transaction` | 100,000 rows updated after a prepared transaction took an xid | VACUUM removes [0](evidence/s4_prepared_transaction.pg18.txt) of [100,000](evidence/s4_prepared_transaction.pg18.txt); the gid, its xid age and owner are named | 14, 18 |
| `s5_autovacuum_disabled` | two identical tables, half of each updated, one with `autovacuum_enabled = false` | The control was autovacuumed to [0](evidence/s5_autovacuum_disabled.pg18.txt) dead; the disabled one kept [50,000](evidence/s5_autovacuum_disabled.pg18.txt), against a trigger threshold of [20,050](evidence/s5_autovacuum_disabled.pg18.txt) | 14, 18 |
| `s6_thresholds_too_high` | per-table thresholds of 5,000,000 plus 0.5 per row, three rounds of updates | No autovacuum ran (`autovacuum_count` [0](evidence/s6_thresholds_too_high.pg18.txt)). The usual query said **[199,996](evidence/s6_thresholds_too_high.pg18.txt)** dead rows ([66.7](evidence/s6_thresholds_too_high.pg18.txt)%); `pgstattuple` measured **[66,667](evidence/s6_thresholds_too_high.pg18.txt)** ([20.8](evidence/s6_thresholds_too_high.pg18.txt)%) | 14, 18 |
| `s7_autovacuum_vs_lock` | an open `LOCK TABLE ... SHARE UPDATE EXCLUSIVE` with no xid, then 110,000 burned xids | Part 1: an ordinary autovacuum **does not wait**. No worker in `pg_stat_activity`, and at least [3](evidence/s7_autovacuum_vs_lock.pg18.txt) `skipping vacuum ... lock not available` log lines in 40 s (4 or 5, depending on where the wait falls against the naptime). Part 2: past an `age(relfrozenxid)` of [110,000](evidence/s7_autovacuum_vs_lock.pg18.txt) an anti-wraparound autovacuum **does** wait, with `wait_event_type = Lock` | 14, 18 |
| `s8_non_hot_updates` | four 20,000-row tables, every row updated once | See the table below. `n_tup_newpage_upd` cannot tell an indexed-column update from a full page | 14 (without newpage), 18 |
| `s9_two_causes` | `autovacuum_enabled = false` and a horizon holder on one table | Manual VACUUM removes [0](evidence/s9_two_causes.pg18.txt) of [100,000](evidence/s9_two_causes.pg18.txt), so the holder ranks first; the disabled autovacuum only matters once it is gone | 14, 18 |
| `s10_never_vacuumed_holder_before` | a never-vacuumed table (autovacuum off), a session idle in transaction opened **before** 100,000 updates | Part 1: "never vacuumed", session present, [100,000](evidence/s10_never_vacuumed_holder_before.pg18.txt) dead rows measured, so the finding says "cause not established". Part 2, VACUUM (VERBOSE) as the finding instructs: [0](evidence/s10_never_vacuumed_holder_before.pg18.txt) removed, [100,000](evidence/s10_never_vacuumed_holder_before.pg18.txt) not yet removable: the session binds | 14, 18 |
| `s11_never_vacuumed_holder_after` | the same, with the session opened **after** the updates | Part 1 identical to s10, which is why the rule gives no verdict. Part 2: all [100,000](evidence/s11_never_vacuumed_holder_after.pg18.txt) removed: the session does not bind | 14, 18 |
| `s16_holder_after_vacuum` | a table with a prior vacuum, new dead rows, then a holder opened after them | the holder is **not** primary: the earlier vacuum cannot establish that it binds, so the holder is in unknowns and the next cause down is primary. Part 2: VACUUM removes all [100,000](evidence/s16_holder_after_vacuum.pg18.txt), proving it did not bind | 14, 18 |

Every run above was on PostgreSQL 14.24 and 18.6, on a primary/standby pair per version built by
`standby.sh` from the pg_lock_tree matrix images (`internal-tooling-pg14`, `internal-tooling-pg18`). The
primary runs with `wal_level = logical`, `max_prepared_transactions = 10`, `log_autovacuum_min_duration
= 0` and **`autovacuum_naptime = 10s`**; the standby with `hot_standby_feedback = on`. The short naptime makes the waits in s5 to s7 forty seconds instead of four minutes; nothing
else depends on it. The two versions agreed on every count above.

### s8: what the counters can and cannot say

| table | why it is not HOT | `n_tup_upd` | `n_tup_hot_upd` | `n_tup_newpage_upd` (18) |
|---|---|---|---|---|
| `s8_plain_room` | it is HOT (fillfactor 50, unindexed column) | [20,000](evidence/s8_non_hot_updates.pg18.txt) | [20,000](evidence/s8_non_hot_updates.pg18.txt) | [0](evidence/s8_non_hot_updates.pg18.txt) |
| `s8_plain_full` | no room on the page (fillfactor 100) | [20,000](evidence/s8_non_hot_updates.pg18.txt) | [0](evidence/s8_non_hot_updates.pg18.txt) | [20,000](evidence/s8_non_hot_updates.pg18.txt) |
| `s8_indexed_room` | indexed column changed (fillfactor 70) | [20,000](evidence/s8_non_hot_updates.pg18.txt) | [0](evidence/s8_non_hot_updates.pg18.txt) | [11,000](evidence/s8_non_hot_updates.pg18.txt) |
| `s8_indexed_full` | indexed column changed (fillfactor 100) | [20,000](evidence/s8_non_hot_updates.pg18.txt) | [0](evidence/s8_non_hot_updates.pg18.txt) | [20,000](evidence/s8_non_hot_updates.pg18.txt) |

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
- **The usual query can mislead badly.** It overstated dead rows threefold in s6
  ([199,996](evidence/s6_thresholds_too_high.pg18.txt) against [66,667](evidence/s6_thresholds_too_high.pg18.txt)). The gap is consistent with in-page pruning removing earlier row
  versions as later updates arrived, which I did not isolate. In one early run on 14 it also
  understated them in s4, after an autovacuum re-estimated mid-scenario; that depended on timing, did
  not reproduce in the two runs the evidence comes from, and is not cited as evidence. A finding built on `n_dead_tup` alone needs the `measured` versus
  `estimated` marking the top-level README already proposes.
- **A recent `last_autovacuum` does not mean the table was cleaned.** In one early run on 14 an
  autovacuum ran on s1 during the hold and removed nothing. That is timing, did not recur in the two
  evidence runs, and is recorded as an observation, not evidence. The mechanism it illustrates is the
  one s1 does evidence: while the holder exists, no VACUUM removes anything.
- **A standby's horizon is on its slot, not its walsender** (s3). With a physical slot, the
  walsender's `backend_xmin` is NULL and the slot's `xmin` carries the standby's horizon. A finding
  that looks only at `pg_stat_replication` would miss it entirely. And the primary never sees the
  standby's query: the fix has to be named as being on the standby.
- **A healthy standby still delays cleanup by up to its feedback interval.** Not a cause worth a
  finding on its own, but it means "dead rows just made, not yet removable" is normal for about ten
  seconds on a primary with a feedback standby, and a finding must not fire on that.
- **Two fixture bugs of my own, both fixed.** The first `ANALYZE` ran in the same session as the
  insert, whose statistics flushed afterwards, so the usual query reported 200,000 live rows in a
  100,000-row table. And s7's first draft changed a reloption while its own holder had the table
  locked, so it blocked on itself.

## Evidence

`run.sh` writes each scenario twice: the raw output to `out/`, which is ignored, and a masked copy to
`evidence/<scenario>.pg<major>.txt`, which is committed. `mask.sh` replaces only values that change
between runs: pids (`<PID>`), timestamps (`<TIMESTAMP>`), intervals (`<AGE>`), transaction ids
(`<XID>`) and their ages (`<XIDAGE>`), and `pg_attribute`'s own row and page counts (`<N>`), which
depend on the cluster's history rather than the fixture. The token names are pg_lock_tree's; its
expressions are not reused, because its broadest rules would mask the row counts this evidence exists
to show. Every row count, dead-row count, percentage and threshold is left as it ran.

**Reproducible, checked.** The committed files came from a run on PostgreSQL 14.24 and 18.6, and a
second consecutive run on each produced byte-identical masked files: for s1 to s9's 18 files in one
double run, and for s10 and s11's 4 files in a later one, on the same kind of primary/standby pair. Every fix that took
was to a fixture, not to the mask:

- autovacuum reaching a table during a hold made `last_autovacuum` differ (s1, s2), so the tables
  whose evidence is a manual VACUUM (s1 to s4, s9) run with autovacuum disabled;
- s7's raw `age(relfrozenxid)` moved by one xid, so it prints the fact that matters (over 110,000);
- `pg_attribute`'s dead-row count moved with unrelated catalog activity (6,000 and 6,021), so s2
  reports only the rows its own churn added;
- **a standby's feedback lags.** With `hot_standby_feedback` on, the standby reports its horizon every
  `wal_receiver_status_interval` (10 s by default), and until then the primary holds an older xmin on
  its slot. That made s2's user table briefly unvacuumable in one run, and changed how much s6's
  in-page pruning removed. `settle_stats` now waits until every active physical slot has caught up
  with the primary's own oldest horizon, and s6 waits between its update rounds. s3 pins the slot
  deliberately and skips the wait.

To regenerate and to check:

```bash
./scenarios/run.sh                                   # rewrites evidence/ for this server's major version
EVIDENCE_DIR=/tmp/ev2 ./scenarios/run.sh             # a second run somewhere else
diff -r scenarios/evidence /tmp/ev2                  # expect nothing
./scenarios/check-evidence.sh                        # every linked figure is in its file
```

