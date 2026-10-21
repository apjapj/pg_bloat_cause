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

The intended shape, when it is implemented, is a **secondary line on the parent**: for example
"TOAST: 1.2 GB, 41% dead, measured", and only when `pgstattuple` can read the TOAST relation. There
is no cheap estimate for TOAST in `pg_stat_user_tables`, so without the extension the line is absent,
not guessed. It never becomes the primary cause: the primary cause is still the horizon, autovacuum
setting or lock that lets the parent and its TOAST accumulate dead rows.

### What must be built before the TOAST line

1. A fixture with out-of-line values, dead TOAST rows, and a vacuum that clears them. The parent heap
   and the TOAST heap must be measured separately, with the TOAST OID resolved from
   `pg_class.reltoastrelid`.
2. A test that the line appears only when `pgstattuple` is available, and says "not established"
   rather than zero when it is not.
3. A decision on the threshold: a TOAST line is useful only when it changes the action, so it should
   appear when TOAST dead bytes are material relative to the parent's, not on every wide table.
4. No change to the primary-cause ranking and no new command: `VACUUM` on the parent is the action for
   both.

This is a later release, not a change to the current finding shape.
