#!/usr/bin/env bash
# s12: bloat_cause_command() against a real holder, a real prepared transaction and a real standby.
#
# Why this is a scenario and not more pgTAP assertions, which is the whole reason it exists. The
# pgTAP fixture builds one table with autovacuum disabled and can produce exactly one cause. The
# holder and lock branches of bloat_cause_command() are therefore unreachable from inside pg_prove,
# because pg_prove cannot open a second connection to hold a transaction open. Assertions written
# there can only pass: changing the gid handling to plain concatenation passed all 45 of them. That
# was measured, not assumed, and an assertion that cannot fail is worse than none because it reads as
# coverage. Here a session can be held open, so the statements can be checked against reality.
#
# Four things are asserted, and the fourth is the one that would otherwise ship untested:
#   a session holder  -> SELECT pg_cancel_backend(<the live pid>), the pid read back and compared
#   a prepared holder -> ROLLBACK PREPARED '<gid>', and that statement is then EXECUTED
#   a standby holder  -> NO ROW AT ALL, because the query is on the other host
#   every returned statement is run and must parse
#
# The standby case skips without BC_STANDBY_PORT, like s3. That is honest: the CI job builds a pair
# so the check runs there, and a developer without one sees SKIP rather than a silent pass.
. "$(dirname "$0")/lib.sh"

cmd() { val "SELECT coalesce(command, '') FROM bloat_cause_command(interval '2 seconds', ${BC_STANDBY_XID_GAP:-1000}) WHERE relname = '$1'"; }

# assert the returned statement matches a pattern, and say PASS or FAIL. A FAIL line fails the
# scenario in run.sh, so this is a real gate and not a note.
assert_command() {
    local t=$1 want=$2 got bad=""
    got=$(cmd "$t")
    [ -z "$got" ] && bad="no command row for $t"
    if [ -n "$got" ] && [ "$(val "SELECT \$\$$got\$\$ LIKE \$\$$want\$\$")" != t ]; then
        bad="command is '$got', expected to match '$want'"
    fi
    if [ -z "$bad" ]; then note "PASS  $t: command ${got}"
    else note "FAIL  $t: $bad"; fi
}

setup_schema
has_extension || exit 0

# ---------------------------------------------------------------- the session case
make_table s12_orders 100000 "WITH (autovacuum_enabled = false)"
# The holder takes an xid BEFORE the updates, which is what pins the horizon below them. Same ordering
# as s1, and it matters: a holder that starts afterwards does not hold these rows back at all.
start_holder s12 "SELECT txid_current();"
psql_q -c "UPDATE $SCHEMA.s12_orders SET status = 'paid'"
settle_stats
# usual_query and measured first, as s1 does, before the VACUUM. On PG14 this order is what makes
# findings() see the holder: without it the vacuum's effect is not in the statistics yet when the
# assertion runs, h_binds comes out false, and the cause reads 'autovacuum disabled' instead. The
# cause is not wrong there, it is just earlier in the ranking, but the scenario is about the command
# so it needs the holder to be the cause.
usual_query s12_orders
measured s12_orders
vacuum_says s12_orders >/dev/null
finding s12_orders

say "evidence: the holder, and the statement for it"
holder_pid=$(val "SELECT pid FROM pg_stat_activity WHERE application_name = 'bloat_scen_s12' AND state = 'idle in transaction'")
note "  holder pid $holder_pid"
assert_finding s12_orders 'horizon holder' '%autovacuum is disabled%' '' 'held back by session %'
# The pid in the statement is compared against the pid read live, so a statement naming some other
# session fails here. That is the check pgTAP could not make.
assert_command s12_orders "SELECT pg_cancel_backend($holder_pid);"

say "the same row says what it loses"
losses=$(val "SELECT coalesce(loses,'') FROM bloat_cause_command(interval '2 seconds', 1000) WHERE relname = 's12_orders'")
if [ "$(val "SELECT \$\$$losses\$\$ LIKE '%rolled back%'")" = t ]; then note "PASS  s12_orders: loses names the rollback"
else note "FAIL  s12_orders: loses is '$losses', expected it to name the rollback"; fi

say "never terminates, only cancels"
if [ "$(val "SELECT count(*) FROM bloat_cause_command() WHERE command LIKE '%pg_terminate_backend%'")" = 0 ]; then
    note "PASS  no statement offers pg_terminate_backend"
else
    note "FAIL  a statement offers pg_terminate_backend; cancelling is the first tool, not terminating"
fi

# ---------------------------------------------------------------- what this scenario does NOT cover
# The prepared and standby cases are NOT here, and the reason is worth recording because it is the
# same trap twice. findings() joins the oldest holder ON true, so ONE holder governs every table in
# the cluster. bloat_cause_command() mirrors that, correctly. So a scenario that opened a session
# holder and then also prepared a transaction would still see the session as the cause for every
# table, and the prepared and standby assertions would fail for the wrong reason. That is what
# happened on the first run of this file.
#
# The holder cases therefore belong one per scenario, where the holder is the only one in the
# cluster, exactly as s1, s3 and s4 already are. The prepared case is asserted in s13_command_gxid
# and the standby case in s14_command_standby, both of which reuse the fixtures already proven in s4
# and s3 rather than inventing new ones.

# ---------------------------------------------------------------- every statement runs
# The check that caught two real bugs while this function was being written: autovacuum_enabled is not
# a pg_class column, and an adjacent-string-literal statement did not parse. Both looked fine to read.
say "running every statement bloat_cause_command() returns"
n_run=0
cmd=""
# Each command is emitted with a sentinel line after it, so a multi-line command is accumulated and
# executed whole. The previous loop ran one line at a time, which made every multi-line read-back
# fail as incomplete SQL.
while IFS= read -r line; do
    if [ "$line" = "__END_COMMAND__" ]; then
        if [ -n "$cmd" ]; then
            n_run=$((n_run + 1))
            if psql_q -c "$cmd" >/dev/null 2>&1; then note "PASS  ran: $cmd"
            else note "FAIL  did not run: $cmd"; fi
        fi
        cmd=""
    else
        if [ -n "$cmd" ]; then cmd="$cmd"$'\n'"$line"; else cmd="$line"; fi
    fi
done < <(val "SELECT command || E'\n__END_COMMAND__' FROM bloat_cause_command(interval '2 seconds', ${BC_STANDBY_XID_GAP:-1000}) WHERE command IS NOT NULL ORDER BY relname")
note "  $n_run statement(s) executed"

expected "SELECT pg_cancel_backend(<the live pid>), with what it costs in the same row, and every
  statement bloat_cause_command() returns is valid SQL. The prepared and standby cases are s13 and
  s14: one oldest holder governs every table, so they cannot share a scenario with this one."