#!/usr/bin/env bash
# check-defects.sh <postgres major version>: re-inject each recorded defect and require the test
# that first caught it to fail again.
#
# A bug fixed today can be reintroduced tomorrow, and nothing notices unless something puts it
# back. Each defects/<id>.patch reverts one fix, and its .meta names the test that must fail while
# the patch is applied. This runs every cell against the same server image CI uses and reports the
# regression rate: of the defects the suite once caught, how many does it still catch.
#
# It is a mutation run, not a lint. It needs Docker and a server, so it is its own target
# (`make defects`), not part of `make lint`, and it reuses ci/Dockerfile and install-extension.sh.
#
# The three verdicts: caught, missed, could-not-run. A cell that cannot run is reported and is never
# counted as caught, because a defect no mechanism could reach makes a miss mean nothing.
set -uo pipefail
v=${1:?usage: check-defects.sh <postgres major version>}
cd "$(dirname "$0")/.."

# Preflight, the same two things ci/job.sh names: a daemon that is not answering fails later as
# "failed to connect to the docker API", which names neither cause nor fix.
if ! command -v docker >/dev/null 2>&1; then
    echo "check-defects.sh: the docker CLI is not on PATH" >&2; exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "check-defects.sh: the docker daemon is not answering${DOCKER_HOST:+ (DOCKER_HOST=$DOCKER_HOST)}" >&2
    exit 1
fi

image="bc-ci:$v"; port=57$v; c="bc-defects-$v"
docker rm -f "$c" >/dev/null 2>&1
docker build -q --build-arg PG_MAJOR="$v" -t "$image" ci/ >/dev/null || exit 1
docker run -d --rm --name "$c" -p 127.0.0.1:$port:5432 -e POSTGRES_PASSWORD=test "$image" postgres >/dev/null || exit 1
trap 'docker rm -f "$c" >/dev/null 2>&1' EXIT
for _ in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -p $port && break; sleep 1; done
sleep 2
export PGHOST=127.0.0.1 PGPORT=$port PGUSER=postgres PGPASSWORD=test PGDATABASE=postgres

# The pristine extension, so a patch has something to overwrite and a restore has a target.
./scenarios/install-extension.sh "$c" >/dev/null || exit 1
extdir=$(docker exec "$c" sh -c 'pg_config --sharedir')/extension

put() {
    docker cp "$1" "$c:/tmp/bc-defect-$2" >/dev/null
    docker exec -u root "$c" sh -c "cp /tmp/bc-defect-$2 \"$extdir/$2\""
    docker exec -u root "$c" sh -c "rm -f /tmp/bc-defect-$2"
}

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

    touched=$(grep -E '^\+\+\+ ' "$patch" | sed -E 's#^\+\+\+ (b/)?##')
    tmp=$(mktemp -d)
    for f in $touched; do mkdir -p "$tmp/$(dirname "$f")" && cp "$f" "$tmp/$f"; done
    if ! patch -s -p1 -d "$tmp" < "$patch"; then
        echo "  $id: COULD-NOT-RUN (the patch does not apply)"
        norun=$((norun+1)); rm -rf "$tmp"; continue
    fi
    for f in $touched; do put "$tmp/$(basename "$f")" "$(basename "$f")"; done
    rm -rf "$tmp"

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
echo "defects: $caught of $den caught, $missed missed, $norun could-not-run"
[ "$missed" -eq 0 ] || { echo "regression:$regressed" >&2; exit 1; }
exit 0
