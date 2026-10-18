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
#
# BC_EVIDENCE_STRICT controls only step 6. Unset or 1 (the default, and what to use locally): a
# difference fails the job. 0: the full diff is printed with an "EVIDENCE DIFFERS (report-only)" line
# and the job does not fail on it. The workflow sets 0 for the first runs on hosted runners, because
# the committed evidence was made on one machine and a comparison that is red for environmental
# reasons on day one teaches everyone to ignore red. Tighten it to 1 once those runs have been read:
# see ci/README.md. pgTAP and the scenario assertions are fatal in both modes.
set -uo pipefail
v=${1:?usage: ci/job.sh <postgres major version>}
cd "$(dirname "$0")/.."

# Preflight. This job needs two things from Docker before it can do anything: the CLI on PATH and a
# daemon that answers. A daemon that is not there fails later as "failed to connect to the docker
# API", and the build that follows reads like a bad Dockerfile, so neither cause nor fix is named.
# standby.sh also creates a network the two containers join; that failure is a Docker error too, and
# is caught here first. The same failure hit the Forgejo copy once and was invisible for five runs.
if ! command -v docker >/dev/null 2>&1; then
    echo "ci/job.sh: the docker CLI is not on PATH" >&2
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "ci/job.sh: the docker daemon is not answering${DOCKER_HOST:+ (DOCKER_HOST=$DOCKER_HOST)}" >&2
    echo "           start it, or point DOCKER_HOST at a reachable daemon; this job needs it" >&2
    exit 1
fi

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

# BEFORE pgTAP, because the pgTAP file creates pgstattuple and this check needs a cluster that has
# never had it. Deliberately a step in this job rather than a second matrix job: a new job's name
# would not be in the required-checks ruleset, so it would run and gate nothing, while a step in a
# required job cannot be ignored. See ci/check-no-pgstattuple.sh.
step "the measurement with no pgstattuple ever installed"
ci/check-no-pgstattuple.sh || fail=1

step "pgTAP"
pg_prove --dbname postgres test/*.sql || fail=1

step "scenarios"
out=$(BC_CONTAINER="bc-pri-$v" BC_STANDBY_PORT=$sport scenarios/run.sh)
printf '%s\n' "$out"
if grep -qE 'FAILED' <<<"$out"; then fail=1; fi

step "evidence matches what is committed"
if git diff --quiet -- "scenarios/evidence/*.pg$v.txt"; then
    echo "  identical"
else
    git diff --stat -- "scenarios/evidence/*.pg$v.txt"
    git diff -- "scenarios/evidence/*.pg$v.txt"
    if [ "${BC_EVIDENCE_STRICT:-1}" = 0 ]; then
        echo "EVIDENCE DIFFERS (report-only): the diff above is not failing this job, because BC_EVIDENCE_STRICT=0"
    else
        echo "EVIDENCE DIFFERS: failing, because BC_EVIDENCE_STRICT is not 0"
        fail=1
    fi
fi

step "scenarios with pgstattuple never installed"
# Step 6's sampler reads the estimate and must not need pgstattuple, so the suite has to pass where
# it is absent. Remove it from both servers and run the scenarios again: the measured cross-check
# reports itself as not established, and every assertion must still hold. This is the with-and-without
# branch made real. The evidence differs from the committed set by design (the measured lines are
# gone), so this run writes it to a scratch directory and nothing here is compared to a committed file.
for c in "bc-pri-$v" "bc-sby-$v"; do
    docker exec -u root "$c" sh -c 'rm -f "$(pg_config --sharedir)"/extension/pgstattuple* "$(pg_config --pkglibdir)"/pgstattuple.so' 2>/dev/null || true
done
absent=$(psql -X -At -c "SELECT count(*) FROM pg_available_extensions WHERE name = 'pgstattuple'")
echo "  pgstattuple available: ${absent} (0 is the state this leg claims to test)"
[ "$absent" = "0" ] || { echo "  FAIL  pgstattuple is still available, so this leg proves nothing"; fail=1; }
out2=$(BC_CONTAINER="bc-pri-$v" BC_STANDBY_PORT=$sport EVIDENCE_DIR=$(mktemp -d) scenarios/run.sh)
printf '%s\n' "$out2"
if grep -qE 'FAILED' <<<"$out2"; then fail=1; fi

step "docker footprint"
# The smoke alarm for the anonymous-volume leak the removal paths fix at source: a host that
# accumulates dangling volumes fails here rather than filling its disk. Deletes nothing.
bash scripts/docker-guard.sh check || fail=1

exit $fail
