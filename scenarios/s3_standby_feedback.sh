#!/usr/bin/env bash
# s3: a physical standby with hot_standby_feedback = on and a long query on the standby holds the
# primary's horizon. The primary never sees the query; it sees the standby's xmin, and this scenario
# checks WHERE it sees it: the walsender's backend_xmin, or the xmin of the standby's physical slot.
#
# Needs a hot standby of this server: set BC_STANDBY_PORT to its port (same host, user and password).
# scenarios/standby.sh builds a primary/standby pair from the matrix image.
. "$(dirname "$0")/lib.sh"
[ -n "${BC_STANDBY_PORT:-}" ] || skip "set BC_STANDBY_PORT to a hot standby of this server (scenarios/standby.sh builds one)"
sby() { PGPORT=$BC_STANDBY_PORT psql -X -At -v ON_ERROR_STOP=1 -c "$1"; }
[ "$(sby "SELECT pg_is_in_recovery()")" = t ] || skip "port $BC_STANDBY_PORT is not a standby"
[ "$(sby "SHOW hot_standby_feedback")" = on ] || skip "the standby has hot_standby_feedback off, so it cannot hold the primary's horizon"

# This scenario pins the standby's slot on purpose, so the shared wait for feedback to catch up would
# only ever time out.
export BC_NO_FEEDBACK_WAIT=1
setup_schema
# autovacuum off on the table, as in s2, so the manual VACUUM is the only thing acting on it.
make_table s3_orders 100000 "WITH (autovacuum_enabled = false)"
for _ in $(seq 1 50); do [ "$(sby "SELECT to_regclass('$SCHEMA.s3_orders') IS NOT NULL")" = t ] && break; sleep 0.2; done

# The long query, on the standby: a REPEATABLE READ snapshot taken and then left open.
printf "SET application_name = 'bloat_scen_s3';\nBEGIN ISOLATION LEVEL REPEATABLE READ;\nSELECT count(*) FROM %s.s3_orders;\n\\\\! sleep 86400\n" "$SCHEMA" \
    | PGPORT=$BC_STANDBY_PORT psql -X -q >/dev/null 2>&1 &
echo $! > "$RUNDIR/holder_s3.pid"
for _ in $(seq 1 50); do
    [ "$(sby "SELECT count(*) FROM pg_stat_activity WHERE application_name = 'bloat_scen_s3' AND state = 'idle in transaction'")" = 1 ] && break
    sleep 0.2
done

# Feedback travels at wal_receiver_status_interval (10 s by default), so wait until the primary holds
# an xmin at or below the xid taken here, from either place it might appear.
x=$(val "SELECT txid_current()")
for _ in $(seq 1 100); do
    [ "$(val "SELECT coalesce(
               (SELECT min(xmin::text::bigint) FROM pg_replication_slots WHERE slot_type = 'physical' AND xmin IS NOT NULL),
               (SELECT min(backend_xmin::text::bigint) FROM pg_stat_replication), $x + 1) <= $x")" = t ] && break
    sleep 0.2
done
psql_q -c "UPDATE $SCHEMA.s3_orders SET status = 'paid'"
settle_stats

usual_query s3_orders
measured s3_orders
vacuum_says s3_orders
say "evidence on the primary: where the standby's horizon shows"
val "SELECT '  walsender ' || application_name || ': ' || state || ', backend_xmin '
            || CASE WHEN backend_xmin IS NULL THEN 'NULL' ELSE 'set' END FROM pg_stat_replication"
val "SELECT '  slot ' || slot_name || ': ' || slot_type || ', active ' || active || ', xmin '
            || CASE WHEN xmin IS NULL THEN 'NULL' ELSE 'set, xmin age ' || age(xmin) END
       FROM pg_replication_slots WHERE slot_type = 'physical'"
say "evidence on the standby: the query holding it"
sby "SELECT '  standby session ' || application_name || ': ' || state || ', backend_xmin '
            || CASE WHEN backend_xmin IS NULL THEN 'NULL' ELSE 'set' END
       FROM pg_stat_activity WHERE application_name = 'bloat_scen_s3'"
# Part 2, the control: end the standby's query and VACUUM again. If the standby merely existing were
# enough to hold the rows, this would still remove nothing. It is the query, so it should remove them
# all once the slot's xmin has moved past the updates.
say "part 2: end the query on the standby, wait for feedback, VACUUM again"
for f in "$RUNDIR"/holder_s3.pid; do pkill -P "$(cat "$f")" 2>/dev/null; kill "$(cat "$f")" 2>/dev/null; rm -f "$f"; done
y=$(val "SELECT txid_current()")
for _ in $(seq 1 150); do
    [ "$(val "SELECT coalesce((SELECT min(xmin::text::bigint) FROM pg_replication_slots WHERE slot_type = 'physical' AND xmin IS NOT NULL), $y) >= $y")" = t ] && break
    sleep 0.2
done
note "slot xmin has moved past the updates: $(val "SELECT min(xmin::text::bigint) >= $y FROM pg_replication_slots WHERE slot_type = 'physical'")"
vacuum_says s3_orders
expected "held back by standby $(val "SELECT application_name FROM pg_stat_replication LIMIT 1") through its physical slot,
  because of a query open ON THE STANDBY. The fix is on the standby: end that query, or turn
  hot_standby_feedback off and accept query cancellations there instead. Part 2 shows it: with the
  query ended and nothing else changed, the same VACUUM removes every dead row."
