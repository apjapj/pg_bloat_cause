# reference: the objects, their columns, and what each is for

**For:** whoever is writing a query against this extension, and whoever is deciding which
of the four entry points to call. This page is the shapes. For why the causes rank the way
they do, see [ranking.md](ranking.md); for the design decisions behind them, see
[design.md](design.md).

Everything here that reads is read-only. Through 0.3.1 nothing in this extension wrote to a cluster
and nothing waited on a lock: a table that could not be examined in time was reported as not
established rather than stalling the caller. From 0.4.0 the sampler and the two senders are the
exception, and they write only this extension's own tables (`bloat_cause_history` and
`bloat_cause_alert`), never a user table. Everything else stays read-only.

## Which entry point to call

| Call | Use it when |
| --- | --- |
| `bloat_cause` view | You want one row per bloated table, worst first, with the default arguments. This is what a dashboard reads. |
| `bloat_cause_text(age, gap)` | You want a sentence per table for a human, the same content as the view but as prose. |
| `bloat_cause_findings(age, gap)` | You want the columns the view hides, or arguments other than the defaults. The view is this with defaults. |
| `bloat_cause_holder(age, gap)` | You want the horizon holders themselves, structured, without any table's finding attached. |
| `bloat_cause_command(age, gap)` | You want the statement that clears the primary cause. Returned as text, never run. |
| `bloat_cause_context(schema, table)` | You want one table's autovacuum context: last run, counts, dead rows, reloptions and resolved thresholds. |

## `bloat_cause` (view)

`SELECT * FROM bloat_cause_findings()` with its defaults. One row per table that has dead
rows and at least one cause, ordered by dead bytes descending.

| Column | Type | Meaning |
| --- | --- | --- |
| `schemaname` | `name` | Schema of the table. |
| `relname` | `name` | Table name. |
| `relid` | `oid` | Table oid, so a caller can join to `pg_class`. |
| `dead_rows` | `bigint` | Dead rows, from the statistics. |
| `dead_pct` | `numeric` | Dead rows as a percentage of live plus dead. |
| `dead_bytes` | `bigint` | Estimated dead **heap** bytes: dead rows times the average heap row width, from the statistics. Excludes TOAST and index bytes, and is not a promise that VACUUM reclaims all of it. |
| `dead_rows_source` | `text` | `estimated` or `measured`. Every row says which, so nobody acts on an estimate believing it is a measurement. |
| `cause` | `text` | The primary cause, as [ranking.md](ranking.md) decides it. |
| `cause_detail` | `text` | One sentence naming the cause, with the holder or the lock named in it. |
| `cause_since` | `timestamptz` | When the primary cause began, where that is visible. NULL where it is not, which is the standby case. |
| `then` | `text[]` | The secondary causes, in ranking order. |
| `unknowns` | `text[]` | Causes present but not established, and always a note when the caller lacks `pg_read_all_stats`. |

## Partitioned tables

A partitioned parent has no storage and no dead tuples of its own, so it does not get a finding row.
Each leaf partition is an ordinary table and is reported separately, with its own autovacuum
settings and dead rows. `bloat_cause_context()` can describe the parent because it reads the catalog
and statistics; `bloat_cause_measure()` refuses it because there is no heap to read. Test/07 pins
this.

## `bloat_cause_findings(min_holder_age interval DEFAULT '1 minute', min_standby_xid_gap bigint DEFAULT 1000)`

The columns above, with the arguments exposed.

`min_holder_age` is how long a session or prepared transaction must have been open before it
counts as holding the horizon. A holder younger than this is ignored, because one that
started a moment ago is not what is keeping a vacuum from cleaning up.

`min_standby_xid_gap` is how far a standby's slot must trail the primary's own horizon, in
xids, before the standby counts as a cause. It exists because the primary cannot see when a
query on the standby began, so it cannot tell a query holding the horizon still from the
ordinary lag between feedback messages. The default of 1000 is a documented guess and is too
low for a busy primary: at a few hundred xids a second, one feedback interval is several
thousand xids of ordinary lag. Raise it on a busy primary, to roughly the xids assigned in
two or three feedback intervals.

## `bloat_cause_text(min_holder_age interval DEFAULT '1 minute', min_standby_xid_gap bigint DEFAULT 1000)`

Returns `SETOF text`, one line per table, formatted `relname: N dead rows (P%, source) ...`.
The same content as the view, written for a human to read rather than for a query to join to.

## `bloat_cause_holder(min_holder_age interval DEFAULT '1 minute', min_standby_xid_gap bigint DEFAULT 1000)`

One row per horizon holder in the cluster: a client session, a prepared transaction, or a
standby holding back through its physical slot. Ordered so the oldest is first.

| Column | Type | Meaning |
| --- | --- | --- |
| `kind` | `text` | `session`, `prepared` or `standby`. |
| `pid` | `integer` | The backend, for `session`. NULL for the other two. |
| `gid` | `text` | The transaction identifier, for `prepared`. NULL for the other two. |
| `slot_name` | `name` | The slot, for `standby`. NULL for the other two. |
| `application_name` | `text` | As reported by the session, or `no application_name`. |
| `state` | `text` | The session's state, for `session`. |
| `who` | `text` | A description naming the pid, the gid or the slot, suitable for a sentence. |
| `since` | `timestamptz` | When the holder began, where visible. NULL for `standby`, because the query is on the other host. |
| `xid_age` | `integer` | The holder's transaction id age, in xids. This is what orders the rows. |

A logical replication slot is deliberately absent, though it also holds a horizon. It holds
`catalog_xmin`, which protects catalog rows rather than user tables, and reporting it here
would name it as the reason a user table cannot be cleaned when it is not.

## `bloat_cause_command(min_holder_age interval DEFAULT '1 minute', min_standby_xid_gap bigint DEFAULT 1000)`

One row per table, for the primary cause only, with the statement that clears it.

| Column | Type | Meaning |
| --- | --- | --- |
| `schemaname` | `name` | Schema of the table. |
| `relname` | `name` | Table name. |
| `cause` | `text` | The primary cause, the same value the view reports. |
| `command` | `text` | The statement, as text. Never run by this extension. |
| `loses` | `text` | What running it costs, in the same row, because the statement alone reads as harmless. |

Two rules govern it, and both are deliberate. It is for the **primary cause only**: a reader
handed four statements for one table would paste all four, and two of them would look like
the fix while doing nothing about the cause holding the rows. And every destructive statement
carries its cost in `loses`, because dropping a slot loses that consumer's position and
cannot be undone by recreating it.

What it emits, per cause:

| Cause | Statement |
| --- | --- |
| `horizon holder`, session | `SELECT pg_cancel_backend(<pid>);` |
| `horizon holder`, prepared | `ROLLBACK PREPARED '<gid>';` |
| `horizon holder`, standby | **no row.** The query is on the other host. |
| `lock keeps vacuum off` | `SELECT pg_cancel_backend(<pid>);` |
| `lock blocks anti-wraparound vacuum` | `SELECT pg_cancel_backend(<pid>);` |
| `autovacuum behind` | `VACUUM (VERBOSE) <table>;` |
| `autovacuum disabled` | a read-back of both the cluster and the table setting |
| `autovacuum thresholds not reached` | a read-back of the table's options |
| `updates not HOT` | a read-back of the update counters |

Cancelling is used rather than terminating because cancelling asks a session to stop at the
next safe point and lets a running query finish. Termination is the harsher tool and is not
the first thing to hand someone a sentence about.

The three autovacuum causes return a read-back rather than an action on purpose.
`ALTER TABLE ... RESET (autovacuum_enabled)` reads as the fix and does nothing when the
threshold is simply never reached, which is a tuning decision and not something to paste.
Only `autovacuum behind` acts, and it acts with `VACUUM`.

The caller's own session is never returned, so an operator cannot be handed the means to
disconnect themselves mid-query.

## `bloat_cause_context(schema name, table name)`

The autovacuum context for one table, from `pg_stat_user_tables` and `pg_class`. It is the answer to
the question the finding leaves open: has autovacuum even tried? It reads statistics and catalogs
only, so it never needs `pgstattuple` and never reads the table.

One row per table. It raises `42P01` when the schema and table name do not match an ordinary table,
materialized view or partitioned table, so a typo is not an empty result.

| Column | Type | Meaning |
| --- | --- | --- |
| `schemaname`, `relname`, `relid` | `name`, `name`, `oid` | The relation. |
| `relkind` | `"char"` | `r` ordinary table, `m` materialized view, `p` partitioned table. |
| `n_live_tup`, `n_dead_tup` | `bigint` | The statistics' live and dead row estimates. |
| `n_mod_since_analyze`, `n_ins_since_vacuum` | `bigint` | Rows changed since the last analyze, and inserted since the last vacuum. |
| `n_tup_ins`, `n_tup_upd`, `n_tup_del` | `bigint` | Cumulative tuple counts since the statistics were reset. |
| `n_tup_hot_upd`, `n_tup_newpage_upd` | `bigint` | HOT updates, and updates that could not stay on the page. The second is NULL before PostgreSQL 16. |
| `last_vacuum`, `last_autovacuum`, `last_clean` | `timestamptz` | Last manual vacuum, last automatic vacuum, and the later of the two. |
| `last_analyze`, `last_autoanalyze` | `timestamptz` | Last manual and automatic analyze. |
| `vacuum_count`, `autovacuum_count` | `bigint` | Cumulative manual and automatic vacuum counts. |
| `analyze_count`, `autoanalyze_count` | `bigint` | Cumulative manual and automatic analyze counts. |
| `reltuples`, `relpages` | `real`, `integer` | The planner's row and page estimates. |
| `heap_bytes` | `bigint` | `pg_relation_size(relid)`: the heap only, not TOAST or indexes. |
| `autovacuum_enabled` | `boolean` | The table reloption resolved against the cluster's `autovacuum` setting. |
| `vacuum_threshold`, `vacuum_scale_factor` | `bigint`, `float8` | The vacuum trigger values, per-table reloption or cluster default. |
| `vacuum_insert_threshold`, `vacuum_insert_scale_factor` | `bigint`, `float8` | The insert-based vacuum trigger values. |
| `analyze_threshold`, `analyze_scale_factor` | `bigint`, `float8` | The analyze trigger values. |

Counts are cumulative since the last `pg_stat_reset()` or crash recovery, like the statistics they
come from. The function is closed like the other readers; a role sees the table only when its own
privileges allow it.

## `bloat_cause_age(interval)`

Formats an interval for the sentences: days when it is two days or more, hours when it is two
hours or more, and so on down to seconds. Returns `text`. It reads nothing, which is why it is
the one function here that is executable by `PUBLIC`.

## `bloat_cause_history` (table)

The sampled series, one row per table per sample (primary key `schemaname, relname, sampled_at`).
Registered with `pg_extension_config_dump`, so `pg_dump` carries it.

| Column | Type | Meaning |
| --- | --- | --- |
| `sampled_at` | `timestamptz` | The instant the sample is about. |
| `schemaname` | `name` | Schema of the table. |
| `relname` | `name` | Table name. |
| `dead_rows` | `bigint` | Estimated dead rows. |
| `dead_pct` | `numeric` | Estimated dead share. |
| `dead_bytes` | `bigint` | Estimated dead **heap** bytes. Excludes TOAST and index bytes. |
| `dead_rows_source` | `text` | Always `estimated` in 0.4.0: the view and the sampler report estimates, the reset marker included. `unknown` is not a value it takes. |
| `stats_reset` | `boolean` | `true` only on the marker row a sample writes across a `pg_stat_reset()` or crash recovery; `false` on every ordinary row. The marker carries NULL figures and re-baselines the series. |
| `holder_pid` | `int` | The horizon holder's pid when the cause was `horizon holder`, else NULL. |
| `holder_xid_age` | `interval` | How long that holder had run, else NULL. |
| `holder_slot` | `text` | The replication slot when a slot was the holder, else NULL. |
| `holder_query` | `text` | NULL unless the session set `bloat_cause.holder_query` on, the holder was a session (not a prepared transaction or a standby), and the cause was `horizon holder`. Then it is the holder's first statement, with the credential shapes in [holder-query.md](holder-query.md) redacted and the text marked `[truncated]` when it reaches the server's query-text limit. Best-effort: it can still contain secrets, so treat it as untrusted text. |

## `bloat_cause_sample(min_dead_pct numeric DEFAULT 0.1, min_dead_bytes bigint DEFAULT 0, sampled_at timestamptz DEFAULT NULL)`

Appends one sample of every table worth a row: at or above both floors, or already in the history,
so a series that starts does not silently stop. Returns one row per cause with `sampled`,
`below_floor` and `not_established` counts. It reads `bloat_cause_findings()` and never measures, so
it needs no `pgstattuple`. A sample taken across a `pg_stat_reset()` writes a marker row with
`stats_reset = true` and NULL figures, and is counted in `not_established`: the marker re-baselines
the series, so the next sample is ordinary, and `dead_rows_source` stays `estimated`. A role granted
the sampler samples only the tables it can read. Schedule it; the `sampled_at` argument is for
fixtures.

## `bloat_cause_prune(older_than interval DEFAULT '35 days')`

Deletes samples older than the given age and returns the count.

## `bloat_cause_notify(channel text DEFAULT 'bloat_cause', min_dead_pct numeric DEFAULT 0.1, min_dead_bytes bigint DEFAULT 104857600, min_holder_age interval DEFAULT '1 minute')`

Raises one `NOTIFY` on `channel` when a table is BOTH at least `min_dead_pct` dead AND at least
`min_dead_bytes` of dead space, and again each time it crosses the next ten-times rung above
`min_dead_bytes` (which is the first rung and has no fixed top). The rung is compared against the
highest already notified, never against the previous sample, so a table that sits still notifies
once. Returns how many notifications it raised. The payload is the shared `pg_incident_watch`
contract: `tool`, `subject` (the schema-qualified relation name), `sampled_at`, `channel`, `event`,
`level`, `previous_level`, `dead_rows`, `dead_pct`, `dead_bytes`, `dead_rows_source`, `cause` and
`cause_detail`. A statistics reset cannot suppress an alert: this reads the current findings and
never consults the history or the `stats_reset` marker, so a table over the threshold after a reset
still alerts and a higher rung after a reset still escalates.

## `bloat_cause_notify_resolved(channel text DEFAULT 'bloat_cause', min_dead_pct numeric DEFAULT 0.1, min_dead_bytes bigint DEFAULT 104857600, min_holder_age interval DEFAULT '1 minute')`

Raises one `cleared` `NOTIFY` per subject that had alerted and is still watched (present in
`bloat_cause_findings()`) but is now below the alert threshold, then forgets its state. A table that
has left the findings is not watched and is not cleared, and a subject whose most recent sample is a
reset marker (`stats_reset = true`) or is older than the current statistics reset time is unknown and
is not cleared either. The `cleared` payload carries `level` (the last level reached) with
`previous_level` absent.

## `bloat_cause_alert` (table)

The state the two senders share, one row per subject per channel, holding the severity (rung) last
notified and the notification count. Managed by the senders; do not edit it by hand.

## Grants

See [INSTALL.md](../INSTALL.md) for the exact grants. In short: `SELECT` on the view,
`EXECUTE` on the functions, and `pg_read_all_stats` so that other users' sessions are
visible. Without the last one, a session holding the horizon is simply absent and every row
carries a note saying so, rather than the finding being wrong in silence.
