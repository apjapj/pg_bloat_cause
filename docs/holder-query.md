# `holder_query`: storing the holding session's query, opt-in

**Status: implemented in 0.5.0.** The GUC, the redaction, the truncation and the update path are in
`pg_bloat_cause--0.5.0.sql` and `pg_bloat_cause--0.4.1--0.5.0.sql`; `test/04_holder_query.sql` is the
proof. The rest of this note is the design it was built from.

## Why the column is empty

`bloat_cause_history.holder_query` exists and is **always NULL** in 0.4.x. Query text can contain
secrets, and storing it needs an explicit opt-in that 0.4.x does not ship. The column is there so
the shape does not change later; it must not start holding text by default.

This note is about that column. It is **not** about the word "holder" in the book prose: the book
calls the session at the top of a lock queue a **root**, and "holder" is a forbidden synonym there.
The column keeps its name; prose keeps "root".

## The opt-in

The principle in 0.4.x is that these extensions have no configuration of their own. An opt-in
breaks that principle, so the mechanism matters.

**Option A, a custom GUC: `bloat_cause.holder_query` (boolean, default off).**
The sampler reads `current_setting('bloat_cause.holder_query', true)`. It is the standard
PostgreSQL opt-in, needs no new object, and a cron job sets it in its own session. It is
per-session: a pooled or forgotten setting can differ from what the operator expects, and a
cluster-wide setting must be in `postgresql.conf` or `ALTER SYSTEM`, outside the extension.

**Option B, a config table: one row, one boolean.**
The sampler reads the row; absent means off. It survives restarts and pooling, is grantable, and
is visible in `\d`. It adds an extension table and a privilege surface, and the extension has none
today.

**Option C, a sampler argument.**
`bloat_cause_sample(..., with_query boolean DEFAULT false)`. This changes the function signature,
which `CREATE OR REPLACE` cannot do: it needs a new overload or a drop and recreate, and the
grant is lost. Rejected for that reason alone.

**Recommendation: A.** One GUC is smaller than a table, and the sampler already runs from a
scheduled session where setting it is explicit. If the operator wants it cluster-wide, that is
`ALTER SYSTEM`, which PostgreSQL already documents and audits.

## Redaction

The opt-in is the protection; redaction is a second line, and it is best-effort by nature. The rules:

- Store only the **first statement** of `pg_stat_activity.query`.
- Redact the known credential shapes. The list is written down because it is a contract, and every
  shape on it has a test in `test/04_holder_query.sql`:
  1. the literal after `PASSWORD` in `CREATE ROLE`, `CREATE USER`, `ALTER ROLE` and `ALTER USER`
     (so `ENCRYPTED PASSWORD` too);
  2. `password=` in the connection string of `CREATE SUBSCRIPTION ... CONNECTION '...'`;
  3. `password=` in the connection string of `dblink_connect('...')`.
- Do not claim to redact what cannot be known: a literal in an arbitrary `INSERT` or `UPDATE` is the
  operator's data and is stored as written. The opt-in is the real control.

**The opt-in carries this warning.** `holder_query` is untrusted text that may still contain
credentials: the redaction is best-effort and its list is finite. Turning the opt-in on is accepting
that; the reader of `bloat_cause_history` must treat the column accordingly, and the documented
cleanup for text already stored is `UPDATE bloat_cause_history SET holder_query = NULL`.

## Truncation

`pg_stat_activity.query` holds at most `track_activity_query_size - 1` characters, and it does not
say whether it cut the text: a query that ends at the cap and one that happens to be exactly that
short look the same. So the marker is added when the stored length **reaches** the server's limit,
read at sample time with `pg_size_bytes(current_setting('track_activity_query_size'))`, as well as
when it passes the sampler's own 1024-byte limit. The cost is that a query exactly one character
under the cap is marked though it was not cut; that is harmless, and it means a query the server cut
is never presented as complete. When the server's limit is raised above 1024 (it needs a restart, so
the default servers run at 1024), the sampler's own 1024-byte truncation fires and marks as well.

## Existing data on an update

The column exists, so the update path changes functions only; no rewrite of
`bloat_cause_history`. Rows sampled before the opt-in stay NULL. Turning the GUC off does not
erase text already stored; the documented cleanup is `UPDATE bloat_cause_history SET holder_query
= NULL`, which the owner may run. Turning it on affects new samples only.

## What the tests must prove

1. **Default off:** a sample writes `holder_query IS NULL` for every row.
2. **Opted in:** the holding session's first statement is stored; a short statement is stored in full
   and unmarked, and one at the server's query-text cap is truncated and marked.
3. **Redaction:** every shape in the list above is redacted, an ordinary `UPDATE ... password =` is
   not, and no stored value contains the literal.
4. **Update:** 0.4.1 updates to the new version with the function replaced, the column unchanged,
   and the grant preserved.

## What it would not change

`bloat_cause_findings()`, `bloat_cause_text()`, `bloat_cause_holder()`, `bloat_cause_command()`
and `bloat_cause_measure()` keep their shapes. `pgstattuple` stays optional. The sampler still
never measures. `dead_rows_source` stays `'estimated'`.

## Decision

Accepted: Option A, a `bloat_cause.holder_query` GUC (boolean, default off), with the redaction,
truncation and tests above, for 0.5.0. Built in `pg_bloat_cause--0.5.0.sql`, reached from 0.4.1 by
`pg_bloat_cause--0.4.1--0.5.0.sql`.
