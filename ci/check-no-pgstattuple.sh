#!/usr/bin/env bash
# ci/check-no-pgstattuple.sh — the measurement's behaviour on a cluster that never installed pgstattuple.
#
# Why this is a step and not a second matrix job. It has to run on a cluster where pgstattuple was never
# created, and the pgTAP suite creates it, so it belongs BEFORE pgTAP in ci/job.sh. A separate job would
# also need its name added to the required-status-checks ruleset on GitHub, or it would run and not gate
# anything; a step in the job that already gates cannot be ignored.
#
# What it is for. bloat_cause_measure() is deliberately always present and raises when pgstattuple is
# absent, rather than being absent itself, so a caller gets "CREATE EXTENSION pgstattuple" instead of
# "function does not exist". That decision is only real if something runs on a cluster without it.
#
# The pgTAP assertion covers the same refusal by DROPPING pgstattuple in a cluster that had it. This is a
# different starting state and tests something a drop cannot: that the extension INSTALLS with
# pgstattuple never present, which it must, because the function's reference to it is resolved at run
# time rather than at CREATE.
#
# It installs into its own schema and drops it again, so the cluster is left as it was found and the
# pgTAP run that follows is unaffected.
#
# Reads the libpq variables from the environment, which ci/job.sh has already exported.

set -uo pipefail

SCHEMA_NO_PGSTATTUPLE=bc_nopt

fail=0
say()  { printf '\n\033[1m%s\033[0m\n' "$1"; }
note() { printf '  %s\n' "$1"; }
check() {  # $1 description, $2 t or f
    if [ "$2" = t ]; then note "PASS  $1"; else note "FAIL  $1"; fail=1; fi
}
val() { psql -X -At -q -v ON_ERROR_STOP=1 -c "$1" 2>&1; }
# The SQLSTATE and the message, read from inside plpgsql because that is the only place a caller can
# observe them. psql -At prints the message without the code, so catching it is the reliable way.
observe() {  # $1 = 'state' or 'message'; $2 = the SQL to run
    psql -X -At -q -c "
DO \$\$
BEGIN
  BEGIN
    PERFORM $2;
    RAISE NOTICE 'no error';
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE '%', $([ "$1" = state ] && echo SQLSTATE || echo SQLERRM);
  END;
END \$\$" 2>&1 | sed -n 's/^NOTICE:  *//p' | head -1
}

say "with no pgstattuple ever installed"

check "pgstattuple is genuinely absent, so this is the state it claims to test" \
    "$([ "$(val "SELECT count(*) FROM pg_extension WHERE extname = 'pgstattuple'")" = 0 ] && echo t || echo f)"

# The install is the assertion a drop-then-call cannot make.
installed=$(val "CREATE SCHEMA IF NOT EXISTS $SCHEMA_NO_PGSTATTUPLE" \
           && val "CREATE EXTENSION IF NOT EXISTS pg_bloat_cause SCHEMA $SCHEMA_NO_PGSTATTUPLE" \
           && val "CREATE TABLE IF NOT EXISTS $SCHEMA_NO_PGSTATTUPLE.probe (id int)" \
           && val "INSERT INTO $SCHEMA_NO_PGSTATTUPLE.probe VALUES (1)")
check "the extension installs with pgstattuple never present" \
    "$([ "$(val "SELECT count(*) FROM pg_extension WHERE extname = 'pg_bloat_cause'")" = 1 ] && echo t || echo f)"

check "and the view runs, so nothing else in it needs the optional extension" \
    "$(val "SELECT count(*) >= 0 FROM $SCHEMA_NO_PGSTATTUPLE.bloat_cause" >/dev/null 2>&1 && echo t || echo f)"

state=$(observe state "$SCHEMA_NO_PGSTATTUPLE.bloat_cause_measure('$SCHEMA_NO_PGSTATTUPLE', 'probe')")
check "the measurement raises the documented SQLSTATE 0A000, not a name-resolution or permission error" \
    "$([ "$state" = "0A000" ] && echo t || echo f)"
note "  observed SQLSTATE: ${state:-<nothing>}"

message=$(observe message "$SCHEMA_NO_PGSTATTUPLE.bloat_cause_measure('$SCHEMA_NO_PGSTATTUPLE', 'probe')")
check "and the message names pgstattuple, so the caller knows what to install" \
    "$(printf '%s' "$message" | grep -q pgstattuple && echo t || echo f)"
note "  message: $message"

# Leave the cluster as it was found, so the pgTAP run that follows is unaffected.
val "DROP SCHEMA IF EXISTS $SCHEMA_NO_PGSTATTUPLE CASCADE" >/dev/null 2>&1

exit $fail
