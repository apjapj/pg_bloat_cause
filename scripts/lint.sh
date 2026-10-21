#!/usr/bin/env bash
# scripts/lint.sh: every database-free check, in one script. No Makefile and no PostgreSQL.
#
# Why this is a script and not the `lint` recipe. `make lint` parses the Makefile first, and the
# Makefile includes $(PGXS) unconditionally, so `make lint` needs pgxs.mk to exist. A CI container
# can have pg_config and no server-dev package, and then `make lint` stops at the include and no
# check runs at all. A lint that needs a PostgreSQL toolchain to check shell scripts is the wrong
# dependency. `make lint` calls this, and both CI copies call it directly.
#
# It also closes a real gap: before this, the two lint jobs ran three checks by hand and the other
# three were only in `make lint`, so none of them ran in CI. One script is the list.
#
# Everything here is text and git only: no database, no network, no superuser, so it is safe
# anywhere and cheap enough for a pre-commit hook.
set -euo pipefail
cd "$(dirname "$0")/.."

step() { printf '\n== %s\n' "$1"; }

# The version agrees across control, the newest release and the README header, every SQL file is
# installed with no DATA duplicate, doc paths resolve, the test plans match, and no em-dashes.
step "the documentation's claims"
./scripts/lint-docs.sh
# Every figure a document links to scenario evidence is in that file.
step "evidence figures"
./scenarios/check-evidence.sh
# Rejects a duplicated mapping key, which PyYAML accepts silently and Forgejo does not. A workflow
# with one dispatches no jobs at all and its run reads as a plain failure.
step "workflows"
./scripts/check-workflows.sh
# Every function in the newest release script is called by a test. The first version of
# bloat_cause_holder() shipped broken and every gate here was green, because nothing ran it.
step "every new function has a test"
./scripts/check-new-function.sh
# Every catalog a README feature table names is one the release script reads.
step "README catalog claims"
./scripts/check-evidence-claims.sh
# A document that states the PostgreSQL range the matrix covers must state the range CI declares.
step "the stated PostgreSQL range"
./scripts/check-pg-matrix-claims.sh
# The two CI copies define the same jobs and run the same command for the ones they share. Vendored
# from pg-dev-infra; run with bash, it has no shebang.
step "the two CI copies agree"
bash ./scripts/check-ci-parity.sh
# The PGXN metadata is generated from the control file and the stable fields, and it must not name a
# private host or address: META.json is published and permanent.
step "the PGXN metadata"
./scripts/pgxn-meta.py --check >/dev/null

# Every vendored harness copy still matches the sha256 in its own header. The canonical is private,
# so this is the in-repo half of the sync. Vendored from pg-dev-infra; run with bash.
step "the vendored harness matches its headers"
bash ./scripts/check-vendored-hashes.sh
# A scenario that reads a cumulative statistic must settle the statistics first, or the read races the
# collector. s15_measure reached CI that way, as a flake that a text check would have caught.
step "scenarios settle the statistics they read"
./scripts/check-scenario-stats.sh
