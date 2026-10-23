-- test/06_toast.sql: the statistics-based TOAST line and the min_dead_pct default.
--
-- The TOAST line is a secondary fact on the parent: never its own row, never primary, and marked
-- estimated because the statistic is 7 to 9 percent high on the experiment fixtures. The TOAST
-- autovacuum setting is separate from the parent's and is named as its own secondary line.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
\ir support/wait.sql

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_bloat_cause;

DROP TABLE IF EXISTS bc_toast_fix;
DROP TABLE IF EXISTS bc_toast_none;
CREATE TABLE bc_toast_fix (id int PRIMARY KEY, payload text) WITH (autovacuum_enabled = false);
ALTER TABLE bc_toast_fix ALTER COLUMN payload SET STORAGE EXTERNAL;
INSERT INTO bc_toast_fix SELECT g, repeat('x', 20000) FROM generate_series(1, 200) g;
UPDATE bc_toast_fix SET payload = repeat('y', 20000);
DELETE FROM bc_toast_fix WHERE id % 2 = 0;
ALTER TABLE bc_toast_fix SET (toast.autovacuum_enabled = false);
CREATE TABLE bc_toast_none (id int PRIMARY KEY);
INSERT INTO bc_toast_none VALUES (1);
ANALYZE bc_toast_fix;
ANALYZE bc_toast_none;
\o

-- The TOAST statistics are written by the collector. The assertions need dead rows (dead_pct > 0),
-- so wait for the dead count itself; a live-only row satisfies the old condition too early.
-- Flush boundary (see support/wait.sql): the backend reports its own counts when this command ends.
SELECT pg_sleep(1.2);
SELECT pg_temp.wait_until(
  $cond$SELECT n_dead_tup > 0
          FROM pg_stat_all_tables s
          JOIN pg_class c ON c.reltoastrelid = s.relid
         WHERE c.relname = 'bc_toast_fix'$cond$,
  'dead rows in the bc_toast_fix TOAST statistics');
\unset QUIET

SELECT plan(11);

SELECT has_function('bloat_cause_toast', ARRAY['name', 'name', 'bigint'],
                    'bloat_cause_toast(name, name, bigint) exists');
SELECT is((SELECT status FROM bloat_cause_toast('public', 'bc_toast_fix')),
          'estimated', 'the TOAST row is estimated from its statistics');
SELECT cmp_ok((SELECT dead_pct FROM bloat_cause_toast('public', 'bc_toast_fix')), '>', 0::numeric,
              'and has a dead percentage above zero');
SELECT is((SELECT material FROM bloat_cause_toast('public', 'bc_toast_fix')), false,
          'a few MB of dead TOAST is below the 100 MB material threshold');
SELECT ok((SELECT line FROM bloat_cause_toast('public', 'bc_toast_fix')) LIKE '%disabled%',
          'the TOAST autovacuum setting is named separately from the parent''s');
SELECT ok(EXISTS (SELECT 1 FROM bloat_cause_findings() f, unnest(f."then") t
                   WHERE f.relname = 'bc_toast_fix' AND t LIKE 'TOAST%'),
          'the line is in then[], on the parent');
SELECT is((SELECT cause FROM bloat_cause_findings() WHERE relname = 'bc_toast_fix'),
          'autovacuum disabled', 'and TOAST never becomes the primary cause');
SELECT is((SELECT count(*)::int FROM bloat_cause_findings()
            WHERE relname LIKE 'pg_toast%' OR schemaname = 'pg_toast'), 0,
          'no TOAST table gets a finding row of its own');
SELECT is((SELECT status FROM bloat_cause_toast('public', 'bc_toast_none')),
          'none', 'a table with no TOAST relation returns none, not an error');
SELECT is((SELECT (regexp_match(pg_get_function_arguments('bloat_cause_sample(numeric,bigint,timestamptz)'::regprocedure),
                                'min_dead_pct[^,]*DEFAULT ([0-9.]+)'))[1]),
          '10', 'bloat_cause_sample defaults min_dead_pct to 10 percent, as documented');
SELECT is((SELECT (regexp_match(pg_get_function_arguments('bloat_cause_notify(text,numeric,bigint,interval)'::regprocedure),
                                'min_dead_pct[^,]*DEFAULT ([0-9.]+)'))[1]),
          '10', 'bloat_cause_notify defaults min_dead_pct to 10 percent, as documented');

\o /dev/null
DROP TABLE bc_toast_fix;
DROP TABLE bc_toast_none;
\o
SELECT * FROM finish();
