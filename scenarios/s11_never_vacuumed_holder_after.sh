#!/usr/bin/env bash
# s11: a table that has NEVER been vacuumed, with a session idle in transaction opened AFTER its
# 100,000 updates. docs/ranking.md's rule for this case: no vacuum, no binding verdict.
#
# Two claims, asserted separately, because the second is what makes the first honest:
#   part 1  without a vacuum, what can be established is only: never vacuumed, a holder is present.
#           The finding says "cause not established", the same for s10 and s11, and that is the
#           point: the extension does not write, so it cannot run the test itself.
#   part 2  following the finding's instruction, VACUUM (VERBOSE), settles it. Here that is expected to
#           show the holder does NOT bind: every dead row is removed.
. "$(dirname "$0")/lib.sh"
setup_schema
# autovacuum off, so the table stays never-vacuumed until part 2 vacuums it by hand.
make_table s11_orders 100000 "WITH (autovacuum_enabled = false)"
psql_q -c "UPDATE $SCHEMA.s11_orders SET status = 'paid'"
start_holder s11 "SELECT txid_current();"
settle_stats

say "part 1: what can be established without a vacuum"
usual_query s11_orders
measured s11_orders
val "SELECT '  never vacuumed: ' || (last_vacuum IS NULL AND last_autovacuum IS NULL)
       FROM pg_stat_user_tables WHERE relid = '$SCHEMA.s11_orders'::regclass"
val "SELECT '  holder present: ' || application_name || ', ' || state
       FROM pg_stat_activity WHERE application_name = 'bloat_scen_s11'"
note "finding: cause not established; the table has never been vacuumed, so it cannot be told"
note "whether session bloat_scen_s11 is holding these rows back. Run VACUUM (VERBOSE) on it."

finding s11_orders
assert_finding s11_orders 'autovacuum disabled' '' '%bloat_scen_s11%not established: this table has never been vacuumed%'
say "part 2: the finding's instruction, followed"
vacuum_says s11_orders
finding s11_orders
assert_finding s11_orders none
expected "part 1 cannot tell, and says the same as s10. Part 2 shows the holder does NOT bind: VACUUM
  removes every dead row. Opened after the updates committed, its snapshot already sees them as dead."
