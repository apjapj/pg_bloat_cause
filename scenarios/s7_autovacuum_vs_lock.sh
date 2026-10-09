#!/usr/bin/env bash
# s7: autovacuum and a lock. The README expected an autovacuum worker WAITING on the lock. That is
# only half true, and this scenario shows both halves:
#
#   part 1, an ordinary autovacuum: it does not wait. It asks for the lock without waiting and, if it
#     cannot have it, skips the table and tries again next naptime. Nothing appears in pg_stat_activity;
#     the evidence is a stale last_autovacuum and, with log_autovacuum_min_duration >= 0, a
#     "skipping vacuum ... lock not available" line in the server log.
#   part 2, an anti-wraparound autovacuum: it does wait, visibly, with wait_event_type = Lock. Forced
#     here with a per-table autovacuum_freeze_max_age of 100,000 and 110,000 burned xids.
#
# The lock holder takes SHARE UPDATE EXCLUSIVE and no xid, so it holds no horizon: the only thing
# stopping cleanup is the lock.
. "$(dirname "$0")/lib.sh"
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
setup_schema
# autovacuum_freeze_max_age is set here, at creation, and not in part 2: changing a reloption takes the
# same SHARE UPDATE EXCLUSIVE lock the holder has, so the first draft blocked on its own holder.
# 100,000 is the lowest value allowed, and on a fresh table age(relfrozenxid) is far below it, so part 1
# is still an ordinary autovacuum.
make_table s7_orders 100000 "WITH (autovacuum_vacuum_threshold = 50, autovacuum_vacuum_scale_factor = 0.01, autovacuum_freeze_max_age = 100000)"
start_holder s7 "LOCK TABLE $SCHEMA.s7_orders IN SHARE UPDATE EXCLUSIVE MODE;"
psql_q -c "UPDATE $SCHEMA.s7_orders SET status = 'paid'"
naptime=$(val "SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_naptime'")
note "part 1: waiting $((naptime * 4)) s for an ordinary autovacuum to try the table"
sleep $((naptime * 4))

usual_query s7_orders
say "evidence, part 1: autovacuum workers on this table right now (expected: none)"
psql -X -P pager=off -c "
SELECT pid, backend_type, wait_event_type, wait_event, left(query, 70) AS query
  FROM pg_stat_activity WHERE backend_type = 'autovacuum worker'"
say "evidence, part 1: the server log, if this is one of the scenario containers"
if [ -n "${BC_CONTAINER:-}" ]; then
    docker logs --since "$SINCE" "$BC_CONTAINER" 2>&1 | grep -c 'skipping vacuum of "s7_orders" --- lock not available' \
        | sed 's/^/  "skipping vacuum of s7_orders --- lock not available" lines: /'
else
    note "BC_CONTAINER not set, log not read"
fi

say "part 2: forcing an anti-wraparound autovacuum"
psql_q -c "CREATE OR REPLACE PROCEDURE $SCHEMA.burn_xids(n int) LANGUAGE plpgsql AS \$\$
BEGIN FOR i IN 1..n LOOP PERFORM txid_current(); COMMIT; END LOOP; END \$\$" -c "CALL $SCHEMA.burn_xids(110000)"
# The fact that matters, not the raw age: the raw value moved by one xid between two runs (110,005 and
# 110,006), which made the evidence differ for no reason anyone cares about.
note "age(relfrozenxid) is at least 110,000 xids, over the table's autovacuum_freeze_max_age of 100,000: $(val "SELECT age(relfrozenxid) >= 110000 FROM pg_class WHERE oid = '$SCHEMA.s7_orders'::regclass")"
sleep $((naptime * 3))
say "evidence, part 2: autovacuum workers now"
psql -X -P pager=off -c "
SELECT pid, wait_event_type, wait_event, left(query, 80) AS query
  FROM pg_stat_activity WHERE backend_type = 'autovacuum worker'"
expected "part 1: autovacuum skipped s7_orders because session bloat_scen_s7 holds a conflicting
  lock; invisible except as a stale last_autovacuum and a log line. Part 2: an anti-wraparound
  autovacuum waits on the same lock, visibly. Either way the fix is to end the lock holder."
