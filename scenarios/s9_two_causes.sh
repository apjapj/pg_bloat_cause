#!/usr/bin/env bash
# s9: two causes at once, to pin down the ranking. s9_orders has autovacuum disabled AND a session
# holds the horizon. The horizon holder should rank first: while it exists nothing else is fixable,
# since even a manual VACUUM removes nothing. Re-enabling autovacuum alone would change nothing.
. "$(dirname "$0")/lib.sh"
setup_schema
make_table s9_orders 100000 "WITH (autovacuum_enabled = false)"
start_holder s9 "SELECT txid_current();"
psql_q -c "UPDATE $SCHEMA.s9_orders SET status = 'paid'"
settle_stats

usual_query s9_orders
measured s9_orders
vacuum_says s9_orders
say "evidence: both causes"
psql -X -P pager=off -c "
SELECT 'horizon holder' AS cause, application_name AS what, age(backend_xid)::text AS how_much
  FROM pg_stat_activity WHERE application_name = 'bloat_scen_s9'
UNION ALL
SELECT 'autovacuum off', relname, array_to_string(reloptions, ',')
  FROM pg_class WHERE oid = '$SCHEMA.s9_orders'::regclass"
finding s9_orders
assert_finding s9_orders 'horizon holder' '%autovacuum is disabled%' '' 'held back by session %bloat_scen_s9%'
expected "rank 1: held back by session bloat_scen_s9 (a manual VACUUM above removed nothing).
  rank 2: autovacuum disabled on s9_orders, which matters only once the holder is gone."
