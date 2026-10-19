# changelog

Versions are listed newest first. Released tags are never edited: a change that needs
a new entry gets a new version.

## 0.4.1 (2026-10-19)

A patch release with no SQL change, fixing the update path from 0.3 and earlier.

The 0.3 to 0.3.1 script used `CREATE FUNCTION` for `bloat_cause_measure`, although its own comment
says "CREATE OR REPLACE, not DROP" and the signature is unchanged. A database at 0.3, or at 0.1 or
0.2 which reach 0.3.1 through it, therefore failed with "function bloat_cause_measure already
exists with same argument types" and could not update. The script is corrected to `CREATE OR
REPLACE`; the `v0.3.1` tag is unchanged, and this release ships the corrected script.

Nothing else changes: 0.4.1's SQL is 0.4.0's, and the 0.4.0 to 0.4.1 update is a version bump.

## 0.4.0 (2026-10-18)

Step 6: the sampler, the history, the pruner and the two senders of the shared `pg_incident_watch`
alert contract, settled in [docs/detect.md](docs/detect.md) before the SQL.

- `bloat_cause_history` is the sampled series: one row per table per sample with the estimated dead
  figures, the source label, the `stats_reset` marker, and the horizon holder's context. It is
  registered with `pg_extension_config_dump`, because the series is the user's data and is what makes
  a trend readable after the fact.
- `bloat_cause_sample(pct, bytes, at)` appends one sample of every table worth a row: at or above
  both floors, or already in the series so a series that starts does not silently stop. It reads
  `bloat_cause_findings()` and never measures, so `pgstattuple` stays optional and is never touched.
  Every figure it records is `dead_rows_source = 'estimated'`; a sample taken across a
  `pg_stat_reset()` or crash recovery writes a marker row with `stats_reset = true` and NULL figures,
  which re-baselines the series, and is counted in `not_established`, so a reset cannot read as a
  table that cleared, `'unknown'` is not a value the column takes, and the table is not left
  unsampled until the pre-reset row is pruned. A role granted the sampler samples only the tables it
  can read, because PostgreSQL's statistics views are not filtered by privilege the way
  `pg_stat_activity` is.
- `bloat_cause_prune(older_than)` drops samples older than an age, default 35 days.
- `bloat_cause_notify(channel, pct, bytes, age)` raises one `NOTIFY` per onset and per escalation on
  the `bloat_cause` channel. A table is notable when it is BOTH at least `min_dead_pct` dead AND at
  least `min_dead_bytes` of dead space; the first rung IS `min_dead_bytes` (100 MB by default) and
  each rung above is ten times the one below with **no fixed top**. The rung is compared against the
  highest already notified, never against the previous sample, so a table that sits still notifies
  once. `bloat_cause_alert` is that high-water state, one row per subject per channel. A statistics
  reset does not suppress an alert: a table over the threshold after a reset still alerts, and a
  higher rung after a reset still escalates.
- `bloat_cause_notify_resolved(...)` raises one `cleared` `NOTIFY` when a watched table is below the
  alert threshold and clears its state. A table that has left `bloat_cause_findings()` is not
  watched and is not cleared, and a subject whose most recent sample is a `stats_reset` marker or is
  older than the current statistics reset time is unknown and is not cleared either.
- The payloads carry the five required keys of the shared contract (`tool`, `subject`, `sampled_at`,
  `event`, `channel`) plus `level` and `previous_level`, with the same shape `pg_lock_tree` 1.2.0
  ships. `subject` is the schema-qualified relation name, `format('%I.%I', schemaname, relname)`.
  `level` is the notification count read after the increment (1 at onset, the prior count plus one at
  each escalation); `previous_level` is that minus one, null at onset; `cleared` carries the last
  level with `previous_level` absent.
- `holder_query` is always NULL in 0.4.0. Storing query text needs an explicit opt-in, this release
  ships none, and these extensions have no configuration of their own, so no GUC was invented.
- Nothing existing changes: `bloat_cause_findings()`, `bloat_cause_text()`, `bloat_cause_holder()`,
  `bloat_cause_command()` and `bloat_cause_measure()` keep their shapes and their output.
- New tests: `test/02_history.sql` for the sampler, the history and the pruner; `test/03_detect.sql`
  for the ladder, the payload shape and the cleared payload.

## 0.3.1 (2026-10-15)

**0.3.0's `bloat_cause_measure()` never worked.** It built the heap read with `format('%L', oid)`,
which quotes the oid, so `pgstattuple` received the string `'19223'` and looked up a relation
named `19223`:

    ERROR: relation "19223" does not exist

The cast is now `%s::regclass`, which is the oid itself and means no name lookup happens at all.
That is also the safer form, because resolving a name is the step that checks the caller's
privileges, and that class of defect has been found twice already in this family.

- A scenario now asserts the **figure**, not only the label: `dead_rows > 0` and both modes
  agreeing within 5 percent on an idle table, and landing within a factor of two of the estimate
  the findings report for the same table. The 0.3.0 pgTAP assertions asserted
  `dead_rows_source = 'measured'`, which the broken function satisfied.

## 0.3 (2026-10-15)

The explicit measurement, for one table, when a caller asks for it.

- `bloat_cause_measure(schema, table, mode)` reads the heap through `pgstattuple` and returns
  measured dead rows, live rows, bytes and percentage with `dead_rows_source = 'measured'`, so
  the row can be put beside the estimate for the same table.
- `mode` is `approx` (default, `pgstattuple_approx()`, reading only the pages the visibility map
  does not cover) or `exact` (`pgstattuple()`, the whole table). The choice is the caller's,
  because `pgstattuple()` reads everything and that must never happen implicitly.
- The function is always present and raises when `pgstattuple` is not installed, naming the
  extension and the statement that installs it, rather than being absent and leaving the caller
  with "function does not exist" and no next step.
- Nothing existing changes: the view, the sentences, the holders and the command all stay on the
  estimate. The exact read happens only where a caller asks for it, which is the contract in
  README's "Measuring bloat" and [docs/measure.md](docs/measure.md).

## 0.2 (2026-10-14)

**Correction to 0.1, which is not edited because a released entry is not rewritten.** The 0.1
entry below says "Where `pg_lock_tree` is installed, a cause that is a lock names the holder".
That is wrong about the dependency. This extension never references `pg_lock_tree`: no
`pg_extension` lookup, no call into it, no branch that reads it. A cause that is a lock names
the holder from `pg_locks` joined to `pg_stat_activity`, so it does so whether or not
`pg_lock_tree` is installed. The sentence read as though the holder were named only when
`pg_lock_tree` is present, and the effect is the opposite: nothing needs it for this.


The holder, in structured form. No existing output changes: every sentence and every
evidence file is byte-identical to 0.1, and the scenario suite fails if one moves.

- `bloat_cause_holder(age, gap)` returns every horizon holder as a row: `kind`, `pid`,
  `gid`, `slot_name`, `application_name`, `state`, `who`, `since`, `xid_age`. It exists
  for `bloat_cause_command()`, which has to emit a statement naming a pid or a gid. In
  0.1 the holder was named only in `cause_detail`, which is prose, and a caller cannot
  get a pid out of an English sentence without parsing it.
- A logical replication slot is deliberately absent: it holds `catalog_xmin`, which
  protects catalog rows rather than user tables, and `s2` asserts that.
- `bloat_cause_findings()` now reads `bloat_cause_holder()` instead of keeping its own
  copy of the holder logic, so the holder is defined once and used everywhere. No
  sentence and no evidence file changes: the three columns the sentences use are
  selected from the shared function, and the scenario suite fails if one moves.
- `bloat_cause_holder()` is executable by `PUBLIC`, which is a change of mind from
  the first draft of this release. `bloat_cause_findings()` is SECURITY INVOKER, so
  revoking the holder from `PUBLIC` would break the two-line grant in
  [INSTALL.md](INSTALL.md) for any role following it. `EXECUTE` is not visibility: a
  role without `pg_read_all_stats` still cannot read the sessions the holder reports.
- `bloat_cause_command(age, gap)` returns one statement per table for the primary
  cause only, returned and never run, with what running it loses in the same row. A
  session holder is cancelled with `pg_cancel_backend()` rather than terminated; a
  prepared transaction takes `ROLLBACK PREPARED`. `pg_terminate_backend()` is never
  offered, and a standby holder produces no row at all because the query is on the
  other host.
- Three autovacuum causes return a read-back rather than an action, because
  `ALTER TABLE ... RESET (autovacuum_enabled)` would read as the fix and would not
  help when the threshold is simply never reached. Only `autovacuum behind` acts,
  with `VACUUM (VERBOSE)`.
- Graded the way the other two functions are: not executable by `PUBLIC`.

## 0.1 (2026-10-12)

The first release. Current state only: it reads the live catalogs, keeps no history,
and projects no dates.

- One row per bloated table, ordered by reclaimable space held, each carrying the
  evidence that names the blocker and the statement that clears it.
- Four cause families: something holding back VACUUM, autovacuum falling behind or off,
  autovacuum kept off the table by a lock, and updates that cannot stay on the page.
- `bloat_cause_findings()` and `bloat_cause_text()` read on the caller's rights and
  never wait: a table that cannot be locked in time is reported "not established"
  rather than stalling the caller.
- Closed by default. Every object is revoked from `PUBLIC`, and what a monitoring role
  loses without each grant is listed in [INSTALL.md](INSTALL.md).
- Where `pg_lock_tree` is installed, a cause that is a lock names the holder.
- PostgreSQL 14 and later, pure SQL, no `shared_preload_libraries` and no restart.

Later versions: none. The design questions and the evidence for the ranking rule are in
[docs/design.md](docs/design.md) and [docs/ranking.md](docs/ranking.md); the measured
figures behind them are in [scenarios/README.md](scenarios/README.md).