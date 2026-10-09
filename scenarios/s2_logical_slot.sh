#!/usr/bin/env bash
# s2: an inactive logical replication slot. The README's headline example blames one for user-table
# bloat. This scenario tests that claim: a logical slot holds catalog_xmin, which protects CATALOG
# rows, and its data xmin is NULL. So it should hold back pg_class / pg_attribute churn, and NOT the
# dead rows of an ordinary table. Needs wal_level = logical.
. "$(dirname "$0")/lib.sh"
[ "$(val "SHOW wal_level")" = logical ] || skip "wal_level is $(val "SHOW wal_level"), and a logical slot needs logical"
setup_schema
psql_q -c "SELECT pg_create_logical_replication_slot('bloat_scen_slot', 'test_decoding')" >/dev/null
# autovacuum off on this table, so the manual VACUUM below is the only thing that can remove its dead
# rows and the evidence says the same thing every run. Without it, autovacuum reached the table first in
# one of two runs: the conclusion was the same (nothing held them back) but the capture was not.
make_table s2_orders 100000 "WITH (autovacuum_enabled = false)"
psql_q -c "UPDATE $SCHEMA.s2_orders SET status = 'paid'"
# The catalog's own dead rows, before the churn. pg_attribute also collects dead rows from whatever else
# the cluster does after the slot is created, and that number moved between runs (6,000 and 6,021). So
# the scenario clears what it can first and reports only the rows its own churn added.
psql_q -c "VACUUM pg_catalog.pg_attribute"
before=$(val "SELECT dead_tuple_count FROM pgstattuple('pg_catalog.pg_attribute')")
# Catalog churn: each temporary table adds and then deletes rows in pg_class, pg_attribute, pg_type.
psql_q -c "DO \$\$ BEGIN FOR i IN 1..300 LOOP EXECUTE 'CREATE TEMP TABLE bloat_scen_tmp (a int, b text, c text); DROP TABLE bloat_scen_tmp'; END LOOP; END \$\$"
settle_stats

usual_query s2_orders
measured s2_orders
vacuum_says s2_orders
say "VACUUM (VERBOSE) pg_catalog.pg_attribute"
psql -X -c "SET client_min_messages = info" -c "VACUUM (VERBOSE) pg_catalog.pg_attribute" 2>&1 \
    | grep -E 'tuples: |removable cutoff|oldest xmin|found [0-9]+ removable' | head -2 | sed 's/^/  pg_attribute /'
after=$(val "SELECT dead_tuple_count FROM pgstattuple('pg_catalog.pg_attribute')")
note "dead rows in pg_attribute that VACUUM left, added by the 300 temporary-table cycles: $((after - before))"
say "evidence: the slot"
psql -X -P pager=off -c "
SELECT slot_name, slot_type, active, xmin, catalog_xmin, age(catalog_xmin) AS catalog_xmin_age
  FROM pg_replication_slots WHERE slot_name = 'bloat_scen_slot'"
expected "NOT the user table: s2_orders' dead rows are removable. The slot holds back catalog rows
  only (pg_attribute above), and the WAL it retains. A finding that blames it for a user table is wrong."
