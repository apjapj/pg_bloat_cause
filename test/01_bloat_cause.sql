-- test/01_bloat_cause.sql: the objects, their shape, and one finding built here.
--
-- The scenario suite (scenarios/run.sh) is where each cause is tested against a real fixture on 14
-- and 18; this file pins what a scenario cannot: that the objects exist with the columns docs/design.md
-- promises, that nothing writes, and that the estimate label is on every row. It builds one table with
-- autovacuum disabled and dead rows, which needs no other session and no waiting.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_bloat_cause;
\o
SELECT plan(14);

SELECT has_view('bloat_cause', 'the bloat_cause view exists');
SELECT has_function('bloat_cause_findings', ARRAY['interval', 'bigint'], 'bloat_cause_findings(interval, bigint) exists');
SELECT has_function('bloat_cause_text', ARRAY['interval', 'bigint'], 'bloat_cause_text(interval, bigint) exists');

-- The three finding states are three columns, and the estimate label is a column of its own.
SELECT columns_are('bloat_cause',
  ARRAY['schemaname', 'relname', 'relid', 'dead_rows', 'dead_pct', 'dead_bytes', 'dead_rows_source',
        'cause', 'cause_detail', 'cause_since', 'then', 'unknowns'],
  'bloat_cause has the columns docs/design.md describes, including cause, then and unknowns');

-- Read-only, stated in the catalog: nothing here is VOLATILE, so nothing can be writing.
SELECT is((SELECT count(*)::int FROM pg_proc p JOIN pg_depend d ON d.objid = p.oid
            JOIN pg_extension e ON e.oid = d.refobjid AND e.extname = 'pg_bloat_cause'
           WHERE p.provolatile = 'v'), 0,
          'no function in the extension is VOLATILE: it reads and never writes');

-- A fixture that needs no second session: autovacuum disabled, half the rows dead.
\o /dev/null
DROP TABLE IF EXISTS bc_test_orders;
CREATE TABLE bc_test_orders (id int PRIMARY KEY, status text) WITH (autovacuum_enabled = false);
INSERT INTO bc_test_orders SELECT g, 'new' FROM generate_series(1, 1000) g;
ANALYZE bc_test_orders;
UPDATE bc_test_orders SET status = 'paid' WHERE id % 2 = 0;
\o
-- Statistics reach the view at transaction end, flushed at most once a second on 15 and later and by
-- the collector on 14; a short wait and a fresh snapshot make them visible here.
SELECT pg_sleep(1.5);
SELECT pg_stat_clear_snapshot();

SELECT is((SELECT cause FROM bloat_cause_findings(interval '1 minute') WHERE relname = 'bc_test_orders'),
          'autovacuum disabled', 'a table with autovacuum disabled and dead rows has that as its cause');
SELECT is((SELECT dead_rows_source FROM bloat_cause_findings() WHERE relname = 'bc_test_orders'),
          'estimated', 'and the row says its figures are estimated');
SELECT ok((SELECT dead_rows FROM bloat_cause_findings() WHERE relname = 'bc_test_orders') > 0,
          'dead_rows is the statistics'' count, above zero');
SELECT ok((SELECT dead_bytes FROM bloat_cause_findings() WHERE relname = 'bc_test_orders') > 0,
          'dead_bytes is estimated from the heap size, above zero');
SELECT is((SELECT cardinality(unknowns) FROM bloat_cause_findings() WHERE relname = 'bc_test_orders'), 0,
          'no horizon holder is present, so nothing is "not established"');
SELECT ok((SELECT t LIKE 'bc_test_orders: % dead rows (%, estimated), autovacuum is disabled on this table%'
             FROM bloat_cause_text() t WHERE t LIKE 'bc_test_orders:%'),
          'the sentence form names the table, the estimate label and the cause');

-- The view is the function with its defaults.
SELECT is((SELECT count(*) FROM bloat_cause), (SELECT count(*) FROM bloat_cause_findings()),
          'the view returns what bloat_cause_findings() returns with its defaults');

-- Once vacuumed, the table has nothing to say: no dead rows, no row. On a primary with a feedback
-- standby the VACUUM has to wait until the standby has reported a horizon past the updates, or it
-- cannot remove the newest dead rows yet (wal_receiver_status_interval, 10 s by default); the scenario
-- suite found that lag, and this waits for it the same way. No physical slot, no wait.
\o /dev/null
-- The target xid is taken in its own statement: taken inside the DO block it would be the block's own
-- running xid, which no standby horizon can pass while the block runs, so the loop could only time out.
SELECT set_config('bc_test.target', txid_current()::text, false);
DO $wait$
DECLARE target bigint := current_setting('bc_test.target')::bigint;
BEGIN
  FOR i IN 1..150 LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM pg_replication_slots
                           WHERE slot_type = 'physical' AND active AND xmin IS NOT NULL
                             AND xmin::text::bigint < target);
    PERFORM pg_sleep(0.2);
  END LOOP;
END
$wait$;
VACUUM bc_test_orders;
\o
SELECT pg_sleep(1.5);
SELECT pg_stat_clear_snapshot();
SELECT is((SELECT count(*)::int FROM bloat_cause_findings() WHERE relname = 'bc_test_orders'), 0,
          'after VACUUM the table has no dead rows and does not appear');

-- The age rendering the sentences use.
SELECT is(bloat_cause_age(interval '3 days 4 hours'), '3 days', 'ages of two days or more are in days');

\o /dev/null
DROP TABLE bc_test_orders;
\o
SELECT * FROM finish();
