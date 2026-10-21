#!/usr/bin/env bash
# bench-overhead.sh: what one call to the read side costs, beside a hand-written baseline.
#
# Why this exists. The optional overhead tile needs a number with a fixture under it. This states
# the fixture, takes the median of N calls, and prints the same measurement for the hand-written
# query an operator would otherwise paste, so the cost of the extension is visible rather than
# asserted.
#
# What is measured. `SELECT count(*) FROM bloat_cause_text()` and
# `... bloat_cause_findings()`, run from psql with `\timing on`. That is parse, plan, execute and
# the round trip: a SQL function has no plan cache across separate statements, so this is what a
# person running the command in psql pays. The count(*) keeps the rows the client transfers constant
# as the fixture grows. The median is the warm steady state; the first call in a fresh backend pays
# for cold catalog caches.
#
# The baseline is the hand-written query over pg_stat_user_tables that answers "which tables have
# dead rows" without naming a cause: a smaller question, so it is a floor, not an equal.
#
# The fixture. N user tables, each with 2000 rows updated once and never vacuumed, so each carries
# 2000 dead rows. It creates and drops its own tables, by a name prefix, and nothing else.
#
# Usage:
#   ./scripts/bench-overhead.sh                     # 10 tables, median of 30
#   ./scripts/bench-overhead.sh --tables=50 --repeat=10
#   ./scripts/bench-overhead.sh --keep              # leave the fixture tables behind
#   ./scripts/bench-overhead.sh --force             # required: it creates tables and dead rows
#
# Needs superuser: it disables autovacuum on the fixture tables for the duration.
set -uo pipefail
cd "$(dirname "$0")/.."

: "${PGHOST:=127.0.0.1}"
: "${PGUSER:=postgres}"
: "${PGDATABASE:=postgres}"
export PGHOST PGUSER PGDATABASE

tables=10
repeat=30
keep=0
force=0
prefix=bloat_bench_fixture

while [ "$#" -gt 0 ]; do
    case "$1" in
        --tables=*) tables="${1#*=}" ;;
        --repeat=*) repeat="${1#*=}" ;;
        --keep)     keep=1 ;;
        --force)    force=1 ;;
        -h|--help)  sed -n '2,28p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

if [ "$force" -ne 1 ]; then
    cat >&2 <<'MSG'
  This script creates N tables, writes 2000 dead rows into each, and drops them afterwards, in the
  database named by PGDATABASE. Run it against a scratch database, or pass --force to confirm.
MSG
    exit 2
fi

q() { psql -X -tA -c "$1" 2>/dev/null; }

if [ "$(q "SELECT count(*) FROM pg_extension WHERE extname='pg_bloat_cause'")" != 1 ]; then
    echo "  bloat_cause is not installed in $PGDATABASE on $PGHOST:$PGPORT" >&2
    exit 1
fi

version=$(q "SELECT current_setting('server_version')")
printf '\n  \033[1mpg_bloat_cause read-overhead benchmark\033[0m\n'
printf '  server %s on %s, database %s, median of %s calls\n' "$version" "$PGHOST" "$PGDATABASE" "$repeat"
printf '  fixture: %s tables, 2000 rows each, every row updated once and never vacuumed (2000 dead rows per table)\n\n' "$tables"

# One statement per table keeps the whole fixture in this script, and the prefix makes the cleanup
# name-scoped: nothing but tables this run created is ever dropped.
psql -X -q >/dev/null 2>&1 <<SQL
DO \$do\$
DECLARE i int;
BEGIN
  FOR i IN 1..$tables LOOP
    EXECUTE format('DROP TABLE IF EXISTS ${prefix}_%s', i);
    EXECUTE format('CREATE TABLE ${prefix}_%s (id int PRIMARY KEY, payload text) WITH (autovacuum_enabled = false)', i);
    EXECUTE format('INSERT INTO ${prefix}_%s SELECT g, repeat(''x'', 100) FROM generate_series(1, 2000) g', i);
    EXECUTE format('UPDATE ${prefix}_%s SET payload = payload || ''!''', i);
  END LOOP;
END
\$do\$;
ANALYZE;
SQL

findings=$(q "SELECT count(*) FROM bloat_cause_findings()")
if [ "${findings:-0}" -ne "$tables" ]; then
    # A benchmark that does not check its own fixture is how a quiet cluster gets timed and called a
    # result. Every fixture table must be reported, and as dead, before anything is timed.
    printf '  fixture wrong: bloat_cause_findings() returned %s row(s), wanted %s; refusing to time\n' \
           "${findings:-?}" "$tables" >&2
    for i in $(seq 1 "$tables"); do q "DROP TABLE IF EXISTS ${prefix}_$i" >/dev/null; done
    exit 1
fi

median_ms() {
    sort -n | awk '
        { a[NR] = $1 }
        END {
            if (NR == 0) { print "?"; exit }
            if (NR % 2) { printf "%.2f", a[(NR+1)/2] }
            else        { printf "%.2f", (a[NR/2] + a[NR/2+1]) / 2 }
        }'
}

time_sql() {
    sql=${1%;}
    tmp=$(mktemp)
    { echo '\timing on'; for _ in $(seq 1 "$repeat"); do printf '%s;\n' "$sql"; done; } \
        | psql -X -A -t 2>/dev/null \
        | grep '^Time:' | sed 's/^Time: //; s/ ms$//' > "$tmp"
    # A missing semicolon once made psql read every call as one statement and print one Time line,
    # so a "median of 30" was a median of one sample. Count the samples and refuse to report a
    # number that is not the requested one.
    n=$(wc -l < "$tmp")
    if [ "$n" -ne "$repeat" ]; then
        printf '  expected %s timings, got %s; refusing to report a median from them\n' "$repeat" "$n" >&2
        rm -f "$tmp"
        return 1
    fi
    median_ms < "$tmp"
    rm -f "$tmp"
}

printf '  %-34s %-24s %s\n' 'bloat_cause_text()' 'bloat_cause_findings()' 'baseline: pg_stat_user_tables'
printf '  %s\n' '----------------------------------------------------------------------------------------'

if ! text=$(time_sql "SELECT count(*) FROM bloat_cause_text()") \
   || ! find=$(time_sql "SELECT count(*) FROM bloat_cause_findings()") \
   || ! base=$(time_sql "SELECT count(*) FROM pg_stat_user_tables WHERE n_dead_tup > 0"); then
    for i in $(seq 1 "$tables"); do q "DROP TABLE IF EXISTS ${prefix}_$i" >/dev/null; done
    exit 1
fi
printf '  %-34s %-24s %s\n' "$text" "$find" "$base"

if [ "$keep" -eq 0 ]; then
    for i in $(seq 1 "$tables"); do q "DROP TABLE IF EXISTS ${prefix}_$i" >/dev/null; done
fi
printf '\n  all times in milliseconds. The baseline answers a smaller question; see the header.\n\n'
