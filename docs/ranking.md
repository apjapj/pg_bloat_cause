# ranking: which cause comes first, and what happens to the others

**For: whoever maintains `bloat_cause` and `bloat_cause_text()`, and whoever has to argue with a
finding.** pg_bloat_cause reports one sentence per table, worst first. This document is the rule that
decides which cause the sentence names when more than one is true, and how the others are reported.
It was settled before any SQL, and `bloat_cause` and `bloat_cause_text()` have shipped since, as
0.1. The rule still binds: a change to either function is a change to what this document promises,
and this is the document to change with it. `bloat_cause_command()` shipped in 0.2, so every rule
below is now about behaviour you can run.

Every figure links to the scenario evidence it comes from; `scenarios/check-evidence.sh` fails if one
does not. The sample sentences in code blocks show the wording: their counts are the scenarios' own,
linked in the text next to each, and their durations ("for 4 min") are illustrative.

## The rule in one line

**Per table, the primary finding is the most upstream cause present; every other cause is a secondary
line under it; tables are ordered by the dead bytes of their primary finding.**

## What "upstream" means

Cause X is **upstream** of cause Y on a table when fixing Y alone would not remove a single dead row
while X is still there. In practice that comes down to one question: does X stop the remedy for Y from
working? The remedy for almost every cause is, in the end, a VACUUM that gets to run and is allowed to
remove what it finds. So:

| Cause | What it blocks | So it is upstream of |
|---|---|---|
| **Horizon holder** (session, prepared transaction, a standby's query held through `hot_standby_feedback`, which with a physical slot shows on the slot's `xmin`, not the walsender's, as s3 measured) | Every VACUUM's ability to *remove* rows newer than the horizon, manual or automatic | everything below |
| **Lock keeping vacuum off the table** | Every VACUUM's ability to *start* on this table: autovacuum skips it, a manual VACUUM waits | autovacuum off or behind, HOT efficiency |
| **Autovacuum off or behind** (disabled, thresholds never reached, workers saturated) | Only the *automatic* VACUUM; a manual one would work | HOT efficiency |
| **Updates that cannot be HOT** | Nothing. It is why dead rows are produced quickly, not why they stay | nothing |

That gives the order the README proposed: horizon holder, then lock, then autovacuum off or behind,
then HOT efficiency. The order is a consequence of "what blocks the remedy", not a severity scale, and
that matters for the cases below: it is why a downstream cause is never shown as a competing top
finding. It is not competing. It cannot be fixed yet.

**A logical slot is not a horizon holder for user tables.** It holds `catalog_xmin` only. In s2, with
an inactive logical slot present, VACUUM removed all
[100,000](../scenarios/evidence/s2_logical_slot.pg18.txt) dead rows of the user table and could not
remove [6,000](../scenarios/evidence/s2_logical_slot.pg18.txt) in `pg_attribute`. So a logical slot is
upstream only for catalog tables, and is reported against them, never against `orders`.

## The worked case: s9, two causes at once

`s9_orders` has autovacuum disabled **and** a session idle in transaction holding the horizon. Both are
true. The evidence settles which comes first: a manual VACUUM, which ignores `autovacuum_enabled`
entirely, removed [0](../scenarios/evidence/s9_two_causes.pg18.txt) of
[100,000](../scenarios/evidence/s9_two_causes.pg18.txt) dead rows. So re-enabling autovacuum would have
changed nothing, and the session is upstream. The finding reads:

```
s9_orders: 100,000 dead rows (47.07%, measured), held back by session bloat_scen_s9, idle in
transaction for 4 min. No VACUUM can remove them until it ends.
  then: autovacuum is disabled on this table (autovacuum_enabled=false). Fixing that alone will
  change nothing while the session above is open; do it after.
```

The rules this case fixes:

1. **One primary per table.** The top line names exactly one cause, the most upstream one present.
2. **A downstream cause is a secondary line, introduced by `then:`**, and says in words that fixing it
   alone will not help yet. It is never dropped: once the session ends, `autovacuum_enabled=false` is
   the next thing standing between this table and a clean state, and an operator who ends the session
   and sees the table not recover needs to have been told why in advance.
3. **The command offered is for the primary only.** `bloat_cause_command()` returns the statement that
   ends the session. It does not also return `ALTER TABLE ... RESET (autovacuum_enabled)`, because a
   reader pasting both would believe the second did something.
4. **Ranking across tables uses the primary's dead bytes**, so `s9_orders` sorts by its 100,000 dead
   rows held back by the session, not by anything about its autovacuum setting.

## The other cases, all of which end with autovacuum not running

s5, s6 and s7 look alike from the outside: dead rows over the threshold and no recent autovacuum. They
are three different findings with three different fixes, and the rule has to keep them apart.

**s5, autovacuum disabled.** Nothing upstream, so it is primary. The control table, changed
identically, was autovacuumed to [0](../scenarios/evidence/s5_autovacuum_disabled.pg18.txt) dead rows.

```
s5_orders: 50,000 dead rows (31.38%, measured), past its autovacuum threshold of 20,050, but autovacuum
is disabled on this table (autovacuum_enabled=false).
```

Figures: [50,000](../scenarios/evidence/s5_autovacuum_disabled.pg18.txt),
[31.38%](../scenarios/evidence/s5_autovacuum_disabled.pg18.txt),
[20,050](../scenarios/evidence/s5_autovacuum_disabled.pg18.txt).

**s6, thresholds never reached.** Also primary, and the sentence must name *both* thresholds, because
either one firing cleans the table (the first draft of the fixture was cleaned by the insert trigger).
It must also say when the statistics disagree with the measurement, because here they disagree
threefold:

```
s6_orders: 66,667 dead rows (20.8%, measured; the statistics say 199,996), but its own autovacuum
thresholds (5,050,000 dead rows, 5,050,000 inserted rows) are never reached.
```

Figures: [66,667](../scenarios/evidence/s6_thresholds_too_high.pg18.txt),
[20.8%](../scenarios/evidence/s6_thresholds_too_high.pg18.txt),
[199,996](../scenarios/evidence/s6_thresholds_too_high.pg18.txt),
[5,050,000](../scenarios/evidence/s6_thresholds_too_high.pg18.txt).

**s7, a lock keeps vacuum off.** The lock is upstream of autovacuum, so a finding of "autovacuum is
behind" on this table would be wrong: autovacuum tried and was refused. An ordinary autovacuum skipped
the table at least [3](../scenarios/evidence/s7_autovacuum_vs_lock.pg18.txt) times in 40 seconds and never
appeared in `pg_stat_activity`, so the evidence is the lock, not a waiting worker:

```
s7_orders: 100,000 dead rows, never autovacuumed: session bloat_scen_s7 holds SHARE UPDATE EXCLUSIVE
on it, which autovacuum needs, so autovacuum skips the table every time it tries.
```

Dead rows: [100000](../scenarios/evidence/s7_autovacuum_vs_lock.pg18.txt). Once the table needs an
anti-wraparound vacuum, past an age of [110,000](../scenarios/evidence/s7_autovacuum_vs_lock.pg18.txt)
xids here, the worker stops skipping and **waits**, visibly. That is the more urgent form of the same
finding, and it outranks every other lock finding:

```
s7_orders: an anti-wraparound autovacuum is waiting on session bloat_scen_s7's lock. Until it ends this
table cannot be frozen, and the database is moving towards wraparound.
```

## A horizon held from a standby

s3 is a horizon holder like s9's session, with one difference that changes the sentence: the query is
not on this server, so neither `pg_stat_activity` nor the fix is here. The primary removed
[0](../scenarios/evidence/s3_standby_feedback.pg18.txt) of
[100,000](../scenarios/evidence/s3_standby_feedback.pg18.txt) dead rows, saw the standby only as its
physical slot's `xmin` (the walsender's `backend_xmin` was NULL), and removed all
[100000](../scenarios/evidence/s3_standby_feedback.pg18.txt) once the standby's query ended:

```
s3_orders: 100,000 dead rows (47.07%, measured), held back by standby bc_standby_18 through its slot
standby_s3 (hot_standby_feedback). A query open ON THE STANDBY is the cause; end it there, or turn
hot_standby_feedback off and accept query cancellations on the standby.
```

It ranks as a horizon holder, above everything else on the table, and `bloat_cause_command()` returns
nothing runnable here: the statement that fixes it has to be run on another server.

## Within one cause: dead bytes, not share

Two tables with the same primary cause are ordered by **dead bytes**, the space the dead rows take
(`dead_tuple_len` when measured, `n_dead_tup` times the average row width when estimated). Not by
dead-row share: a 10 MB table at 90% dead is a smaller problem than a 400 GB table at 40%, and share
would put it first.

A horizon holder affects every table with dead rows, so it is reported **once**, with the tables it
holds back listed under it in dead-bytes order, rather than as one identical top line per table.

When several holders exist, the one with the oldest horizon is primary, because it is the one that
binds: ending a younger holder first removes nothing. The others are secondary lines, since each
becomes primary in turn.

## HOT efficiency is never primary over a cleanup failure

Non-HOT updates explain why dead rows arrive quickly. They never explain why they stay. So a HOT
finding is primary only on a table with no cleanup failure at all, and is a tuning note, not an
incident. What it may say is limited by the counters. In s8, an update to an indexed column on a full
page and an update to an unindexed column on a full page are identical in every counter
([20,000](../scenarios/evidence/s8_non_hot_updates.pg18.txt) non-HOT, and
[20,000](../scenarios/evidence/s8_non_hot_updates.pg18.txt) moved to a new page, each), so on 16 and
later the finding can only give a lower bound for the indexed-column share. On 14 and 15 it says it
cannot separate the two at all.

## Tested: when the horizon holder is present but not binding

The rule above treats a horizon holder as upstream whenever it exists. That is wrong in one case: a
session that opened *after* a table's dead rows were made does not hold those rows back. s5's table
would still be bloated with a young session open somewhere, and naming the session as primary would
send the operator to the wrong fix.

The extension cannot run VACUUM to find out. What it can see is whether a vacuum of the table finished
after the holder's transaction started and left the dead rows in place, which is direct evidence that
the holder binds. Proposed: the holder is primary when that evidence exists, or when its horizon is
older than the table's last vacuum; otherwise it is a secondary line marked "may be holding these
back", and the next cause down is primary. This needs a fixture before it is code: s5's table with a
session opened after the updates.

**A table that has never been vacuumed is the case that test cannot answer.** With `last_vacuum` and
`last_autovacuum` both NULL there is no vacuum to compare the holder's start against, and comparing
against NULL must not fall through to "the holder binds": that would make every never-cleaned table
look held back by whichever session happens to be open, which is the same trap pg_lock_tree's alert
state fell into when a wait recorded on every sample made "has it grown" permanently true. So the rule
for this case is explicit: **no vacuum, no binding verdict.** The finding says what is known and stops.
Measured in s10, where the session opened before the updates:

> s10_orders: [100,000](../scenarios/evidence/s10_never_vacuumed_holder_before.pg18.txt) dead rows ([47.07%](../scenarios/evidence/s10_never_vacuumed_holder_before.pg18.txt), measured). Cause not established: this
> table has never been vacuumed, so it cannot be told whether session bloat_scen_s10 is holding these
> rows back. Run VACUUM (VERBOSE) on it: "dead but not yet removable" above zero means the session binds.

The holder is reported as present, not as the cause, and the next step offered is the one that settles
it: a VACUUM, whose "dead but not yet removable" count is the binding test the extension cannot run
itself, since it does not write to the database. Other causes the table has (autovacuum disabled,
thresholds) are still reported as usual, since they need no vacuum history to establish.

**Tested both ways, and the rule survived.** s10 opens the session before the updates and s11 opens it
after; both tables have never been vacuumed.

- **Without a vacuum the two cannot be told apart, so the rule is right not to guess.** Both read
  "never vacuumed", both have the session present, and `pgstattuple` measures the same
  [100,000](../scenarios/evidence/s11_never_vacuumed_holder_after.pg18.txt) dead rows ([47.07%](../scenarios/evidence/s11_never_vacuumed_holder_after.pg18.txt)) in s11 as in s10. A rule that named the session as
  the cause would have been right in s10 and wrong in s11, with the same evidence.
- **Following the instruction settles it.** In s10, VACUUM (VERBOSE) removed [0](../scenarios/evidence/s10_never_vacuumed_holder_before.pg18.txt) and left
  [100,000](../scenarios/evidence/s10_never_vacuumed_holder_before.pg18.txt) dead but not yet removable: the session binds. In s11 it removed all
  [100,000](../scenarios/evidence/s11_never_vacuumed_holder_after.pg18.txt): opened after the updates committed, the session's snapshot already sees them as
  dead, so it binds nothing.

**The vacuumed case is now a fixture too.** s16 gives the table a prior vacuum, then makes new dead
rows, then opens the holder after them. The vacuum finished before the holder, so it cannot say
whether the holder binds the newer rows: the finding keeps the next cause as primary and puts the
holder under unknowns as "not established", saying "this table has not been vacuumed since it
began". VACUUM (VERBOSE) then removes all 100,000 dead rows, proving the holder did not bind. The
scenario passes on PostgreSQL 14 to 19; evidence is committed under
[scenarios/evidence](../scenarios/evidence/).
