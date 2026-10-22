#!/usr/bin/env bash
# scripts/check-uninstall.sh: the clean-drop contract for pg_bloat_cause, using ProbeKit v0.1.0.
#
# Throwaway database, ProbeKit snapshot, a dependent view that must block the drop, DROP EXTENSION
# with no CASCADE, then no extension-owned survivor and no history or alert table. Reinstall last.
# Needs probekit.control and probekit--0.1.0.sql in the server's extension directory.
set -euo pipefail

db="bloat_cause_uninstall_check_$$"
cleanup() { dropdb --if-exists "$db" >/dev/null 2>&1 || true; }
trap cleanup EXIT

createdb "$db"
export PGDATABASE="$db"

psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION probekit;
CREATE EXTENSION pg_bloat_cause;
CREATE EXTENSION IF NOT EXISTS pgstattuple;

INSERT INTO bloat_cause_history (sampled_at, schemaname, relname, dead_rows_source)
VALUES (now(), 'public', 'uninstall_x', 'estimated');
INSERT INTO bloat_cause_alert (channel, subject, severity, notify_count, dead_bytes)
VALUES ('uninstall_check', 'public.uninstall_x', 1, 1, 1);

CREATE TABLE uninstall_before (doc jsonb);
INSERT INTO uninstall_before SELECT probekit.snapshot('{"run":"uninstall-check"}'::jsonb);
SQL

psql -X -q -v ON_ERROR_STOP=1 -c "CREATE VIEW uninstall_dependent AS SELECT * FROM bloat_cause;"
if psql -X -q -v ON_ERROR_STOP=1 -c "DROP EXTENSION pg_bloat_cause" >/dev/null 2>&1; then
    echo "FAIL: DROP EXTENSION succeeded with a dependent view" >&2
    exit 1
fi
psql -X -q -v ON_ERROR_STOP=1 -c "DROP VIEW uninstall_dependent;"
psql -X -q -v ON_ERROR_STOP=1 -c "DROP EXTENSION pg_bloat_cause;"

psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
DO $check$
DECLARE survivors int;
BEGIN
  SELECT count(*) INTO survivors FROM probekit.survivors((SELECT doc FROM uninstall_before), 'pg_bloat_cause');
  IF survivors <> 0 THEN
    RAISE EXCEPTION 'extension-owned survivors after drop: %', survivors;
  END IF;
  IF to_regclass('public.bloat_cause_history') IS NOT NULL
     OR to_regclass('public.bloat_cause_alert') IS NOT NULL THEN
    RAISE EXCEPTION 'a history or alert table survived the drop';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_bloat_cause') THEN
    RAISE EXCEPTION 'pg_extension still has a pg_bloat_cause row';
  END IF;
  RAISE NOTICE 'PASS: no extension-owned survivor, and every history/alert table is gone';
END
$check$;

DO $opt$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgstattuple') THEN
    RAISE NOTICE 'PASS: pgstattuple, a separate extension, survived';
  END IF;
END
$opt$;
SQL

psql -X -q -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pg_bloat_cause;"
psql -X -q -v ON_ERROR_STOP=1 -c "SELECT count(*) FROM bloat_cause;" >/dev/null
echo "PASS: pg_bloat_cause reinstalls and bloat_cause answers"
