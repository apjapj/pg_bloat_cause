# `holder_query`: storing the holding session's query, opt-in

**Status: proposal, not built.** It would be a new release, 0.5.0, with a full script and an
update path. Nothing changes until this note is accepted.

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

The opt-in is the protection; redaction is a second line, and it is lossy by nature. The rules:

- Store only the **first statement** of `pg_stat_activity.query`, truncated to 1024 bytes, with
  the truncation marked.
- Redact the credential shapes that are known: the literal after `PASSWORD` in `CREATE ROLE` and
  `ALTER ROLE`, and the literal in `ALTER ROLE ... PASSWORD`. Anything else is stored as written.
- Do not claim to redact what cannot be known: a literal in an arbitrary `INSERT` is the
  operator's data. The documentation says the column can contain secrets and that the opt-in is
  the real control.
- A test stores a query containing a password literal and asserts the stored text does not contain
  it, and asserts the column is NULL with the opt-in off (the default).

## Existing data on an update

The column exists, so the update path changes functions only; no rewrite of
`bloat_cause_history`. Rows sampled before the opt-in stay NULL. Turning the GUC off does not
erase text already stored; the documented cleanup is `UPDATE bloat_cause_history SET holder_query
= NULL`, which the owner may run. Turning it on affects new samples only.

## What the tests must prove

1. **Default off:** a sample writes `holder_query IS NULL` for every row.
2. **Opted in:** the holding session's first statement is stored, truncated and marked.
3. **Redaction:** a query with a password literal does not store the literal.
4. **Update:** 0.4.1 updates to the new version with the function replaced, the column unchanged,
   and the grant preserved.

## What it would not change

`bloat_cause_findings()`, `bloat_cause_text()`, `bloat_cause_holder()`, `bloat_cause_command()`
and `bloat_cause_measure()` keep their shapes. `pgstattuple` stays optional. The sampler still
never measures. `dead_rows_source` stays `'estimated'`.

## Decision

One question: accept Option A, a `bloat_cause.holder_query` GUC, with the redaction and tests
above, for 0.5.0? If yes, the next step is the full script, the update path, and the tests; if no,
the column stays NULL and the note is closed as declined.
