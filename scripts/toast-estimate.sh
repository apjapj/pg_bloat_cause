#!/usr/bin/env bash
# scripts/toast-estimate.sh: the TOAST statistics estimate against pgstattuple_approx(), with the
# materiality boundaries. Run against installed 0.7.0 or later.
#
# It creates wide-value fixtures in the current database, compares the estimate with the exact read
# (tolerance 15%), and checks that ~80 MB of dead TOAST is not material while ~120 MB is. The estimate
# runs about 9% high, so the boundaries are deliberately clear of 100 MB.
set -euo pipefail

keep=${KEEP:-0}
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS pgstattuple;
DROP TABLE IF EXISTS toast_est_upd, toast_est_del, toast_est_80, toast_est_120;

CREATE TABLE toast_est_upd (id int PRIMARY KEY, payload text) WITH (autovacuum_enabled = false);
ALTER TABLE toast_est_upd ALTER COLUMN payload SET STORAGE EXTERNAL;
INSERT INTO toast_est_upd SELECT g, repeat('x', 20000) FROM generate_series(1, 200) g;
UPDATE toast_est_upd SET payload = repeat('y', 20000);

CREATE TABLE toast_est_del (id int PRIMARY KEY, payload text) WITH (autovacuum_enabled = false);
ALTER TABLE toast_est_del ALTER COLUMN payload SET STORAGE EXTERNAL;
INSERT INTO toast_est_del SELECT g, repeat('x', 20000) FROM generate_series(1, 200) g;
DELETE FROM toast_est_del WHERE id % 2 = 0;

CREATE TABLE toast_est_80 (id int PRIMARY KEY, payload text) WITH (autovacuum_enabled = false);
ALTER TABLE toast_est_80 ALTER COLUMN payload SET STORAGE EXTERNAL;
INSERT INTO toast_est_80 SELECT g, repeat('x', 20000) FROM generate_series(1, 4000) g;
UPDATE toast_est_80 SET payload = repeat('y', 20000);

CREATE TABLE toast_est_120 (id int PRIMARY KEY, payload text) WITH (autovacuum_enabled = false);
ALTER TABLE toast_est_120 ALTER COLUMN payload SET STORAGE EXTERNAL;
INSERT INTO toast_est_120 SELECT g, repeat('x', 20000) FROM generate_series(1, 6000) g;
UPDATE toast_est_120 SET payload = repeat('y', 20000);
SQL

# Statistics are written by the collector; poll instead of assuming one sleep is enough.
psql -X -q -v ON_ERROR_STOP=1 <<'SQL'
DO $wait$
DECLARE i int;
BEGIN
  FOR i IN 1..200 LOOP
    EXIT WHEN (SELECT count(*) FROM pg_stat_all_tables s
                JOIN pg_class c ON c.reltoastrelid = s.relid
               WHERE c.relname LIKE 'toast_est_%'
                 AND coalesce(s.n_live_tup, 0) + coalesce(s.n_dead_tup, 0) > 0) >= 4;
    PERFORM pg_sleep(0.1);
  END LOOP;
END
$wait$;
SELECT pg_stat_clear_snapshot();
SQL

psql -X -v ON_ERROR_STOP=1 <<'SQL'
DO $check$
DECLARE
  r record;
  n int := 0;
BEGIN
  FOR r IN
    SELECT c.relname,
           s.n_live_tup, s.n_dead_tup,
           pg_relation_size(c.reltoastrelid) AS toast_bytes,
           (SELECT dead_tuple_len FROM pgstattuple_approx(c.reltoastrelid)) AS measured_bytes
      FROM pg_class c
      JOIN pg_stat_all_tables s ON s.relid = c.reltoastrelid
     WHERE c.relname IN ('toast_est_upd', 'toast_est_del')
  LOOP
    n := n + 1;
    IF r.n_live_tup + r.n_dead_tup = 0 THEN
      RAISE EXCEPTION '% has no TOAST statistics', r.relname;
    END IF;
    IF r.measured_bytes = 0 THEN
      RAISE EXCEPTION '% has no measured dead TOAST bytes', r.relname;
    END IF;
    IF abs((r.n_dead_tup * r.toast_bytes / (r.n_live_tup + r.n_dead_tup)) - r.measured_bytes)
       > 0.15 * r.measured_bytes THEN
      RAISE EXCEPTION '%: estimate is more than 15%% from pgstattuple_approx()', r.relname;
    END IF;
    RAISE NOTICE '%: estimate within 15%% of the measured dead bytes', r.relname;
  END LOOP;
  IF n <> 2 THEN
    RAISE EXCEPTION 'expected two tolerance fixtures, found %', n;
  END IF;

  IF (SELECT material FROM bloat_cause_toast('public', 'toast_est_80', 0)) THEN
    RAISE EXCEPTION 'the ~80 MB fixture was material; the boundary is too close to 100 MB';
  END IF;
  IF NOT (SELECT material FROM bloat_cause_toast('public', 'toast_est_120', 0)) THEN
    RAISE EXCEPTION 'the ~120 MB fixture was not material; the boundary is too close to 100 MB';
  END IF;
  RAISE NOTICE 'boundary: ~80 MB not material, ~120 MB material';
END;
$check$;
SQL

if [ "$keep" != 1 ]; then
  psql -X -q -v ON_ERROR_STOP=1 -c "DROP TABLE IF EXISTS toast_est_upd, toast_est_del, toast_est_80, toast_est_120;"
fi
