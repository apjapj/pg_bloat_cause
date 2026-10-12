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
SELECT plan(19);

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
-- With every horizon holder filtered out, nothing may be "not established". The filters are set past
-- anything a real cluster has, because this assertion is about the logic, not about the cluster: an
-- earlier version used the defaults and failed whenever some other session on the server had been in a
-- transaction for over a minute, which the view correctly reported. Found by a hand run with a stray
-- session from a botched setup still open.
SELECT is((SELECT cardinality(unknowns) FROM bloat_cause_findings(interval '1000 years', 9223372036854775807)
            WHERE relname = 'bc_test_orders'), 0,
          'with no horizon holder in play, nothing is "not established"');
SELECT ok((SELECT t LIKE 'bc_test_orders: % dead rows (%, estimated), autovacuum is disabled on this table%'
             FROM bloat_cause_text() t WHERE t LIKE 'bc_test_orders:%'),
          'the sentence form names the table, the estimate label and the cause');

-- The view is the function with its defaults.
SELECT is((SELECT count(*) FROM bloat_cause), (SELECT count(*) FROM bloat_cause_findings()),
          'the view returns what bloat_cause_findings() returns with its defaults');

-- Privileges. Closed by default: a role with no grant is refused by the view and by both functions.
-- A role given the documented grants, but not pg_read_all_stats, can read the findings and is TOLD
-- what it cannot see. That is the behaviour docs/design.md promises, asserted as a real role rather
-- than as a superuser, since a superuser can never observe it.
--
-- These run BEFORE the VACUUM below, on the same fixture the assertions above already proved visible
-- in pg_stat_user_tables. On PG 14 the statistics collector writes asynchronously, so a
-- freshly-created fixture can have an unobservable dead-tuple count for a moment; reusing the
-- already-proven fixture removes that wait entirely. This was a real flake: 2 failures in 9 CI runs on
-- the 14 runner, none on 15 and later, where statistics are in shared memory.
\o /dev/null
DROP ROLE IF EXISTS bc_test_none;
DROP ROLE IF EXISTS bc_test_granted;
CREATE ROLE bc_test_none;
CREATE ROLE bc_test_granted;
GRANT SELECT ON bloat_cause TO bc_test_granted;
GRANT EXECUTE ON FUNCTION bloat_cause_findings(interval, bigint), bloat_cause_text(interval, bigint) TO bc_test_granted;
\o

SET ROLE bc_test_none;
SELECT throws_ok('SELECT count(*) FROM bloat_cause', '42501', NULL,
                 'a role with no grant is refused by the view');
SELECT throws_ok('SELECT count(*) FROM bloat_cause_text()', '42501', NULL,
                 'and by bloat_cause_text(), which is not executable by PUBLIC');
RESET ROLE;

SET ROLE bc_test_granted;
SELECT ok((SELECT unknowns[1] LIKE 'this role cannot see other users'' sessions (it lacks pg_read_all_stats)%'
             FROM bloat_cause WHERE relname = 'bc_test_orders'),
         'a role with the grants but without pg_read_all_stats reads the view and is told what it cannot see');
SELECT ok((SELECT t LIKE '%Not established: this role cannot see other users'' sessions%'
             FROM bloat_cause_text() t WHERE t LIKE 'bc_test_orders:%'),
         'and the sentence form says it too');
SELECT is((SELECT cause FROM bloat_cause WHERE relname = 'bc_test_orders'), 'autovacuum disabled',
         'while still naming the cause it can establish');
RESET ROLE;

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
-- Conditional, and counted either way: if another session or a prepared transaction holds the horizon,
-- the VACUUM above cannot remove the dead rows, the table correctly still appears, and asserting
-- otherwise would be asserting about the cluster rather than the extension. So it is skipped, with the
-- reason, rather than failed. The same stray session that broke the assertion above broke this one.
SELECT CASE
  WHEN EXISTS (SELECT 1 FROM pg_stat_activity
                WHERE pid <> pg_backend_pid() AND backend_type = 'client backend'
                  AND (backend_xid IS NOT NULL OR backend_xmin IS NOT NULL))
       OR EXISTS (SELECT 1 FROM pg_prepared_xacts)
  THEN skip('another session or a prepared transaction holds the horizon, so VACUUM cannot clean the table here', 1)
  ELSE is((SELECT count(*)::int FROM bloat_cause_findings() WHERE relname = 'bc_test_orders'), 0,
          'after VACUUM the table has no dead rows and does not appear')
END;

-- The age rendering the sentences use.
SELECT is(bloat_cause_age(interval '3 days 4 hours'), '3 days', 'ages of two days or more are in days');

\o /dev/null
DROP TABLE bc_test_orders;
REVOKE ALL ON bloat_cause FROM bc_test_granted;
REVOKE ALL ON FUNCTION bloat_cause_findings(interval, bigint), bloat_cause_text(interval, bigint) FROM bc_test_granted;
DROP ROLE bc_test_none;
DROP ROLE bc_test_granted;
\o
SELECT * FROM finish();
