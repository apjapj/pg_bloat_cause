#!/usr/bin/env bash
# ci/job.sh <major>: everything one CI matrix job does, as one script, so it runs the same on a laptop
# as on a runner. Needs Docker, psql and pg_prove on the host.
#
#   1. build the server image (ci/Dockerfile: official postgres plus pgTAP)
#   2. build a primary and a hot standby from it (scenarios/standby.sh), which s3 needs
#   3. install the extension into both, md5-verified (scenarios/install-extension.sh)
#   4. the pgTAP suite against the primary
#   5. the scenario suite, which asserts the extension's finding for every cause
#   6. the masked evidence it writes must equal the committed evidence, byte for byte
#
# Step 6 is the strictest and the one most likely to find a runner-specific difference: two
# consecutive local runs agree byte for byte, but a slower or busier machine may move a timing that
# the fixtures have not yet been made to wait for. If it fails, the diff is the finding.
set -uo pipefail
v=${1:?usage: ci/job.sh <postgres major version>}
cd "$(dirname "$0")/.."
image="bc-ci:$v"; pport=57$v; sport=$((57${v} + 1))
fail=0
step() { printf '\n== %s\n' "$1"; }

step "build $image"
docker build -q --build-arg PG_MAJOR="$v" -t "$image" ci/ >/dev/null || exit 1

step "primary on $pport, standby on $sport"
scenarios/standby.sh "$v" down
BC_IMAGE="$image" scenarios/standby.sh "$v" "$pport" "$sport" || exit 1
trap 'scenarios/standby.sh "$v" down' EXIT

step "install the extension"
scenarios/install-extension.sh "bc-pri-$v" "bc-sby-$v" || exit 1

export PGHOST=127.0.0.1 PGPORT=$pport PGUSER=postgres PGPASSWORD=test PGDATABASE=postgres
step "pgTAP"
pg_prove --dbname postgres test/*.sql || fail=1

step "scenarios"
out=$(BC_CONTAINER="bc-pri-$v" BC_STANDBY_PORT=$sport scenarios/run.sh)
printf '%s\n' "$out"
if grep -qE 'FAILED' <<<"$out"; then fail=1; fi

step "evidence matches what is committed"
if git diff --exit-code --stat -- "scenarios/evidence/*.pg$v.txt"; then
    echo "  identical"
else
    git diff -- "scenarios/evidence/*.pg$v.txt" | head -60
    fail=1
fi

exit $fail
