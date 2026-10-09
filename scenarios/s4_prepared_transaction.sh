#!/usr/bin/env bash
# s4: an orphaned prepared transaction. It survives disconnects and restarts and holds the horizon
# like s1, but there is no session to terminate: ROLLBACK PREPARED is the fix.
. "$(dirname "$0")/lib.sh"
[ "$(val "SHOW max_prepared_transactions")" -gt 0 ] || skip "max_prepared_transactions is 0"
setup_schema
# autovacuum off on the table: an autovacuum running during the hold is timing, and it made
# last_autovacuum differ between two otherwise identical runs. The evidence is the manual VACUUM.
make_table s4_orders 100000 "WITH (autovacuum_enabled = false)"
psql_q -c "BEGIN" -c "SELECT txid_current()" -c "PREPARE TRANSACTION 'bloat_scen_gxid'" >/dev/null
psql_q -c "UPDATE $SCHEMA.s4_orders SET status = 'paid'"
settle_stats

usual_query s4_orders
measured s4_orders
vacuum_says s4_orders
say "evidence: the prepared transaction"
psql -X -P pager=off -c "
SELECT gid, transaction, age(transaction) AS xid_age, prepared, now() - prepared AS open_for, owner
  FROM pg_prepared_xacts WHERE gid = 'bloat_scen_gxid'"
finding s4_orders
assert_finding s4_orders 'horizon holder' '%autovacuum is disabled%' '' "held back by prepared transaction 'bloat_scen_gxid'%"
expected "held back by prepared transaction bloat_scen_gxid. No session to cancel: the fix is
  ROLLBACK PREPARED 'bloat_scen_gxid' (or COMMIT PREPARED if it should have committed)."
