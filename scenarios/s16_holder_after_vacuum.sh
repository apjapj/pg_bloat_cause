#!/usr/bin/env bash
# s16: a table WITH a prior vacuum, then new dead rows, then a holder opened after them.
# docs/ranking.md's open case: the holder is present but there is no evidence it binds. A vacuum
# finished before the holder began, so the finding must not name the holder as the primary cause; it
# belongs under unknowns as "not established", and VACUUM (VERBOSE) proves it does not bind.
. "$(dirname "$0")/lib.sh"
setup_schema
# autovacuum off, so the only vacuum this table has is the one below.
make_table s16_orders 100000 "WITH (autovacuum_enabled = false)"
# The prior vacuum: it sets last_vacuum on a table with no dead rows, so the comparison is against a
# vacuum that provably had nothing to remove. It is before the holder and before the dead rows.
psql_q -c "VACUUM (ANALYZE) $SCHEMA.s16_orders"
# The only dead rows, made after that vacuum and before the holder.
psql_q -c "UPDATE $SCHEMA.s16_orders SET status = 'paid'"
start_holder s16 "SELECT txid_current();"
settle_stats

say "part 1: a vacuum exists, but before the holder"
usual_query s16_orders
measured s16_orders
val "SELECT '  last vacuum: ' || coalesce(greatest(last_vacuum, last_autovacuum)::text, 'never')
       FROM pg_stat_user_tables WHERE relid = '$SCHEMA.s16_orders'::regclass"
val "SELECT '  holder started: ' || xact_start
       FROM pg_stat_activity WHERE application_name = 'bloat_scen_s16'"
note "finding: the holder is present, but the vacuum that finished before it cannot say whether it"
note "binds these newer rows. The primary cause is the next one down; the holder is in unknowns."

finding s16_orders
assert_finding s16_orders 'autovacuum disabled' '' '%bloat_scen_s16%not been vacuumed since it began%'

say "part 2: the finding's instruction, followed"
vacuum_says s16_orders
finding s16_orders
assert_finding s16_orders none
expected "part 1 does NOT name the holder as the primary cause: the prior vacuum predates it, so binding
  is not established and the holder is reported under unknowns. Part 2 shows it does not bind: VACUUM
  removes every dead row. This is the vacuumed counterpart to s11's never-vacuumed table."
