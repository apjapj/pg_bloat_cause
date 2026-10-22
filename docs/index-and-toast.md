# Index bloat and TOAST: the two scope decisions

Two questions in the README's open list are decisions about what this extension is for, not
measurements. This note records both, so a later change starts from a decision rather than reopening
the same argument.

## Index bloat: out of scope here, a separate concern if pursued

**Decision: `pg_bloat_cause` does not report index bloat.** It remains a tool for one question: why
dead heap rows are not being removed, and what to do about it.

The reasons are not just scope:

- **Different cause.** Heap bloat from dead rows is about vacuum: the horizon, autovacuum settings,
  locks, standby feedback. B-tree bloat is about page splits, deletion patterns, deduplication (which
  older releases do not have) and updates that cannot stay on the page. A table can have a clean heap
  and a bloated index, or the reverse.
- **Different fix.** The action is `REINDEX CONCURRENTLY`, not `VACUUM`. It rewrites one index at a
  time, needs its own lock and disk budget, and can fail and leave an invalid index behind. Putting it
  in the same row as a vacuum finding would make the primary cause and the command disagree.
- **Different measurement.** `pgstattuple` measures heap pages; index bloat needs `pgstatindex` or a
  model of the index, and the numbers are not comparable with dead-row bytes. Ranking them together
  would compare unlike quantities.
- **Different permissions and cost.** Reading every index of every table is a larger and more
  privileged scan than the heap path, and it would make the default read pay for a question most
  incidents do not ask.

If the demand is real, the right shape is a **separate tool or extension** with its own entry point,
its own `REINDEX CONCURRENTLY` action and its own tests. It is not planned here; the roadmap records
it as a separate concern rather than a later release of this one.

## TOAST: folded into the parent table, never its own row

**Decision: TOAST bloat is reported as part of the parent table's finding, not as a row for
`pg_toast.pg_toast_<oid>`.**

TOAST is the parent's storage for wide values. It is vacuumed with the parent, and the same horizon,
autovacuum and lock causes apply to it. A separate row would:

- name a system table the reader cannot act on directly;
- split one cause across two rows, so the parent could look clean while its TOAST is the problem;
- pollute ranking with a relation the operator did not create.

The shape is a **secondary line on the parent**: for example
"TOAST: ~1.2 GB, 41% dead (estimated); VACUUM the parent cleans it too". It never becomes the primary
cause: the primary cause is still the horizon, autovacuum setting or lock that lets the parent and its
TOAST accumulate dead rows.

### The estimate is real, and it is cheap

The first draft of this note said there was no cheap estimate, because `pg_stat_user_tables` does not
show TOAST rows. That was wrong: `pg_stat_all_tables` carries live and dead tuple counts for the TOAST
relation, and `pg_class` gives its size. The experiment in
[`scripts/toast-estimate.sh`](../scripts/toast-estimate.sh) measures the estimate against
`pgstattuple_approx()` on PostgreSQL 14.24 and 18.6, with 20 KB out-of-line values, update-only,
delete-only, partial-update and mixed-size fixtures:

| fixture | measured dead bytes | statistics estimate | error |
| :-- | --: | --: | --: |
| update all 200 rows | 4,079,200 | 4,370,432 | +7.1% |
| delete 100 of 200 | 2,039,600 | 2,187,264 | +7.2% |
| update 50 of 200 | 1,019,800 | 1,092,812 | +7.2% |
| mixed 5 KB/30 KB, update half, delete third | 1,688,372 | 1,843,267 | +9.2% |

The dead percentage was exact in every case; the byte estimate was 7 to 9 percent high. It is
reported as **estimated**, never measured. `pgstattuple` remains the opt-in exact read.

### Materiality

The line appears when the **estimate itself** is at least **10 percent dead and at least 100 MB**.
That is the same pair the heap notify rule uses, so TOAST and heap findings read consistently; it is
not a setting. A boundary test should sit clear of 100 MB on both sides because the estimate runs
about 9 percent high.

### TOAST autovacuum is separate

A TOAST relation has its own `toast.autovacuum_*` reloptions and its own statistics row. Setting
`autovacuum_enabled = false` on the parent does not set the TOAST reloption; setting
`toast.autovacuum_enabled = false` does. The line names that condition separately, because the
existing "autovacuum is disabled" finding reads the parent's setting and would otherwise miss it.

### Boundaries that stay

1. No row of its own for `pg_toast.pg_toast_<oid>`.
2. Never the primary cause and no new command: `VACUUM` on the parent is the action for both.
3. `not established` when the TOAST statistics are absent or unreadable, never zero.
4. No setting: the threshold is fixed.

Implemented in 0.7.0. The family page is corrected separately.
