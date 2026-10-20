#!/usr/bin/env bash
# check-defects.sh [--local|--container] [<postgres major version>]: re-inject each recorded defect
# and require the test that first caught it to fail again.
#
# A bug fixed today can be reintroduced tomorrow, and nothing notices unless something puts it back.
# Each defects/<id>.patch reverts one fix, and its .meta names the test that must fail while the
# patch is applied. Each cell runs the test on the pristine tree first (the control, which must pass)
# and then on the patched tree (which must fail), and reports a regression rate.
#
# Two modes, one command. `make defects` picks the mode:
#   --container  build ci/Dockerfile and run a throwaway server (needs Docker).
#   --local      use the server already here, with the extension installed by `make install`; the
#                Forgejo runner is itself a PostgreSQL and has no Docker, so it runs this way.
# Auto (the default) chooses container when the docker CLI and daemon are there, else local.
#
# The three verdicts: caught, missed, could-not-run. A cell that cannot run is reported and is never
# counted as caught, because a defect no mechanism could reach makes a miss mean nothing.
set -uo pipefail

mode=auto
case "${1:-}" in
    --local)     mode=local; shift ;;
    --container) mode=container; shift ;;
esac
v=${1:-}
case "$mode" in
    container) [ -n "$v" ] || { echo "usage: check-defects.sh [--local|--container] <postgres major version>" >&2; exit 2; } ;;
esac
cd "$(dirname "$0")/.."

if [ "$mode" = auto ]; then
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then mode=container; else mode=local; fi
fi

ext=$(basename "$(ls ./*.control 2>/dev/null | head -1)" .control)
[ -n "$ext" ] || { echo "check-defects.sh: no .control file, so no extension to test" >&2; exit 1; }

container=""; extdir=""
if [ "$mode" = container ]; then
    if ! command -v docker >/dev/null 2>&1; then
        echo "check-defects.sh --container: the docker CLI is not on PATH" >&2; exit 1
    fi
    if ! docker info >/dev/null 2>&1; then
        echo "check-defects.sh --container: the docker daemon is not answering${DOCKER_HOST:+ (DOCKER_HOST=$DOCKER_HOST)}" >&2
        exit 1
    fi
    image="bc-ci:$v"
    # Same run-scoping rule as ci/job.sh: a container job must not share a name or port with another
    # job on the host. The +2 keeps this port out of the primary/standby pair's block.
    if [ -n "${GITHUB_RUN_ID:-}" ]; then
        suffix="-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-0}"
        slot=$(( GITHUB_RUN_ID % 1000 ))
        port=$(( 20000 + slot * 40 + (v - 14) * 2 + 2 ))
    else
        suffix=""
        port=57$v
    fi
    container="bc-defects-$v$suffix"
    docker rm -f -v "$container" >/dev/null 2>&1
    docker build -q --build-arg PG_MAJOR="$v" -t "$image" ci/ >/dev/null || exit 1
    docker run -d --rm --name "$container" -p 127.0.0.1:$port:5432 -e POSTGRES_PASSWORD=test "$image" postgres >/dev/null || exit 1
    trap 'docker rm -f -v "$container" >/dev/null 2>&1' EXIT
    for _ in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -p $port && break; sleep 1; done
    sleep 2
    export PGHOST=127.0.0.1 PGPORT=$port PGUSER=postgres PGPASSWORD=test PGDATABASE=postgres
    ./scenarios/install-extension.sh "$container" >/dev/null || exit 1
    extdir=$(docker exec "$container" sh -c 'pg_config --sharedir')/extension
    put() {
        docker cp "$1" "$container:/tmp/bc-defect-$2" >/dev/null
        docker exec -u root "$container" sh -c "cp /tmp/bc-defect-$2 \"$extdir/$2\""
        docker exec -u root "$container" sh -c "rm -f /tmp/bc-defect-$2"
    }
else
    command -v pg_config >/dev/null 2>&1 || { echo "check-defects.sh --local: pg_config is not on PATH" >&2; exit 1; }
    extdir=$(pg_config --sharedir)/extension
    if [ ! -e "$extdir/$ext.control" ]; then
        echo "check-defects.sh --local: $ext is not installed in $extdir; run make install first" >&2
        exit 1
    fi
    put() { cp "$1" "$extdir/$2"; }
fi

# Drop the extension before each run. A test that creates it outside a transaction leaves it
# installed, and the next run's CREATE EXTENSION IF NOT EXISTS would then reuse the old objects
# instead of reading the file that was just swapped, so the mutant would never load.
drop_ext() { psql -qX -c "DROP EXTENSION IF EXISTS \"$ext\" CASCADE" >/dev/null 2>&1; }

total=0; caught=0; missed=0; norun=0; regressed=""
for patch in defects/*.patch; do
    [ -e "$patch" ] || continue
    id=$(basename "$patch" .patch)
    meta="defects/$id.meta"
    test=$(sed -n 's/^test=//p' "$meta" 2>/dev/null | head -1)
    if [ -z "$test" ]; then
        echo "  $id: COULD-NOT-RUN (no test= in $meta)"
        total=$((total+1)); norun=$((norun+1)); continue
    fi
    total=$((total+1))

    # Control: the test must PASS on the pristine tree, or "caught" means nothing.
    drop_ext
    ctl=$(pg_prove --dbname postgres "$test" 2>&1); crc=$?
    if [ $crc -ne 0 ]; then
        echo "  $id: COULD-NOT-RUN (the control failed: $test does not pass on the clean tree)"
        printf '%s\n' "$ctl" | grep -vE '^ok ' | sed 's/^/        /' | tail -3
        norun=$((norun+1)); continue
    fi

    touched=$(grep -E '^\+\+\+ ' "$patch" | sed -E 's#^\+\+\+ (b/)?##')
    tmp=$(mktemp -d)
    for f in $touched; do mkdir -p "$tmp/$(dirname "$f")" && cp "$f" "$tmp/$f"; done
    if ! patch -s -p1 -d "$tmp" < "$patch"; then
        echo "  $id: COULD-NOT-RUN (the patch does not apply)"
        norun=$((norun+1)); rm -rf "$tmp"; continue
    fi
    for f in $touched; do put "$tmp/$(basename "$f")" "$(basename "$f")"; done
    rm -rf "$tmp"

    drop_ext
    out=$(pg_prove --dbname postgres "$test" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then
        echo "  $id: MISSED (the defect does not make $test fail)"
        missed=$((missed+1)); regressed="$regressed $id"
    elif printf '%s' "$out" | grep -qE 'Failed [0-9]+/[0-9]+ subtests'; then
        echo "  $id: caught (the defect makes $test fail)"
        caught=$((caught+1))
    else
        echo "  $id: COULD-NOT-RUN ($test did not report a failing assertion)"
        printf '%s\n' "$out" | grep -vE '^ok ' | sed 's/^/        /' | tail -3
        norun=$((norun+1))
    fi

    for f in $touched; do put "$f" "$(basename "$f")"; done
done

den=$((caught+missed))
echo
echo "defects ($mode): $caught of $den caught, $missed missed, $norun could-not-run"
[ "$missed" -eq 0 ] || { echo "regression:$regressed" >&2; exit 1; }
exit 0
