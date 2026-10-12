# changelog

Versions are listed newest first. Released tags are never edited: a change that needs
a new entry gets a new version.

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