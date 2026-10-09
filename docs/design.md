# design: the decisions the first version is built on

**For: whoever reads `pg_bloat_cause--0.1.sql` and wants to know why it is shaped this way.** Each
decision below was settled before the SQL was written, and each names the evidence that forced it.
The ranking itself, which cause comes first, is in [ranking.md](ranking.md).

## 1. Dead bytes are estimated, and every row says so

`bloat_cause` orders tables by dead bytes, and computes them as `n_dead_tup` times the table's average
row size on disk (heap size divided by live plus dead rows). Every row carries `dead_rows_source =
'estimated'`.

The label is mandatory because the estimate can be badly wrong. In s6 the statistics reported
[199,996](../scenarios/evidence/s6_thresholds_too_high.pg18.txt) dead rows and `pgstattuple` measured
[66,667](../scenarios/evidence/s6_thresholds_too_high.pg18.txt). An unlabelled figure that is three
times the truth is worse than no figure.

`pgstattuple` is never a dependency and never runs implicitly: it reads the whole table, and a view
that did so on every query would be the most expensive thing on the server. Measuring is a later,
explicit function (`bloat_cause_measure(regclass)`, which will find `pgstattuple` through
`pg_extension` if it is installed and return `measured`). It is not in 0.1.

## 2. Three finding states, not two

A row has:

- `cause`: the primary finding, the most upstream cause present, or NULL when none can be named;
- `then`: secondary causes, downstream of the primary, in ranking order;
- `unknowns`: things present whose effect cannot be established, chiefly a horizon holder on a table
  that has never been vacuumed.

The third state exists because s10 and s11 present identical evidence to anything that does not run a
VACUUM ([100,000](../scenarios/evidence/s10_never_vacuumed_holder_before.pg18.txt) dead rows in each, a
holder present in each) and differ only in whether the holder binds. So "not established" has to be
representable, and it must not swallow a cause the tool can name: in s10 and s11 the table also has
autovacuum disabled, which needs no vacuum history, so the row's `cause` is autovacuum disabled and the
holder is in `unknowns`. `cause` is NULL only when nothing at all can be named.

A NULL `last_vacuum` and `last_autovacuum` never fall through to "the holder binds". The binding test
is "a vacuum finished after the holder started and dead rows remain", and with no vacuum it is not
evaluated at all.

## 3. Read-only

No writes, no VACUUM, no state owned by the extension, no history, no alerting and no `NOTIFY` in 0.1.
It reads `pg_stat_user_tables`, `pg_class`, `pg_stat_activity`, `pg_locks`, `pg_prepared_xacts`,
`pg_replication_slots` and `pg_stat_replication`, and nothing else. That is why it cannot settle the
never-vacuumed case itself, and why the finding hands the operator the VACUUM that does.

## 4. PostgreSQL 14 and later, per-feature checks above that

The floor is 14, revisited at its end of life on 2026-11-12. Anything newer is checked at run time and
degrades with a stated message. `n_tup_newpage_upd` exists only on 16 and later, so on 14 and 15 the
HOT note says it cannot separate an indexed-column update from a full page; on 16 and later it gives
only the lower bound the s8 evidence supports.

## 5. Horizon holders, and what 0.1 does about each

| holder | start time | binding test in 0.1 |
|---|---|---|
| session holding an xid or snapshot | `xact_start` | a vacuum finished after it, and dead rows remain |
| prepared transaction | `pg_prepared_xacts.prepared` | the same |
| standby through a physical slot | not visible on the primary | a vacuum has run, dead rows remain, and the slot's `xmin` is the oldest horizon in the cluster |
| logical slot | n/a | never, for a user table: its `catalog_xmin` holds back catalog tables only (s2) |

The standby row is weaker than the other two and says so in its detail: the primary never sees when
the standby's query began, only that the slot's `xmin` is where the horizon is (s3, where the
walsender's `backend_xmin` was NULL).

Holders younger than a minimum age are ignored, so the ordinary short transactions every server has
do not appear as causes. The default is one minute; `bloat_cause_findings(min_holder_age,
min_standby_xid_gap)` takes it as an argument, and the scenarios pass two seconds.

## Decisions made while writing it

- **Which tables appear.** A table appears when it has dead rows and at least one cause, secondary or
  unknown. A table with dead rows and nothing to say about them does not appear: that is autovacuum
  working, and a row for it would be noise.
- **One holder per table.** When several holders exist, the oldest is the one tested, because it is
  the one that binds; the others are not listed in 0.1.
- **A standby counts only past a gap of 1000 xids.** Found by the scenario suite: between feedback
  messages an idle standby's slot `xmin` trails the primary's horizon, and the first version counted
  that as a holder, so every table in one s8 run reported a standby as present. The primary cannot see
  when a standby's query began and this version keeps no history, so it cannot tell lag from a held
  query; the gap (`min_standby_xid_gap`, default 1000) is a heuristic and says so in its comment. s3,
  whose standby query pins only a few xids, passes 1. The default is a documented guess and too low
  for a busy primary: at a few hundred xids a second, one 10-second feedback interval is several
  thousand xids of ordinary lag, so expect to raise it there, to two or three intervals' worth.
- **A role that cannot see sessions is told so.** Found by testing the grants: without
  `pg_read_all_stats`, a session holding the horizon is invisible and the finding silently became the
  next cause down. Every row now carries a "not established" note for such a role, so the gap in what
  it can see is stated, not hidden. INSTALL.md gives the grant.
- **A view over a function.** `bloat_cause` is a view over `bloat_cause_findings()`, because the
  version check for `n_tup_newpage_upd` needs a function body, and a function can take the minimum
  holder age.
