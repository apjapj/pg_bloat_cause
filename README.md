# pg_bloat_cause

[![CI](https://github.com/apjapj/pg_bloat_cause/actions/workflows/ci.yml/badge.svg)](https://github.com/apjapj/pg_bloat_cause/actions/workflows/ci.yml)
[![Licence: PostgreSQL](https://img.shields.io/badge/licence-PostgreSQL-blue.svg)](LICENSE)

**What's slowing down.** Bloat is a symptom; this tool names the cause.

Part of [pg_incident_watch](https://github.com/apjapj/pg_incident_watch). Pure SQL, `CREATE EXTENSION pg_bloat_cause`, no
restart, no `shared_preload_libraries`. Status: **0.5.0**, built and tested on
PostgreSQL 14 and 18. Install and grants: [INSTALL.md](INSTALL.md). What changed in each
release: [CHANGELOG.md](CHANGELOG.md). Changing it or releasing it:
[CONTRIBUTING.md](CONTRIBUTING.md).

## The incident, end to end

This tool answers one question; the family covers the rest, and the three install independently.
They share the alert contract and the reference listener in
[pg_incident_watch](https://github.com/apjapj/pg_incident_watch).

| Tool | Question it answers |
|---|---|
| [pg_lock_tree](https://github.com/apjapj/pg_lock_tree) | what is stuck now |
| [pg_bloat_cause](https://github.com/apjapj/pg_bloat_cause) | what is slowing down |
| [pg_limit_runway](https://github.com/apjapj/pg_limit_runway) | what will break next |

The umbrella also tests all three in one database, so installing more than one is a supported
combination rather than an accident.

## Overview

Bloat tools report how big a table is and how much of it is dead. That is the symptom, and it leaves
the operator to work out why VACUUM is not keeping up. pg_bloat_cause answers the why, per table,
ranked worst first, in one sentence (an illustration of the format, not a measurement):

```
orders: 40% dead rows, held back by session 4127 (idle in transaction) for 3 days
```

An earlier version of this example blamed a logical replication slot. That was wrong, and
`scenarios/s2_logical_slot.sh` shows it: a logical slot holds back catalog rows (`catalog_xmin`), not
an ordinary table's. With an inactive slot in place, VACUUM removed all
[100,000](scenarios/evidence/s2_logical_slot.pg18.txt) dead rows of the user table and could not remove
[6,000](scenarios/evidence/s2_logical_slot.pg18.txt) in `pg_attribute`. The same run on 14:
[100000](scenarios/evidence/s2_logical_slot.pg14.txt) and [6000](scenarios/evidence/s2_logical_slot.pg14.txt).

### The causes it ranks

| Cause | What it means | Where the evidence is |
|---|---|---|
| **Something holding back VACUUM** | The xmin horizon is pinned, so dead rows cannot be removed however often VACUUM runs | `pg_stat_activity.backend_xmin` / `backend_xid` (long transaction), `pg_replication_slots.xmin` (a standby with `hot_standby_feedback` and a physical slot: measured in s3, its horizon shows HERE and `pg_stat_replication.backend_xmin` is NULL; a logical slot's `catalog_xmin` holds back catalog tables only), `pg_stat_replication.backend_xmin` (a standby with feedback and no slot; PostgreSQL's documented behaviour, not measured here: s3 uses a slot), `pg_prepared_xacts` (orphaned prepared transaction) |
| **Autovacuum falling behind or off** | VACUUM could clean up but is not running often enough, or at all, for this table | `pg_stat_user_tables` (`n_dead_tup`, `last_autovacuum`, `last_vacuum`, `n_ins_since_vacuum`), `reloptions` (`autovacuum_enabled=false`, per-table thresholds), BOTH computed trigger thresholds (dead-row and, since 13, insert-based: either one firing cleans the table) |
| **Autovacuum kept off the table by a lock** | An ordinary autovacuum does **not** wait for a lock: it skips the table and tries again next naptime, so nothing shows in `pg_stat_activity`. Only an anti-wraparound autovacuum waits, visibly | For the ordinary case: a stale `last_autovacuum` with dead rows over the threshold, and a session holding a conflicting lock in `pg_locks` (the server log says `skipping vacuum ... lock not available` when `log_autovacuum_min_duration >= 0`). For the anti-wraparound case: `backend_type = 'autovacuum worker'` with `wait_event_type = 'Lock'`. The holder is named from `pg_locks` joined to `pg_stat_activity`, with no dependency on `pg_lock_tree` |
| **Updates that cannot stay on the page** | Non-HOT updates, because an indexed column changes or the page has no room (`fillfactor`) | `n_tup_upd` vs `n_tup_hot_upd`; on PG 16+ `n_tup_newpage_upd` counts updates that moved to a new page, which is evidence for "no room" (see the scenarios for how cleanly); on 14 and 15 the finding says it cannot tell the two apart |

### What a finding looks like

Every finding carries the same parts, which is what makes it a family member:

- **Diagnose**: table, dead-row share and size, the cause, how long the cause has been in place, and
  a one-line sentence like the one above.
- **Act**: the least destructive statement that removes the cause, never the symptom. Cancel or
  terminate the long transaction; `pg_drop_replication_slot()` for an abandoned slot, but only
  as a command to read, never as a default; `ROLLBACK PREPARED` for an orphan; an `ALTER TABLE ... SET
  (autovacuum_...)` or `fillfactor` change. `VACUUM` itself is offered only after the cause is gone,
  because before then it removes nothing.
- **Detect**: `NOTIFY` on the `bloat_cause` channel, once at onset, again when materially worse, once
  when cleared, in the shared payload format.
- **Review**: sampled history of horizon holders and per-table dead-row counts, so "the table doubled
  last week" can be traced to the slot that was there at the time.

### Measuring bloat

Exact measurement uses `pgstattuple` when it is installed; otherwise an estimate from `pg_class`
and `pg_stats`. `pgstattuple()` reads the whole table, so it must never run implicitly across a
database. `pgstattuple_approx()` reads only the pages the visibility map does not cover and is the
better default when exact is asked for on a large table.

## Next steps

In order. Steps 1 to 3 settle what the tool says; 4 onwards build it.

### 1. Wait for, or write, the shared contract

Payload keys, `event` vocabulary, channel naming, version floor and naming conventions are decided
once in [pg_incident_watch](https://github.com/apjapj/pg_incident_watch#next-steps). Do not invent local
versions. The floor is **PostgreSQL 14 and later**. PostgreSQL 14 reaches upstream end of life on 2026-11-12, and the floor is revisited then. Features newer
than 14 are per-feature checks with a stated degradation, never a floor: on 14 and 15 there is no
`n_tup_newpage_upd`, so the HOT-update finding reports what it cannot tell apart instead of guessing.

### 2. Build the scenario fixtures first

As pg_lock_tree did with `scenarios/`: one script per cause that builds real bloat and leaves it
there, so every later step has something to be right about. At least:

1. long `idle in transaction` session holding the horizon
2. inactive logical replication slot
3. physical standby with `hot_standby_feedback = on` and a long query on the standby
4. orphaned prepared transaction (needs `max_prepared_transactions > 0`, skip where absent)
5. `autovacuum_enabled = false` on one table
6. autovacuum thresholds too high for a hot table (both the dead-row and the insert threshold)
7. autovacuum kept off a table by a lock held by an open `LOCK TABLE`: skipped when ordinary,
   waiting when anti-wraparound
8. non-HOT updates from an indexed column, and separately from `fillfactor = 100` on a wide row
9. two causes at once, to pin down ranking

Each scenario should also print what the usual hand-written query reports, so the README can show
the difference rather than claim it.

**Done, in [`scenarios/`](scenarios/README.md).** All nine run on PostgreSQL 14 and 18, plus s10 and
s11 for the never-vacuumed case in [docs/ranking.md](docs/ranking.md); s3 needs a
primary/standby pair, which `scenarios/standby.sh` builds. Four of them corrected this document: the
logical-slot example above, the lock row in the causes table, the threshold row, and where a
standby's horizon shows (on its slot, not its walsender).

### 3. ~~Define the ranking~~ **Done: [docs/ranking.md](docs/ranking.md)**

Settled before any SQL. Per table, the primary finding is the most upstream cause present, and every
other cause is a secondary line under it; s9 is the worked case. One part is still open there: when a
horizon holder exists but is not the reason a table's rows stay.

What follows is the proposal it started from. The overview promises "ranks why dead rows aren't being cleaned up". Write down the rule before the
code. Proposed: a horizon holder outranks everything, because nothing else is fixable while it is
there; then a lock wait; then autovacuum off or behind; then HOT efficiency, which is a tuning
finding rather than an incident. Within a cause, rank by dead bytes, not dead-row share, so a small
table at 90% does not outrank a large one at 40%.

### 4. ~~The first version: diagnose only~~ **Done: 0.1, tagged `v0.1.0`, [INSTALL.md](INSTALL.md)**

`pg_bloat_cause--0.1.sql`: the view `bloat_cause`, `bloat_cause_findings()` behind it, and
`bloat_cause_text()`. Every scenario asserts the finding this view gives for its table, on PostgreSQL 14
and 18, and all pass; [docs/design.md](docs/design.md) records the decisions and what the scenarios
and the grant test changed. [INSTALL.md](INSTALL.md) has the grants.

The original plan for it: `bloat_cause` (view, one row per table with a cause) and `bloat_cause_text()` (the sentence form).
No history, no alerting. This is the part that has to be right, and it is useful mid-incident on its
own.

Specific things to get right:

- **Attributing a horizon to a table.** A pinned horizon affects every table, so the finding has to
  say "this is why `orders` cannot be cleaned" and name the one holder, not list every table.
  Catalog-only horizons (`catalog_xmin` of a logical slot) affect catalog tables, not user tables;
  report them separately.
- **Age of the cause**, from `xact_start`, slot state, or `pg_prepared_xacts.prepared`, because
  "for 3 days" is the half of the sentence that drives action.
- **Standbys.** A primary cannot see what a standby's long query is. With a physical slot it sees the
  standby's horizon on the slot's `xmin`, not on `pg_stat_replication.backend_xmin`, which is NULL
  ([s3](scenarios/evidence/s3_standby_feedback.pg18.txt)). Say "held back by standby
  `<application_name>`", and say the fix is on the standby.
- **Not a cause**: a table that is bloated from one past event and is now being vacuumed normally.
  Dead space that VACUUM has already reclaimed into the free space map is not "dead rows". Do not
  raise it.
- **Lock chains**: if `pg_lock_tree` is installed, find its schema via `pg_extension` and call it;
  if not, report the direct blocker pids from `pg_blocking_pids()`. Test both.
- **Waits that are not locks**: an autovacuum worker waiting on a buffer pin (`BufferPin`) is not in
  the lock graph; say so rather than reporting nothing.

### 5. ~~Act: `bloat_cause_command()`~~ **Done: 0.2**

One statement per cause, returned and never run, as `lock_tree_command()` does. Destructive steps
(dropping a slot, terminating a session) must say what they lose in the same row, since dropping a
logical slot loses that consumer's position.

Shipped as `bloat_cause_command()`: one row per table, the primary cause only, with `loses` beside
the statement. `pg_cancel_backend()` rather than `pg_terminate_backend()`, `ROLLBACK PREPARED` for a
prepared transaction, no row at all for a standby holder. See [docs/ranking.md](docs/ranking.md) rule 3.

### 6. ~~Review and detect~~ **Done: 0.4.0, [docs/detect.md](docs/detect.md)**

`bloat_cause_sample()`, `bloat_cause_history`, `bloat_cause_prune()`, `bloat_cause_notify()`,
`bloat_cause_notify_resolved()` and `bloat_cause_alert`, following the shared contract. It reuses
pg_lock_tree's lessons from its own docs: compare escalation against the last notification rather
than the last sample, keep samples as separate statements, and never store query text that would
have to be redacted on every sample. The contract is settled in
[docs/detect.md](docs/detect.md), written before the SQL the way `docs/measure.md` was. 0.5.0 adds
the opt-in that does store it, `bloat_cause.holder_query`, with its redaction and truncation in
[docs/holder-query.md](docs/holder-query.md); the column is NULL in 0.4.x and until a session turns
the setting on.

### 7. Docs, grants and the matrix

`INSTALL.md` with the exact grants (`pg_read_all_stats` plus `SELECT` on the views, and what
`pgstattuple` additionally needs: it is granted to `pg_stat_scan_tables`), a reference page, and the
shared PG matrix. Tests run with and without pgstattuple and pg_lock_tree.

Done: [INSTALL.md](INSTALL.md), [docs/reference.md](docs/reference.md), and the PG matrix, which **runs
14 to 18** on every push. 19 is deliberately not in it: its image needs the `include` form and a separate
apt major, as pg_lock_tree's workflow does it. That is an open item rather than a done one.

The with-and-without-`pgstattuple` matrix leg was the gap here, and step 6 closed it: `ci/job.sh`
removes `pgstattuple` from both servers after the first scenario pass and runs the scenarios again,
so the estimate path is exercised on a cluster that never had it. The sampler never measures and
never needs it.

The `pg_lock_tree` interaction was written up here as a real gap, and checking it showed the gap is
not coverage at all. This extension never references `pg_lock_tree`: no `pg_extension` lookup, no
call into it. The lock holder is named from `pg_locks` joined to `pg_stat_activity`, so it works
whether or not `pg_lock_tree` is installed, and there is no branch that could differ. What was
actually wrong was three prose claims saying otherwise, corrected in 0.2. Deeper integration, naming
a whole lock chain through `pg_lock_tree`, remains on the roadmap below.

### Known flakes

**2026-10-19, PG 14: one of two concurrent CI runs of the same commit failed `test/02_history.sql`
and `test/03_detect.sql`; the other run and the rerun passed.** In `test/02`, the sample after a
fixture update returned no row, so `sum(sampled)` was NULL, `\gset` left `:sampled` unset, and the next
statement failed as a psql syntax error instead of an assertion. `test/03` counted two notifications
where the test expected one.

Both files wait for statistics with fixed `pg_sleep(1.5)` calls. A loaded runner can take longer, and
the fixture is then read before its dead rows are visible. The fix is to poll for the expected
condition (`n_dead_tup` or `dead_bytes`) with a timeout rather than raise the sleep, and to coalesce
the aggregate so a missing row fails as an assertion. The container names and ports are also fixed per
major (`bc-pri-14`, 5714), which is safe on GitHub-hosted runners but would collide if two jobs ever
shared a Docker host. Until the waits are deterministic, rerun a lone PG 14 failure in these files
before treating it as a defect.

## Open questions

- Index bloat is not in the overview. B-tree bloat has different causes (deletion patterns, no
  deduplication on older indexes) and a different fix (`REINDEX CONCURRENTLY`). In scope later, or a
  separate concern?
- TOAST tables bloat independently and are vacuumed with their parent. Report them as their own rows,
  or folded into the parent?
- `n_dead_tup` is an estimate that resets on a stats reset and after crash recovery, on every
  version (PG 15 moved the statistics into shared memory but still discards them on recovery). How much of
  the "40%" can rest on it when pgstattuple is absent?
- Should the estimate path be visibly marked (`measured` vs `estimated`) in every row? Recommended
  yes, so nobody acts on an estimate thinking it is a measurement.
