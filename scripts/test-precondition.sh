#!/usr/bin/env bash
# scripts/test-precondition.sh: refuse to run the suite on a cluster where another session or
# prepared transaction holds the horizon.
#
# Why. bloat_cause_holder() is cluster-wide, so a stray `idle in transaction` session becomes the
# oldest holder for every test that assumes its own fixture is. The failure then looks like a bug in
# the extension: command rows with no statement, or another session's query in holder_query. It
# happened once; this turns it into one clear sentence before the suite starts.
#
# It checks client sessions with backend_xid/backend_xmin and prepared transactions. It deliberately
# does not check physical replication slots: a standby slot is an expected horizon and test/01
# handles it. Teardown of sessions this suite opened is scripts/test-teardown.sh.
set -euo pipefail

rows=$(psql -X -v ON_ERROR_STOP=1 -At -F '|' <<'SQL'
SELECT 'session' AS kind,
       pid::text,
       datname,
       state,
       left(regexp_replace(query, '\s+', ' ', 'g'), 100)
  FROM pg_stat_activity
 WHERE pid <> pg_backend_pid()
   AND backend_type = 'client backend'
   AND (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL)
UNION ALL
SELECT 'prepared', NULL, database, NULL, gid
  FROM pg_prepared_xacts;
SQL
)

if [ -n "$rows" ]; then
    printf '%s\n' "another session holds the horizon; the suite needs a fresh cluster or for it to end:" >&2
    while IFS='|' read -r kind pid db state query; do
        [ -n "$kind" ] || continue
        if [ "$kind" = prepared ]; then
            printf '  prepared transaction %s in database %s\n' "$query" "$db" >&2
        else
            printf '  pid %s in database %s (%s): %s\n' "$pid" "$db" "$state" "$query" >&2
        fi
    done <<< "$rows"
    printf '%s\n' "terminate it, roll the prepared transaction back, or use a fresh cluster" >&2
    exit 1
fi
