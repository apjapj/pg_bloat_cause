#!/usr/bin/env bash
# s14: a standby holder produces NO command row at all, and that is the honest answer.
#
# Its own scenario, not part of s12 or s13, because findings() joins the oldest holder ON true: one
# holder governs every table in the cluster. A session holder open elsewhere would win the ordering
# and this table would read as blocked by that session instead, so the assertion would pass or fail
# for the wrong reason. s3 already builds this exact standby fixture and it is reused rather than
# reinvented.
#
# Why no row is correct and a statement would be wrong. The query holding the primary's horizon is
# running on the standby. This side has no pid for it, no session to cancel, and no statement that
# would help: the fix is on the other host. docs/ranking.md rule 3 says the command is for the primary
# only, and bloat_cause_text() already says where the fix is. A plausible-looking statement here would
# be the single worst output this extension could produce, because a reader would paste it, it would
# appear to work, and nothing would have been fixed.
. "$(dirname "$0")/lib.sh"
[ -n "${BC_STANDBY_PORT:-}" ] || skip "set BC_STANDBY_PORT to a hot standby of this server (scenarios/standby.sh builds one)"
sby() { PGPORT=$BC_STANDBY_PORT psql -X -At -v ON_ERROR_STOP=1 -c "$1"; }
[ "$(sby "SELECT pg_is_in_recovery()")" = t ] || skip "port $BC_STANDBY_PORT is not a standby"
[ "$(sby "SHOW hot_standby_feedback")" = on ] || skip "the standby has hot_standby_feedback off, so it cannot hold the primary's horizon"

export BC_NO_FEEDBACK_WAIT=1
export BC_STANDBY_XID_GAP=1
setup_schema
has_extension || exit 0

make_table s14_orders 100000 "WITH (autovacuum_enabled = false)"
for _ in $(seq 1 50); do [ "$(sby "SELECT to_regclass('$SCHEMA.s14_orders') IS NOT NULL")" = t ] && break; sleep 0.2; done

printf "SET application_name = 'bloat_scen_s14';\nBEGIN ISOLATION LEVEL REPEATABLE READ;\nSELECT count(*) FROM %s.s14_orders;\n\\\\! sleep 86400\n" "$SCHEMA" \
    | PGPORT=$BC_STANDBY_PORT psql -X -q >/dev/null 2>&1 &
echo $! > "$RUNDIR/holder_s14.pid"
for _ in $(seq 1 50); do
    [ "$(sby "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'bloat_scen_s14' AND state = 'idle in transaction'")" = 1 ] && break
    sleep 0.2
done

x=$(val "SELECT txid_current()")
for _ in $(seq 1 100); do
    [ "$(val "SELECT coalesce(
                 (SELECT min(xmin::text::bigint) FROM pg_replication_slots WHERE slot_type = 'physical' AND xmin IS NOT NULL),
                 (SELECT min(backend_xmin::text::bigint) FROM pg_stat_replication), $x + 1) <= $x")" = t ] && break
    sleep 0.2
done
psql_q -c "UPDATE $SCHEMA.s14_orders SET status = 'paid'"
settle_stats
usual_query s14_orders
measured s14_orders
vacuum_says s14_orders

say "evidence on the primary: where the standby's horizon shows"
val "SELECT '  slot ' || slot_name || ': ' || slot_type || ', xmin age ' || age(xmin)
           FROM pg_replication_slots WHERE slot_type = 'physical' AND xmin IS NOT NULL"
say "evidence on the standby: the query holding it"
sby "SELECT '  standby session ' || application_name || ': ' || state FROM pg_stat_activity
      WHERE application_name = 'bloat_scen_s14'"

finding s14_orders
assert_finding s14_orders 'horizon holder' '%autovacuum is disabled%' '' 'held back by standby %the fix is there'

say "and no statement is offered for it"
# Counted on relname, and the command is coalesced to '(null)' in the message on purpose. A standby
# row produced by a broken function would have command IS NULL rather than no row at all, so a reader
# pasting commands would see no difference. The test can, and must: "no row" is the intended shape
# and "a row with nothing to say" is the bug, and they differ only in a column a reader never reads.
#
# This assertion was verified by removing bloat_cause_command()'s WHERE clause entirely, which makes
# the standby row survive with a NULL command. It fails with "1 finding but 1 command row(s): (null)".
#
# A note on how that was first attempted and why it proved nothing, because the mistake is easy to
# repeat. Replacing the WHERE with `cause IS DISTINCT FROM 'horizon holder'` leaves s14 green, and for
# an obvious reason: that predicate still excludes every holder row whatever its kind, so the standby
# is excluded for being a holder rather than for being a standby, and the test is measuring the wrong
# clause. Removing the clause is what actually exercises the kind check. Any future change here has
# to be checked the same way, by deleting the thing it is supposed to guard rather than editing it.
n=$(val "SELECT count(*) FROM bloat_cause_command(interval '2 seconds', ${BC_STANDBY_XID_GAP:-1000}) WHERE relname = 's14_orders'")
# The count must be compared against the findings, not against zero alone. "No row" and "no finding"
# are different states, and a test that cannot tell them apart passes for the wrong reason: it did
# once, when removing the exclusion from the function left this check green, because the check only
# ever asked whether the count was 0 and never whether a finding existed to be excluded.
findings=$(val "SELECT count(*) FROM bloat_cause_findings(interval '2 seconds', ${BC_STANDBY_XID_GAP:-1000}) WHERE relname = 's14_orders'")
if [ "$findings" != 1 ]; then
    note "FAIL  the fixture did not produce its finding ($findings rows, expected 1), so the standby case proved nothing"
elif [ "$n" = 0 ]; then
    note "PASS  1 finding, 0 command rows: a standby holder produces no statement"
else
    rows=$(val "SELECT coalesce(command, '(null)') FROM bloat_cause_command(interval '2 seconds', ${BC_STANDBY_XID_GAP:-1000}) WHERE relname = 's14_orders'")
    note "FAIL  1 finding but $n command row(s): $rows. The query is on the other host; this side has nothing to run and must say so by having no row."
fi

# The sentence still says where the fix is. Silence from the command is only honest when the
# sentence is not silent, or the reader is left with nothing at all.
if [ "$(val "SELECT cause_detail LIKE '%the fix is there%' FROM bloat_cause_findings(interval '2 seconds', ${BC_STANDBY_XID_GAP:-1000}) WHERE relname = 's14_orders'")" = t ]; then
    note "PASS  the sentence still says the fix is on the standby"
else
    note "FAIL  the sentence does not say where the fix is, so the command's silence leaves the reader nothing"
fi

expected "no row at all, because the query is on the standby and no statement here would help. The
  sentence still says so, so the reader is told where to look rather than given nothing."