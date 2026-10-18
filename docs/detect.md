# detect: the sampler, the history, and the alerting, settled before any code

**Status: implemented.** Shipped in 0.4.0 as `bloat_cause_sample()`, `bloat_cause_history`,
`bloat_cause_prune()`, `bloat_cause_notify()`, `bloat_cause_notify_resolved()` and
`bloat_cause_alert`, with the pgTAP suite in `test/02_history.sql` and `test/03_detect.sql`. This is
the plan for step 6 of `README.md`, written before the SQL so the next session started from decisions
rather than questions, the way `docs/measure.md` was written for `bloat_cause_measure()`. The shared
contract in `pg_incident_watch` is the authority for the payload; this document is the authority for
what bloat_cause samples and when it notifies. The statistics-reset design was reworked twice in
review. The first rework wrote no row across a reset and reported it in `not_established`; the
second, which this document now records as shipped, writes a **marker row** flagged `stats_reset =
true` with NULL figures, so the series re-baselines on the next sample, the sender reads the flag off
the row, and a reset cannot leave a table unsampled until the pre-reset row is pruned.

The three decisions this document first left open have since been settled in review; they are marked
**[review]** below. The last one, the escalation's size rungs, is settled too, marked **[settled]**.

Three points are worth recording as built, including one correction to this plan. The stats-reset
guard (reworked twice in review) compares `pg_stat_get_db_stat_reset_time()` against the subject's
previous sample, and a sample taken
across a reset writes a **marker row** flagged `stats_reset = true`: the row carries NULL figures,
because the change across the reset cannot be computed, and the sample is counted in
`not_established`. The marker is the first post-reset row, so the very next sample has a post-reset
previous row and is ordinary; writing no row at all (the first rework) left the pre-reset row as the
latest sample, so the reset time stayed newer than it on every later sample and the table was never
sampled again until that row was pruned, up to 35 days. `dead_rows_source` therefore keeps its meaning
and is `'estimated'` on every row the view and the sampler write; `'unknown'` is not a value it takes.
The sender reads the flag: a latest sample with `stats_reset = true` is unknown, and so is a latest
sample that predates the reset time. The plan's privilege premise
was also **corrected**: it assumed `pg_stat_user_tables` was filtered by privilege the way
`pg_stat_activity` is, which PostgreSQL does not do. The sampler filters to tables the calling role
can read with `has_table_privilege(c.oid, 'SELECT')`, so a role granted only the sampler does not read
another role's tables into the shared history, which the Verification section below requires. The
filter stays. `holder_query` is always NULL in 0.4.0: storing query text needs an explicit opt-in and
this release ships none, so the column exists and stays empty rather than holding text that would
have to be redacted on every sample.

## What it will be

```
bloat_cause_sample(min_dead_pct numeric DEFAULT 0.1,
                   min_dead_bytes bigint DEFAULT 0,
                   sampled_at timestamptz DEFAULT NULL)
  RETURNS TABLE (kind text, sampled int, below_floor int, not_established int)

bloat_cause_prune(older_than interval DEFAULT interval '35 days')
  RETURNS bigint

bloat_cause_notify(channel text DEFAULT 'bloat_cause',
                   min_dead_pct numeric DEFAULT 0.1,
                   min_dead_bytes bigint DEFAULT 104857600,   -- 100 MB, the first rung
                   min_holder_age interval DEFAULT interval '1 minute')
  RETURNS bigint

bloat_cause_notify_resolved(channel text DEFAULT 'bloat_cause', <same thresholds>)
  RETURNS bigint
```

and a history table:

```
bloat_cause_history (
  sampled_at     timestamptz,
  schemaname     name,
  relname        name,
  dead_rows      bigint,
  dead_pct       numeric,
  dead_bytes     bigint,
  dead_rows_source text,        -- always 'estimated': the sample never measures
  stats_reset    boolean,       -- true on the marker row a sample writes across a reset, else false
  holder_pid     int,           -- the horizon holder, or NULL
  holder_xid_age interval,      -- how long that transaction has run, or NULL
  holder_slot    text,          -- the replication slot, when a slot is the holder, or NULL
  holder_query   text,          -- NULL unless text storage is opted in and redacted
  PRIMARY KEY (schemaname, relname, sampled_at)
)
```

## Settled decisions

**The subject is the table, and it is schema-qualified.** The shared contract fixes the bloat subject
as the relation name, not the OID, because a listener reading a log a week later cannot resolve an
OID. It is `format('%I.%I', schemaname, relname)`, the same identity `bloat_cause_findings()` prints.

**The sample is the estimate, and it never measures.** It reads `bloat_cause_findings()`, which is
`pg_stat_user_tables` and the catalog, and writes `dead_rows_source = 'estimated'`. It does **not**
call `bloat_cause_measure()`: that reads the heap, and `docs/measure.md`'s whole point is that the
whole-table read happens only when a caller asks for one table. A sampler that measured would be the
implicit whole-database read the contract forbids.

**Every stored row and every payload says the numbers are estimates.** `dead_rows_source` is carried
in the history row and in the payload, so a reader never has to guess whether a figure came from a
table read. **[review]**

**Only tables worth a row are sampled, and the floor is a function argument.** A table at or above
`min_dead_pct` (default 10%) **and** `min_dead_bytes` (default 0) is sampled, **and** any table
already in the history is sampled even below the floor, so a series that starts does not silently
stop. The floors are **arguments with defaults, not a GUC**: these extensions are pure SQL with no
configuration of their own, and `sampled_at` is already an argument, so a GUC would add global state
the history table cannot reproduce. **[review]**

**Samples are one statement each, and `sampled_at` is an argument.** The row count a sample writes is
bounded by the number of tables above the floor, and a caller passing `sampled_at` is laying a
fixture, exactly as `pg_limit_runway`'s `limit_runway_sample()` does.

**The history is the user's data.** It is registered with `pg_dump` through `pg_extension_config_dump`,
as `limit_runway_history` and `lock_tree_history` are, because a series is what makes a trend readable
after the fact.

**Escalation compares against the last notification, not the last sample.** This is the contract's
rule and `pg_lock_tree`'s hard-won one: a quantity that only grows makes the previous-sample
comparison true on every sample. The state table is `bloat_cause_alert`, one row per subject per
channel, holding the severity last notified.

**The metric is `dead_bytes`, gated on both floors, with `dead_pct` shown.** **[settled]** A table's
bloat is a state, not a date, so it has no natural halving; it needs a size ladder. `dead_bytes` is
what "slowing down" costs and what VACUUM will have to do, and a percentage alone alerts on a 40-row
table that is 60% dead. A level fires only when the table is **both** at least `min_dead_pct` dead
**and** at least `min_dead_bytes` of dead space, so a huge table at 2% and a tiny table at 60% each
stay quiet. The payload carries `dead_pct` beside `dead_bytes` so a reader sees both.

**The holder is a `then:` line, not its own subject.** **[review]** A long transaction holding back
VACUUM is the cause of the bloat, and `bloat_cause_holder()` already reports it. Keeping the table as
the subject means a listener's deduplication key does not change identity when the holder changes.

**Stored holder context is pid, transaction age and slot name, not query text.** **[review]** Query
text is stored only through an explicit opt-in, and redacted (with `pg_lock_tree`'s rules, the
`SCRAM-SHA-256$4096:<salt>$<StoredKey>:<ServerKey>` shape included) when it is. A redaction step that
must work on every sample is weaker than not storing the text at all.

**A statistics reset is unknown, not resolved.** **[review]** `n_dead_tup` is reset by a crash or by
`pg_stat_reset()`. Without a guard the next sample reads as a drop to zero and would be reported as
"cleared" when it is really "unknown". A sample taken across a reset writes a **marker row** flagged
`stats_reset = true` with NULL figures: the marker is the first post-reset row, so the series
re-baselines immediately and the next sample is ordinary, and the sample is still reported in
`not_established` rather than reading as a table that cleared. Writing no row was tried first and had
a persistence flaw: the pre-reset row stayed the table's latest sample, so the reset time stayed
newer than it on every later sample and the table was never sampled again until that row was pruned,
up to 35 days. `dead_rows_source` is not overloaded for this; it stays `'estimated'` on every row the
sampler writes, the marker included. `bloat_cause_notify_resolved()` treats a latest sample with
`stats_reset = true` as unknown, and also a latest `bloat_cause_history.sampled_at` older than
`pg_stat_get_db_stat_reset_time()` (the window before the next sample); in either case it must not
send `cleared`. That is the rule that matters most. `bloat_cause_notify()` is the other half: a
flagged or unknown sample means "unknown, so do not clear", and it must never mean "suppress alerts".
It walks the current findings and never consults the marker or the history, so a table over the
threshold right after a reset still raises a real onset, and a table that crosses a higher rung after
a reset still escalates. A reset that zeroes the counters simply removes the table from consideration
until it accumulates dead rows again; nothing in `notify()` clears state.

**A table leaving the sampled set is no longer watched, not cleared.** **[review]** A table that
drops below the floor stops being sampled; that must not send a "resolved". `bloat_cause_notify_resolved()`
clears a subject only when a table is still watched and is now below the alert threshold. The two
cases are distinguished by whether the table is present in the current findings, not by the absence
of a row.

## The escalation, in full

| rung | a notification fires when dead_bytes first reaches |
|---|---|
| onset | 100 MB (`min_dead_bytes`), with `dead_pct` at or above `min_dead_pct` (10%) |
| escalate | 1 GB |
| escalate | 10 GB |
| escalate | 100 GB |
| escalate | 1 TB |
| escalate | and on, by factors of ten, with no fixed top |

and the rungs are compared against the highest already notified, never the previous sample, so a
large table that sits still notifies once. **[settled] The ladder multiplies by ten and has no top**:
a fixed cap would go silent for a table that went on to lose 500 GB. `min_dead_bytes` (100 MB) and
`min_dead_pct` (10%) are both arguments, so a small system or a fixture can lower the first rung
without changing the ladder above it.

## The order of work, and why it is that order

1. **The harness change first: the with-and-without-`pgstattuple` matrix.** **Done before the
   sampler.** `README.md` step 7 said the suite runs **with** `pgstattuple` only, because the
   scenario library creates it unconditionally. The sampler must not need it, so before the sampler
   existed the suite had to be able to run without it, and the matrix leg that does so is real
   (`ci/job.sh` builds the primary, runs the suite, removes `pgstattuple` from both servers and runs
   the scenarios again). The estimate path is tested on a cluster that never had `pgstattuple`.
2. **`bloat_cause_sample()`, the history table and `bloat_cause_prune()`.**
3. **`bloat_cause_notify()` and `bloat_cause_notify_resolved()`**, with `bloat_cause_alert`.
4. **The documents**, if and only if the implementation shows a sentence needs amending.
5. **`INSTALL.md` grants** for the history table and the sender.
6. **Version 0.4.0**, a new release script and an update path, never an edit to 0.3.1.

Building the harness before the thing it tests is what this repository learned the hard way:
`bloat_cause_measure()` shipped broken with every gate green because nothing called it.

## Verification, and the paths that will actually find faults

**With `pgstattuple` and without it.** The without case is the new matrix leg, meaningful precisely
because the sampler must not depend on it.

**An unprivileged role.** This section first assumed, wrongly, that `pg_stat_user_tables` was
filtered by privilege the way `pg_stat_activity` is. That premise was **corrected**: PostgreSQL's
statistics views are not filtered, so a role granted only the sampler would otherwise read another
role's tables into the shared history. The sampler therefore filters to the tables the caller can
read, and `test/02_history.sql` asserts that a role samples its own table and not one it was not
granted. This is the path that found the `findings()` and `measure()` defects, and reading the SQL
found neither.

**A rising series, not a single sample.** The escalation test plants two or three samples whose
`dead_bytes` cross a rung, calls `notify()`, and asserts one notification per rung, then the silence
at the same rung. The silence half is the one a notify-on-every-sample function fails.

**A statistics reset.** `pg_stat_reset()`, then a sample, must write the marker row
(`stats_reset = true`, NULL figures) and report `not_established`, and the reset must never clear a
standing alert. The next sample must be ordinary, so the series resumes. A table over the threshold
right after a reset must still alert. The sender reads the marker off the row, and the reset time for
the window before the next sample.

**A table falling below the floor.** It must stop being sampled and must not send a "resolved".

**The redaction, when text is opted in.** A stored `holder_query` for a role holding a `SCRAM-SHA-256`
password must not contain the verifier. Assert the stored text, not a boolean that says it is redacted.

## What must not change

- `bloat_cause_findings()`, `bloat_cause_text()`, `bloat_cause_holder()`, `bloat_cause_command()` and
  `bloat_cause_measure()` keep their shapes.
- `pgstattuple` stays optional and is never invoked by the view, the sampler, or any function that
  does not exist solely to measure one named table.
- `dead_rows_source` stays `'estimated'` on every row the view and the sampler report, the marker
  row included. A sample taken across a statistics reset writes a marker row, so `'unknown'` is never
  a value it takes.
- Version: this is `0.4.0`, a new release script and a new update path, not an edit to `0.3.1`.

## The decisions, now settled

- **The size rungs** are settled: ten-times steps with **no top**, and `min_dead_bytes`'s default
  (100 MB) **is** the first rung, so the floor and the onset are the same number and cannot disagree.
  See the escalation table above.
- The first draft's other two open decisions, the metric and the holder, were settled earlier and are
  marked **[review]** in the text.

## What shipped

All six items of the order of work above are done, and the tests the Verification section calls for
are in `test/02_history.sql` and `test/03_detect.sql`: the sampler writes one row per table above the
floors and none for a table below them that is not already in the series; a sample across a
statistics reset writes a marker row flagged `stats_reset = true` with NULL figures, increments
`not_established`, and leaves every `dead_rows_source` at `'estimated'`, and the next sample is
ordinary so the series resumes; `notify()` fires once per rung and is silent at the same rung, a
table over the threshold right after a reset still alerts, and a new incident after a reset alerts
too; a reset never produces a `cleared` (whether the latest sample is a marker or predates the reset
time), and a table that dropped out of the findings is not cleared either; `cleared` carries the last
level with `previous_level` absent. The redaction case is deliberately not built:
`holder_query` is always NULL in 0.4.0, because storing query text needs an explicit opt-in and this
release ships none (these extensions have no configuration of their own, and no GUC was invented).
