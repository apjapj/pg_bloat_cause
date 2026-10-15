#!/usr/bin/env bash
# s15: bloat_cause_measure() on a real bloated table, both modes, against the estimate.
#
# Why a scenario and not only the pgTAP assertions. Those run on a small synthetic table and check
# the contract: the modes, the errors, and the unprivileged refusals. What they cannot check is that
# the measurement reads a real heap and reports something a person would recognise as the answer,
# beside the estimate the rest of this extension reports for the same table. That is what this does.
#
# pgstattuple is required here. Its absence is covered in the pgTAP file by dropping the extension,
# which is smaller than a second CI matrix leg and is not the same thing; the matrix is still open.
. "$(dirname "$0")/lib.sh"

# A local assertion, because this repository's lib.sh has no generic one: run.sh fails a scenario on a
# line beginning "  FAIL  " or a non-zero exit, and nothing else. The first version of this scenario
# called assert_true, which exists in pg_limit_runway and NOT here, so every assertion printed
# "command not found" and the scenario still reported "ran". That is the false green this helper is for.
check() {  # $1 description, $2 t or f
    if [ "$2" = t ]; then note "PASS  $1"; else note "FAIL  $1"; fi
}
setup_schema
has_extension || exit 0
[ -n "$(val "SELECT 1 FROM pg_available_extensions WHERE name = 'pgstattuple'")" ] \
    || skip "pgstattuple is not available on this server"

# autovacuum off and a low fillfactor, so the dead rows stay put and are not cleaned mid-scenario.
make_table s15_orders 20000 "WITH (autovacuum_enabled = false, fillfactor = 50)"
psql_q -c "UPDATE $SCHEMA.s15_orders SET status = 'paid' WHERE id % 2 = 0"
psql_q -c "ANALYZE $SCHEMA.s15_orders"

say "the measurement, both modes"
psql -X -P pager=off -c "
SELECT mode, dead_rows, live_rows, dead_bytes, dead_pct, dead_rows_source
  FROM (VALUES ('approx'), ('exact')) AS m(mode),
       LATERAL bloat_cause_measure('$SCHEMA', 's15_orders', m.mode)"

say "the estimate for the same table, for comparison"
psql -X -P pager=off -c "
SELECT relname, dead_rows, dead_pct, dead_rows_source
  FROM bloat_cause_findings(interval '1 second') WHERE relname = 's15_orders'"

say "checks"
check "approx reports dead_rows_source = measured" \
    "$([ "$(val "SELECT dead_rows_source FROM bloat_cause_measure('$SCHEMA','s15_orders','approx')")" = 'measured' ] \
       && echo t || echo f)"
# The figure itself, not only the label: a mode that returned the label and a zero would pass a check
# on the label alone, which is the shape of assertion this repository has been bitten by before.
check "and reports a positive count of dead rows, not a zero with a confident label" \
    "$([ "$(val "SELECT dead_rows > 0 FROM bloat_cause_measure('$SCHEMA','s15_orders','approx')")" = t ] && echo t || echo f)"
check "exact also reports measured, and a positive count" \
    "$([ "$(val "SELECT (dead_rows > 0) AND dead_rows_source = 'measured' FROM bloat_cause_measure('$SCHEMA','s15_orders','exact')")" = t ] && echo t || echo f)"
# The two modes count the same thing and should agree closely on a table nothing is writing to. Not
# exactly: approx reads only the pages the visibility map does not cover, and one update per page here
# means it can miss a page whose only dead tuple is on an all-visible one. A disagreement by more than
# a few percent would mean one of them is reading the wrong heap, which is worth failing on.
check "the two modes agree within 5 percent on an idle table" \
    "$(val "SELECT abs(a.dead_rows - e.dead_rows) <= 0.05 * greatest(a.dead_rows, e.dead_rows, 1)
             FROM bloat_cause_measure('$SCHEMA','s15_orders','approx') a,
                  bloat_cause_measure('$SCHEMA','s15_orders','exact') e")"
# And the estimate the rest of the extension reports is in the same country as the measurement. This
# is the assertion that would catch the measurement reading a different table or a different schema.
check "the measured count is within a factor of two of the estimate, so they are the same table" \
    "$(val "SELECT m.dead_rows BETWEEN 0.5 * f.dead_rows AND 2 * f.dead_rows
             FROM bloat_cause_measure('$SCHEMA','s15_orders') m,
                  (SELECT dead_rows FROM bloat_cause_findings(interval '1 second') WHERE relname = 's15_orders') f")"

expected "measured dead rows for one table, with dead_rows_source = 'measured', agreeing between
  approx and exact on an idle table and landing near the estimate the findings report. The absence of
  pgstattuple is a pgTAP case, not this one."
