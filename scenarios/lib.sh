# scenarios/lib.sh: shared helpers for the pg_bloat_cause scenario fixtures. Sourced, not run.
#
# Every scenario builds real bloat in schema bloat_scen and leaves it in place, together with whatever
# is causing it (a session, a slot, a prepared transaction, a reloption). scenarios/teardown.sh removes
# all of it. Connection comes from the usual libpq variables; a superuser is needed for slots,
# prepared transactions and pg_terminate_backend.
#
# The horizon holders pin the whole cluster, not one database, so run these against a scratch server.
set -uo pipefail

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGUSER PGDATABASE

SCHEMA=bloat_scen
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
RUNDIR="$HERE/.run/${PGHOST}_${PGPORT:-5432}"
mkdir -p "$RUNDIR"
# The order rules live once, in pg-dev-infra, vendored as scripts/order-rules.sh. val() uses the exact
# rule, where the row count is known; check-examples.sh (where a repository has one) uses the plan rule.
. "$HERE/../scripts/order-rules.sh"

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
# The exact nondeterministic-order rule, where the row count is known, judged by order-rules.sh. The
# warning goes to a side file, never to stdout or stderr, because run.sh captures both into the
# evidence. run.sh reads the file.
val() {
    local sql=$1 out
    out=$(psql -X -At -v ON_ERROR_STOP=1 -c "$sql")
    [ -n "$(order_val_multirow "$sql" "$out")" ] && \
        printf '%s\t%s\n' "${LR_SCENARIO:-?}" "$(printf '%s' "$sql" | tr '\n\t' '  ' | cut -c1-120)" \
            >> "$RUNDIR/order-warnings"
    printf '%s\n' "$out"
}

VER=$(val "SHOW server_version_num")
say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }

# Exit code 3 means skipped, and the reason is printed. run.sh reports it as SKIP, not as a pass.
skip() { printf '\n  SKIP  %s\n' "$1"; exit 3; }

setup_schema() {
    psql_q -c "CREATE SCHEMA IF NOT EXISTS $SCHEMA"
    # pgstattuple is a cross-check the scenarios use, not a dependency of the extension. Create it
    # only when the cluster has it, so the suite runs on a cluster that never installed it; the
    # measured cross-check then reports itself as not established instead of failing.
    if has_pgstattuple; then psql_q -c "CREATE EXTENSION IF NOT EXISTS pgstattuple"; fi
}

# Cumulative statistics are flushed asynchronously: by the stats collector on 14, and by each backend
# at transaction end, at most once a second, on 15 and later. A counter read too early reports the
# state before the writes, so every report waits for them to land.
settle_stats() { sleep 2; wait_for_standby_feedback; }

# A standby with hot_standby_feedback reports its horizon every wal_receiver_status_interval (10 s by
# default), and until it does the primary keeps an OLDER xmin on its slot. Measured on the s3 pairs:
# without this wait, s2's user table showed 100,000 dead rows "not yet removable" in one run of two, and
# s6's in-page pruning removed different amounts (pgstattuple counted 133,334 and 200,001). So before
# measuring, wait until every active physical slot has caught up with the oldest horizon the primary
# itself holds: the current xid, or an older open transaction or prepared transaction where a scenario
# put one. No physical slot means nothing to wait for. s3 pins the slot on purpose and sets
# BC_NO_FEEDBACK_WAIT. Times out after 30 s rather than hang, and says so.
wait_for_standby_feedback() {
    [ -n "${BC_NO_FEEDBACK_WAIT:-}" ] && return 0
    [ "$(val "SELECT count(*) FROM pg_replication_slots WHERE slot_type = 'physical' AND active")" = 0 ] && return 0
    local target i
    target=$(val "SELECT least(txid_current(),
        (SELECT min(backend_xmin::text::bigint) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'),
        (SELECT min(backend_xid::text::bigint) FROM pg_stat_activity WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'),
        (SELECT min(transaction::text::bigint) FROM pg_prepared_xacts))")
    for i in $(seq 1 150); do
        [ "$(val "SELECT coalesce(min(xmin::text::bigint), $target) >= $target FROM pg_replication_slots WHERE slot_type = 'physical' AND active")" = t ] && return 0
        sleep 0.2
    done
    note "standby feedback did not catch up within 30 s; figures below may include its lag"
}

# A session that sits "idle in transaction" until teardown kills it. psql blocks on the shell escape,
# so the server sees an open transaction with nothing running. $1 is a name, $2 the SQL to run first.
start_holder() {
    local name=$1 sql=$2
    printf "SET application_name = 'bloat_scen_%s';\nBEGIN;\n%s\n\\\\! sleep 86400\n" "$name" "$sql" \
        | psql -X -q >/dev/null 2>&1 &
    echo $! > "$RUNDIR/holder_$name.pid"
    local i
    for i in $(seq 1 50); do
        [ "$(val "SELECT count(*) FROM pg_stat_activity
                   WHERE application_name = 'bloat_scen_$name' AND state = 'idle in transaction'")" = 1 ] \
            && return 0
        sleep 0.2
    done
    echo "  holder $name did not reach idle in transaction" >&2
    exit 1
}

# A table of $2 rows with an indexed id and a 100-byte payload, analysed so reltuples is real.
make_table() {
    local t=$1 n=$2 opts=${3:-}
    psql_q -c "DROP TABLE IF EXISTS $SCHEMA.$t" \
           -c "CREATE TABLE $SCHEMA.$t (id int PRIMARY KEY, status text, filler text) ${opts}" \
           -c "INSERT INTO $SCHEMA.$t SELECT g, 'new', repeat('x', 100) FROM generate_series(1, $n) g"
    # ANALYZE in a second session, after the first has exited. A backend flushes its insert counts when
    # it exits, so an ANALYZE in the same session sets n_live_tup and the late flush then adds the
    # inserts again: the first draft reported 200,000 live rows in a 100,000-row table.
    psql_q -c "ANALYZE $SCHEMA.$t"
}

# What most people run first: the dead-row share from the statistics views.
usual_query() {
    say "the usual hand-written query (pg_stat_user_tables)"
    psql -X -P pager=off -c "
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / nullif(n_live_tup + n_dead_tup, 0), 1) AS dead_pct,
       last_autovacuum, last_vacuum
  FROM pg_stat_user_tables
 WHERE schemaname = '$SCHEMA' AND relname = ANY (string_to_array('$1', ','))
 ORDER BY relname"
}

# Measured rather than estimated: pgstattuple reads the whole table. Fine on a fixture.
measured() {
    say "measured (pgstattuple)"
    if ! has_pgstattuple; then
        note "  pgstattuple is not available on this server, so the measured cross-check is not established"
        return 0
    fi
    local t
    for t in ${1//,/ }; do
        psql -X -At -F' ' -c "
SELECT '  $t: ' || tuple_count || ' live rows, ' || dead_tuple_count || ' dead rows, '
       || dead_tuple_percent || '% of the table is dead tuples'
  FROM pgstattuple('$SCHEMA.$t')"
    done
}

# A manual VACUUM VERBOSE, reduced to the line that says what it could not remove. Used only where
# the point is that VACUUM cannot help; elsewhere it would destroy the fixture.
vacuum_says() {
    say "VACUUM (VERBOSE) $1"
    psql -X -c "SET client_min_messages = info" -c "VACUUM (VERBOSE) $SCHEMA.$1" 2>&1 \
        | grep -E 'tuples: |removable cutoff|oldest xmin|found [0-9]+ removable' | head -2 | sed 's/^/  /'
}

expected() { say "expected cause"; note "$1"; }

# ---------------------------------------------------------------- the extension's own finding
#
# When pg_bloat_cause is available on the server, each scenario also prints what the extension says
# about its table and asserts the finding docs/ranking.md predicts. Holders younger than a few seconds
# are ignored by default in the extension (one minute); the scenarios pass 2 seconds, since their
# holders are seconds old. The standby gap stays at the extension's default of 1000 xids except in s3,
# whose standby query pins only a few, which sets BC_STANDBY_XID_GAP. A "FAIL" line makes run.sh
# report the scenario as FAILED.
has_extension() {
    [ "$(val "SELECT count(*) FROM pg_available_extensions WHERE name = 'pg_bloat_cause'")" = 1 ]
}
has_pgstattuple() {
    [ "$(val "SELECT count(*) FROM pg_available_extensions WHERE name = 'pgstattuple'")" = 1 ]
}
finding() {   # $1 table
    has_extension || { note "pg_bloat_cause is not installed on this server; finding not checked"; return 0; }
    sleep 1
    psql_q -c "CREATE EXTENSION IF NOT EXISTS pg_bloat_cause" 2>/dev/null
    say "what pg_bloat_cause says about $1"
    local line
    line=$(val "SELECT t FROM bloat_cause_text(interval '2 seconds', ${BC_STANDBY_XID_GAP:-1000}) t WHERE t LIKE '$1: %'")
    note "${line:-(no finding: $1 does not appear)}"
}
# $1 table, $2 expected cause (or 'none' for no row, or 'null' for a row with no cause),
# $3 a LIKE pattern every "then" must include (or ''), $4 a LIKE pattern "unknowns" must include ('' means
# unknowns must be empty), $5 a LIKE pattern for the cause detail (or '').
assert_finding() {
    has_extension || return 0
    local t=$1 want=$2 thenp=${3:-} unkp=${4:-} detp=${5:-} got
    got=$(val "SELECT coalesce(cause, 'null') || '|' || coalesce(cause_detail, '') || '|'
                      || array_to_string(\"then\", ' ;; ') || '|' || array_to_string(unknowns, ' ;; ')
                 FROM bloat_cause_findings(interval '2 seconds', ${BC_STANDBY_XID_GAP:-1000}) WHERE relname = '$t'")
    local cause=${got%%|*} rest=${got#*|}
    local detail=${rest%%|*}; rest=${rest#*|}
    local thens=${rest%%|*} unks=${rest#*|}
    local bad=""
    if [ -z "$got" ]; then
        [ "$want" = none ] || bad="$bad; no row, expected cause '$want'"
    else
        [ "$want" = none ] && bad="$bad; expected no row, got cause '$cause'"
        [ "$want" != none ] && [ "$cause" != "$want" ] && bad="$bad; cause is '$cause', expected '$want'"
        [ -n "$detp" ] && [ "$(val "SELECT \$\$${detail}\$\$ LIKE \$\$${detp}\$\$")" != t ] && bad="$bad; detail does not match '$detp'"
        [ -n "$thenp" ] && [ "$(val "SELECT \$\$${thens}\$\$ LIKE \$\$${thenp}\$\$")" != t ] && bad="$bad; then does not match '$thenp'"
        if [ -z "$unkp" ]; then [ -n "$unks" ] && bad="$bad; unknowns not empty"
        else [ "$(val "SELECT \$\$${unks}\$\$ LIKE \$\$${unkp}\$\$")" != t ] && bad="$bad; unknowns do not match '$unkp'"; fi
    fi
    if [ -z "$bad" ]; then note "PASS  $t: cause $want${thenp:+, then $thenp}${unkp:+, unknowns $unkp}"
    else note "FAIL  $t${bad}"; fi
}
