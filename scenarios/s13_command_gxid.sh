#!/usr/bin/env bash
# s13: bloat_cause_command() for a prepared transaction, which is ROLLBACK PREPARED.
#
# Its own scenario, not part of s12, because findings() joins the oldest holder ON true: one holder
# governs every table in the cluster. A scenario holding a session open would keep that session as the
# cause for this table too, and the assertion would fail for the wrong reason. s4 already has this
# fixture and it is reused verbatim: a transaction that takes an xid before the updates, prepared, so
# it survives and holds the horizon with no session left to cancel.
#
# The difference from s4, which is the point: s4 asserts the SENTENCE. This asserts the STATEMENT, and
# then runs it. Running it is the only way to know it is valid SQL rather than plausible text, and
# that check caught a real bug while the command was being written.
. "$(dirname "$0")/lib.sh"
[ "$(val "SHOW max_prepared_transactions")" -gt 0 ] || skip "max_prepared_transactions is 0"
setup_schema
has_extension || exit 0

make_table s13_orders 100000 "WITH (autovacuum_enabled = false)"
psql_q -c "BEGIN" -c "SELECT txid_current()" -c "PREPARE TRANSACTION 'bloat_scen_s13_gxid'" >/dev/null
psql_q -c "UPDATE $SCHEMA.s13_orders SET status = 'paid'"
settle_stats
usual_query s13_orders
measured s13_orders
vacuum_says s13_orders

say "evidence: the prepared transaction"
psql -X -P pager=off -c "
SELECT gid, transaction, age(transaction) AS xid_age, prepared, now() - prepared AS open_for, owner
  FROM pg_prepared_xacts WHERE gid = 'bloat_scen_s13_gxid'"

finding s13_orders
assert_finding s13_orders 'horizon holder' '%autovacuum is disabled%' '' "held back by prepared transaction 'bloat_scen_s13_gxid'%"

say "the statement for it"
got=$(val "SELECT coalesce(command, '') FROM bloat_cause_command(interval '2 seconds', 1000) WHERE relname = 's13_orders'")
want="ROLLBACK PREPARED 'bloat_scen_s13_gxid';"
if [ -z "$got" ]; then
    note "FAIL  no command row for a prepared holder"
elif [ "$(val "SELECT \$\$$got\$\$ = \$\$$want\$\$")" != t ]; then
    note "FAIL  command is '$got', expected exactly '$want'"
else
    note "PASS  s13_orders: $got"
fi

# There is no pid to cancel here, so the statement must not name one. A statement that emitted
# pg_cancel_backend for a prepared transaction would be the worst possible answer: it looks like a
# fix and there is no backend to act on.
if [ "$(val "SELECT count(*) FROM bloat_cause_command() WHERE relname = 's13_orders' AND command LIKE '%pg_cancel_backend%'")" = 0 ]; then
    note "PASS  the statement does not try to cancel a session that does not exist"
else
    note "FAIL  the statement names a session; a prepared transaction has no backend to cancel"
fi

say "what it loses, in the same row"
losses=$(val "SELECT coalesce(loses,'') FROM bloat_cause_command(interval '2 seconds', 1000) WHERE relname = 's13_orders'")
if [ "$(val "SELECT \$\$$losses\$\$ LIKE '%releases everything it holds%'")" = t ]; then
    note "PASS  s13_orders: $losses"
else
    note "FAIL  s13_orders: loses is '$losses', expected it to name what is released"
fi

say "running the statement, which is the only proof it is valid SQL"
if psql_q -c "$got" >/dev/null 2>&1; then
    left=$(val "SELECT count(*) FROM pg_prepared_xacts WHERE gid = 'bloat_scen_s13_gxid'")
    if [ "$left" = 0 ]; then note "PASS  it ran and the prepared transaction is gone"
    else note "FAIL  it ran but bloat_scen_s13_gxid is still there"; fi
else
    note "FAIL  the statement did not run: $got"
fi

expected "ROLLBACK PREPARED 'bloat_scen_s13_gxid', because a prepared transaction has no session to
  cancel and nothing else ends it. The statement is executed here, not merely compared, so that a
  malformed one fails the scenario rather than being read and believed."