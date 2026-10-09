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

psql_q() { psql -X -q -v ON_ERROR_STOP=1 "$@"; }
val()    { psql -X -At -v ON_ERROR_STOP=1 -c "$1"; }

VER=$(val "SHOW server_version_num")
say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }

# Exit code 3 means skipped, and the reason is printed. run.sh reports it as SKIP, not as a pass.
skip() { printf '\n  SKIP  %s\n' "$1"; exit 3; }

setup_schema() {
    psql_q -c "CREATE SCHEMA IF NOT EXISTS $SCHEMA" -c "CREATE EXTENSION IF NOT EXISTS pgstattuple"
}

# Cumulative statistics are flushed asynchronously: by the stats collector on 14, and by each backend
# at transaction end, at most once a second, on 15 and later. A counter read too early reports the
# state before the writes, so every report waits for them to land.
settle_stats() { sleep 2; }

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
        | grep -E 'tuples: |removable cutoff|oldest xmin' | head -2 | sed 's/^/  /'
}

expected() { say "expected cause"; note "$1"; }
