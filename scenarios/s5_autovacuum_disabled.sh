#!/usr/bin/env bash
# s5: autovacuum_enabled = false on one table. Dead rows accumulate past every threshold and nothing
# runs. A control table with default settings, changed the same way, shows autovacuum is otherwise
# working. Waits for autovacuum: a few naptimes.
. "$(dirname "$0")/lib.sh"
setup_schema
make_table s5_orders 100000 "WITH (autovacuum_enabled = false)"
make_table s5_control 100000
psql_q -c "UPDATE $SCHEMA.s5_orders SET status = 'paid' WHERE id % 2 = 0" \
       -c "UPDATE $SCHEMA.s5_control SET status = 'paid' WHERE id % 2 = 0"
naptime=$(val "SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_naptime'")
note "waiting $((naptime * 4)) s, four autovacuum naptimes, for the control table to be vacuumed"
sleep $((naptime * 4))

# The read below is of a cumulative statistic: settle it rather than assume the long sleep covered
# the stats collector's own cadence.
settle_stats
usual_query s5_orders,s5_control
measured s5_orders,s5_control
say "evidence: the reloption and the trigger threshold"
psql -X -P pager=off -c "
SELECT c.relname, c.reloptions, s.n_dead_tup,
       current_setting('autovacuum_vacuum_threshold')::int
         + current_setting('autovacuum_vacuum_scale_factor')::float8 * c.reltuples AS would_trigger_at
  FROM pg_class c JOIN pg_stat_user_tables s ON s.relid = c.oid
 WHERE s.schemaname = '$SCHEMA' AND c.relname IN ('s5_orders', 's5_control') ORDER BY 1"
finding s5_orders
assert_finding s5_orders 'autovacuum disabled' '' '' '%50000 dead rows against a threshold of 20050%'
finding s5_control
assert_finding s5_control none
expected "autovacuum is switched off for s5_orders (autovacuum_enabled=false); s5_control, changed
  identically, was vacuumed. The fix is ALTER TABLE ... RESET (autovacuum_enabled), then VACUUM."
