#!/usr/bin/env bash
# s6: autovacuum is on, but the table's own threshold is set so high that a hot table never reaches
# it. Distinct from s5 because the table looks enabled, and from a horizon holder because a manual
# VACUUM would clean it.
. "$(dirname "$0")/lib.sh"
setup_schema
# The insert threshold is raised too, and the first draft found out why the hard way: with only the
# vacuum threshold set, the 100,000-row load tripped the INSERT-based trigger (13 and later,
# autovacuum_vacuum_insert_threshold + insert_scale_factor x rows), autovacuum ran inside the wait, and
# it removed the update's dead rows along with everything else. So a "threshold too high" finding has
# to read both thresholds, because either one firing cleans the table.
make_table s6_orders 100000 "WITH (autovacuum_vacuum_threshold = 5000000, autovacuum_vacuum_scale_factor = 0.5, autovacuum_vacuum_insert_threshold = 5000000, autovacuum_vacuum_insert_scale_factor = 0.5)"
for round in 1 2 3; do
    psql_q -c "UPDATE $SCHEMA.s6_orders SET status = 'round $round' WHERE id % 3 <> 0"
done
naptime=$(val "SELECT setting::int FROM pg_settings WHERE name = 'autovacuum_naptime'")
note "waiting $((naptime * 4)) s, four autovacuum naptimes"
sleep $((naptime * 4))

usual_query s6_orders
measured s6_orders
say "evidence: the table's threshold against its dead rows"
psql -X -P pager=off -c "
SELECT c.relname, c.reloptions, s.n_dead_tup, s.autovacuum_count,
       coalesce((SELECT option_value::int FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_vacuum_threshold'),
                current_setting('autovacuum_vacuum_threshold')::int)
       + coalesce((SELECT option_value::float8 FROM pg_options_to_table(c.reloptions) WHERE option_name = 'autovacuum_vacuum_scale_factor'),
                  current_setting('autovacuum_vacuum_scale_factor')::float8) * c.reltuples AS would_trigger_at
  FROM pg_class c JOIN pg_stat_user_tables s ON s.relid = c.oid
 WHERE s.schemaname = '$SCHEMA' AND c.relname = 's6_orders'"
expected "autovacuum is enabled but s6_orders' own threshold (5,000,000 + 0.5 x rows) is far above
  its dead rows, so it never triggers. The fix is to reset or lower the per-table thresholds."
