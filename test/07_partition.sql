-- test/07_partition.sql: partitioned tables are reported at the leaf, not the parent.
--
-- A partitioned parent has no storage and no dead tuples of its own. Its leaves have both, so the
-- findings name the leaves and never the parent. bloat_cause_context() can describe the parent
-- because it reads the catalog and statistics; bloat_cause_measure() cannot, because there is no
-- heap to read. This is a documentation and coverage gap, not a new behaviour.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
\ir support/wait.sql

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_bloat_cause;

DROP TABLE IF EXISTS bc_part CASCADE;
CREATE TABLE bc_part (id int, payload text) PARTITION BY RANGE (id);
CREATE TABLE bc_part_1 PARTITION OF bc_part FOR VALUES FROM (1) TO (1001)
  WITH (autovacuum_enabled = false);
CREATE TABLE bc_part_2 PARTITION OF bc_part FOR VALUES FROM (1001) TO (2001)
  WITH (autovacuum_enabled = false);
INSERT INTO bc_part SELECT g, repeat('x', 100) FROM generate_series(1, 2000) g;
UPDATE bc_part SET payload = 'y' WHERE id % 2 = 0;
DELETE FROM bc_part WHERE id % 5 = 0;
ANALYZE bc_part;
\o

-- One visible leaf satisfies the old sum. The test asserts both leaves, so wait for both.
-- Flush boundary (see support/wait.sql): the backend reports its own counts when this command ends.
SELECT pg_sleep(1.2);
SELECT pg_temp.wait_until(
  $cond$SELECT count(*) = 2 FROM bloat_cause_findings()
          WHERE relname IN ('bc_part_1', 'bc_part_2')$cond$,
  'both partition leaves to appear in the findings');
\unset QUIET

SELECT plan(6);

SELECT has_table('bc_part');
SELECT is((SELECT count(*)::int FROM bloat_cause_findings()
            WHERE relname IN ('bc_part_1', 'bc_part_2')), 2,
          'both leaf partitions are reported');
SELECT is((SELECT count(*)::int FROM bloat_cause_findings()
            WHERE relname = 'bc_part'), 0,
          'the partitioned parent is not reported as a row of its own');
SELECT is((SELECT cause FROM bloat_cause_findings() WHERE relname = 'bc_part_1'),
          'autovacuum disabled', 'the leaf carries its own cause and setting');
SELECT is((SELECT relkind FROM bloat_cause_context('public', 'bc_part')), 'p'::"char",
          'the context reader can describe the parent from the catalog and statistics');
SELECT throws_ok($$ SELECT * FROM bloat_cause_measure('public', 'bc_part') $$, '42P01',
                 'no ordinary table named public.bc_part',
                 'the measurement refuses the parent, because there is no heap to read');

\o /dev/null
DROP TABLE bc_part CASCADE;
\o
SELECT * FROM finish();
