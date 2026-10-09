#!/usr/bin/env bash
# s1: a session idle in transaction holds the xmin horizon, so VACUUM cannot remove dead rows from
# ANY table, however often it runs. Expected cause: the horizon holder, by name and age.
. "$(dirname "$0")/lib.sh"
setup_schema
make_table s1_orders 100000
# The holder takes an xid BEFORE the updates, which is what pins the horizon below them.
start_holder s1 "SELECT txid_current();"
psql_q -c "UPDATE $SCHEMA.s1_orders SET status = 'paid'"
settle_stats

usual_query s1_orders
measured s1_orders
vacuum_says s1_orders
say "evidence: who holds the horizon"
psql -X -P pager=off -c "
SELECT pid, application_name, state, backend_xid, backend_xmin,
       age(backend_xid) AS xid_age, now() - xact_start AS open_for
  FROM pg_stat_activity WHERE application_name = 'bloat_scen_s1'"
expected "held back by session bloat_scen_s1, idle in transaction since the updates. VACUUM removes
  nothing until it ends; terminating it is the fix, VACUUM is not."
