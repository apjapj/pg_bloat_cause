#!/usr/bin/env bash
# scripts/test-teardown.sh: terminate sessions this suite opened and left behind.
#
# The test connections carry application_name = bc_test_*, so this cannot touch a real session. It is
# safe to run when the suite passed, failed or was interrupted; pg_terminate_backend() returns false
# for a pid that has already gone.
set -euo pipefail

psql -X -v ON_ERROR_STOP=1 -At <<'SQL'
SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
 WHERE pid <> pg_backend_pid()
   AND application_name LIKE 'bc_test%';
SQL
