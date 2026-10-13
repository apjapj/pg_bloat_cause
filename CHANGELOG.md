# changelog

Versions are listed newest first. Released tags are never edited: a change that needs
a new entry gets a new version.

## 0.2 (unreleased)

The holder, in structured form. No existing output changes: every sentence and every
evidence file is byte-identical to 0.1, and the scenario suite fails if one moves.

- `bloat_cause_holder(age, gap)` returns every horizon holder as a row: `kind`, `pid`,
  `gid`, `slot_name`, `application_name`, `state`, `who`, `since`, `xid_age`. It exists
  for `bloat_cause_command()`, which has to emit a statement naming a pid or a gid. In
  0.1 the holder was named only in `cause_detail`, which is prose, and a caller cannot
  get a pid out of an English sentence without parsing it.
- A logical replication slot is deliberately absent: it holds `catalog_xmin`, which
  protects catalog rows rather than user tables, and `s2` asserts that.
- `bloat_cause_findings()` still keeps its own inline copy of the holder logic in this
  release. Switching it to the shared function is a separate change.
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