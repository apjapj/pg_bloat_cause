#!/usr/bin/env bash
# scripts/run-tests.sh [database]: the pgTAP suite with a clean-horizon precondition and a teardown
# of the sessions it opened. The database defaults to $TESTDB, then postgres.
set -uo pipefail

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$here"

db=${1:-${TESTDB:-postgres}}

./scripts/test-teardown.sh >/dev/null 2>&1 || true
./scripts/test-precondition.sh

pg_prove --dbname "$db" test/*.sql
rc=$?

./scripts/test-teardown.sh >/dev/null 2>&1 || true
exit $rc
