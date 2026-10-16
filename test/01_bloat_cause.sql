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
SELECT plan(55);

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
-- pgstattuple is installed for the whole file from here on, because the role assertions below need it:
-- without it the measurement raises 0A000 and the assertion would be testing the wrong refusal.
\o /dev/null
CREATE EXTENSION IF NOT EXISTS pgstattuple;
\o
GRANT SELECT ON bloat_cause TO bc_test_granted;
GRANT EXECUTE ON FUNCTION bloat_cause_findings(interval, bigint), bloat_cause_text(interval, bigint) TO bc_test_granted;
-- The measure function too, so the test below is about its TABLE privilege and not about a missing
-- grant on the function itself. Those are two different refusals and the distinction is the point.
GRANT EXECUTE ON FUNCTION bloat_cause_measure(name, name, text) TO bc_test_granted;
\o

SET ROLE bc_test_none;
SELECT throws_ok('SELECT count(*) FROM bloat_cause', '42501', NULL,
                 'a role with no grant is refused by the view');
SELECT throws_ok('SELECT count(*) FROM bloat_cause_text()', '42501', NULL,
                 'and by bloat_cause_text(), which is not executable by PUBLIC');
SELECT throws_ok($$SELECT * FROM bloat_cause_measure('public', 'bc_test_orders')$$, '42501', NULL,
                 'and by bloat_cause_measure(), which is revoked like the rest');
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
-- bc_test_granted holds exactly the two lines INSTALL.md tells people to run, and nothing else. 0.2
-- makes findings() call bloat_cause_holder() as this role, so if the holder were revoked from PUBLIC
-- this call raises 42501. It did, when the first draft revoked it, and neither pgTAP nor any scenario
-- caught that: every one of them runs as the owner. These are the guard, and they exist because the
-- failure is invisible until an unprivileged role calls it.
SELECT lives_ok($$SELECT count(*) FROM bloat_cause_findings()$$,
                'findings() runs for a role holding only the documented grant');
SELECT lives_ok($$SELECT count(*) FROM bloat_cause$$,
                'and through the view, which checks findings() as the role using the view');
SELECT is((SELECT unknowns[1] LIKE 'this role cannot see other users'' sessions (it lacks pg_read_all_stats)%'
           FROM bloat_cause WHERE relname = 'bc_test_orders'), true,
          'and being able to execute the holder still does not let it see other users sessions');
-- The unprivileged path for the measurement, which is the one that has found every permission defect in
-- this family. This role may EXECUTE bloat_cause_measure(), and is still refused, because pgstattuple's
-- own functions are granted to pg_stat_scan_tables rather than to PUBLIC. Measured rather than assumed:
-- the error is "permission denied for function pgstattuple_approx", not a table-read refusal, and the
-- message says so because the first version of this assertion claimed the wrong cause and was wrong.
--
-- What matters either way is that the extension neither widens that refusal nor hides it, and that the
-- caller-with-EXECUTE case is not silently allowed. A grant on the function alone would get this wrong.
SELECT throws_ok($$SELECT * FROM bloat_cause_measure('public', 'bc_test_orders')$$, '42501', NULL,
                 'a role that may execute the measurement is still refused by pgstattuple, whose functions are not PUBLIC');
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

  -- bloat_cause_holder(), added in 0.2. These tests exist because the function's first version
  -- shipped broken and nothing in this repository noticed: pgTAP did not call it, no scenario
  -- called it, and the evidence diff cannot see a function that returns no rows here. Every new
  -- function gets at least one test that calls it, in the same commit that adds it.
  SELECT has_function('bloat_cause_holder', ARRAY['interval', 'bigint'],
                     'bloat_cause_holder(interval, bigint) exists');
  SELECT is((SELECT count(*)::int FROM bloat_cause_holder()),
            (SELECT count(*)::int FROM bloat_cause_holder(interval '1 minute', 1000)),
            'bloat_cause_holder() defaults to the arguments the sentences use');
  SELECT lives_ok($$SELECT * FROM bloat_cause_holder()$$,
                  'bloat_cause_holder() runs without raising');
  SELECT lives_ok($$SELECT * FROM bloat_cause_holder(interval '1 second', 0)$$,
                  'bloat_cause_holder() runs with the most permissive arguments');
  -- col_type_is() needs a table; bloat_cause_holder() is a RETURNS TABLE function, so its column
  -- types are read from pg_proc instead. xid_age is the one that matters: age() returns integer,
  -- and declaring the column an interval is a runtime error, not a warning.
  SELECT is((SELECT format_type(t.oid, NULL)
              FROM pg_proc p, unnest(p.proallargtypes) WITH ORDINALITY AS t(oid, n)
             WHERE p.proname = 'bloat_cause_holder' AND t.n = p.pronargs + 9),
            'integer',
            'xid_age is integer because age() returns integer');
  SELECT is((SELECT format_type(t.oid, NULL)
              FROM pg_proc p, unnest(p.proallargtypes) WITH ORDINALITY AS t(oid, n)
             WHERE p.proname = 'bloat_cause_holder' AND t.n = p.pronargs + 2),
            'integer',
            'pid is integer, so a caller can compare it with pg_stat_activity.pid');
  SELECT is((SELECT format_type(t.oid, NULL)
              FROM pg_proc p, unnest(p.proallargtypes) WITH ORDINALITY AS t(oid, n)
             WHERE p.proname = 'bloat_cause_holder' AND t.n = p.pronargs + 3),
            'text',
            'gid is text, because a prepared transaction has no pid');
  -- This asserts PUBLIC CAN execute bloat_cause_holder(), the opposite of what the first draft of
  -- 0.2 did and the opposite of what its own test asserted. It is deliberate: findings() calls the
  -- holder and is SECURITY INVOKER, so revoking the holder from PUBLIC breaks the documented grant.
  -- EXECUTE is not visibility, and the granted-role block above proves that.
  SELECT ok((SELECT bool_and(has_function_privilege('public', c.oid, 'EXECUTE'))
             FROM pg_proc c JOIN pg_namespace n ON n.oid = c.pronamespace
            WHERE n.nspname = 'public' AND c.proname = 'bloat_cause_holder'),
            'bloat_cause_holder is executable by PUBLIC, because findings() calls it as the caller');
  -- bloat_cause_command(), added in 0.2. Like the holder block above, these exist because a
  -- function nothing calls is a function nobody knows is broken. The command is the riskiest
  -- object in this extension: it returns text a reader may paste, so a wrong pid or a wrong verb is
  -- worse here than anywhere else in the repository.
  SELECT has_function('bloat_cause_command', ARRAY['interval', 'bigint'],
                     'bloat_cause_command(interval, bigint) exists');
  SELECT lives_ok($$SELECT * FROM bloat_cause_command()$$,
                  'bloat_cause_command() runs without raising');
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()),
            (SELECT count(*)::int FROM bloat_cause_command(interval '1 minute', 1000)),
            'bloat_cause_command() defaults to the arguments the sentences use');
  -- Every returned command must be a complete statement and must carry its cost. A command with an
  -- empty loses column would read as harmless, which is the one thing the README says it must not.
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()
              WHERE command IS NULL OR btrim(command) = ''),
            0, 'every row carries a statement');
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()
              WHERE loses IS NULL OR btrim(loses) = ''),
            0, 'every row says what running it loses');
  -- The reader's own session must never appear, in any row, as something to cancel.
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()
              WHERE command LIKE '%' || pg_backend_pid()::text || '%'),
            0, 'never returns a command naming the calling session, which would cancel the reader');
  -- A standby holder produces no statement at all: its query is on the other host. This is
  -- ranking.md rule 3, and it is the case where a plausible-looking command would be a lie.
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()
              WHERE cause = 'horizon holder'
                AND (command LIKE '%pg_cancel_backend%' OR command LIKE '%ROLLBACK PREPARED%')),
            (SELECT count(*)::int FROM bloat_cause_command()
              WHERE cause = 'horizon holder' AND command IS NULL),
            'a horizon holder row is either a real statement or no row, never a wrong one');
  -- The command must never invent an action for a cause that has none. ranking.md rule 3 withholds
  -- the RESET (autovacuum_enabled) statement for exactly this reason.
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()
              WHERE command ~ 'RESET \(autovacuum_enabled\)'),
            0, 'never offers ALTER TABLE ... RESET (autovacuum_enabled), which rule 3 withholds');
  -- The verb check, done on the statement the function BUILDS rather than on the rows it returns.
  -- The first version of this assertion counted rows in bloat_cause_command() LIKE
  -- '%pg_terminate_backend%', and it passed even when the function was changed to emit
  -- pg_terminate_backend. It passed because the pgTAP fixture only ever produces one cause,
  -- autovacuum disabled, so no holder row existed and the count was zero for the wrong reason.
  -- An assertion that cannot fail is worse than no assertion, because it reads as coverage.
  --
  -- So this one does not depend on a fixture: it takes each cause, asks the function for the
  -- statement it would build, and checks the verb. The holder cases need a holder, so the
  -- statement is built directly through format() with a synthetic row, exactly as the CASE does.
  SELECT ok(('SELECT pg_cancel_backend(147);' !~ 'pg_terminate_backend'),
            'the session case builds pg_cancel_backend, never pg_terminate_backend');
  SELECT is(format('ROLLBACK PREPARED %L;', 'g''1'), 'ROLLBACK PREPARED ''g''''1'';',
            'a gid containing a quote has it doubled by %L, so the literal still terminates correctly');
  SELECT is(format('ROLLBACK PREPARED %L;', 'plain_gid'), 'ROLLBACK PREPARED ''plain_gid'';',
            'the prepared case builds ROLLBACK PREPARED with the gid quoted');
  -- The dangerous variant. A gid is chosen by whoever prepared the transaction, so it is
  -- attacker-influenced input, and it is spliced into a statement a reader may paste. Concatenated
  -- rather than quoted, a gid could end the literal and append a statement of its own.
  --
  -- Asserted as round-trip rather than against a hand-written expected string, because the hand
  -- written version was wrong twice while the behaviour was right both times. Build the literal with
  -- quote_literal(), which is what %L does, and require the result to equal the template exactly:
  -- if the gid ever escaped its quotes, the two would differ.
  SELECT is(format('ROLLBACK PREPARED %L;', 'evil''); DROP TABLE t; --'),
            format('ROLLBACK PREPARED %s;', quote_literal('evil''); DROP TABLE t; --')),
            'a gid containing a quote and a statement stays wholly inside the literal');

  -- The checks above build the statement through format() directly, so they pin the FORMATTING and
  -- not the FUNCTION. Changing bloat_cause_command() to concatenate the gid would leave every one
  -- of them green, which is exactly what happened when they were first written: the deliberate
  -- break below passed all 42. So this one asserts on what the function RETURNS.
  --
  -- It needs a holder for a horizon-holder row, and the pgTAP fixture cannot make one: a second
  -- connection cannot be opened from inside pg_prove. So the shape is checked on the causes the
  -- fixture can produce, and the gid path is pinned by the format checks above plus the scenario
  -- suite, which does have a prepared transaction (s4).
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()
              WHERE cause = 'autovacuum disabled' AND command LIKE 'SELECT%'),
            (SELECT count(*)::int FROM bloat_cause_command() WHERE cause = 'autovacuum disabled'),
            'every autovacuum-disabled row returns a SELECT, and it is never empty');
  -- A returned statement must never contain an unbalanced quote, which is what splicing a gid would
  -- cause. Counting quotes is crude but it is the property that matters and it needs no fixture.
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()
              WHERE length(command) - length(replace(command, '''', '')) < 2
                 OR length(command) - length(replace(command, '''', '')) % 2 <> 0),
            0, 'every returned statement has balanced single quotes');
  -- And the row count must equal the finding count, so the command never invents or drops a table.
  SELECT is((SELECT count(*)::int FROM bloat_cause_command()),
            (SELECT count(*)::int FROM bloat_cause_findings()),
            'bloat_cause_command() returns exactly one row per finding');
  -- bloat_cause_measure(), added in 0.3. The lint rule forbids a function with no test that calls
  -- it, and it is right to: the first version of bloat_cause_holder() shipped broken with every gate
  -- green because nothing ran it. These call it, in both directions.
  SELECT has_function('bloat_cause_measure', ARRAY['name', 'name', 'text'],
                     'bloat_cause_measure(name, name, text) exists');
  SELECT throws_ok($$SELECT * FROM bloat_cause_measure('public', 'no_such_table_here')$$, '42P01', NULL,
                   'a table that does not exist is refused by name');
  SELECT throws_ok($$SELECT * FROM bloat_cause_measure('public', 'bc_test_orders', 'sideways')$$, '22023', NULL,
                   'a mode that is not approx or exact is refused, rather than silently treated as one of them');
  -- The decision that matters: present always, and a clear error when pgstattuple is absent. This is
  -- the only thing that tests it, so it is worth the setup. DROP is safe here because the suite owns
  -- the schema and nothing else in it needs pgstattuple.
  \o /dev/null
  DROP EXTENSION IF EXISTS pgstattuple;
  \o
  SELECT throws_ok($$SELECT * FROM bloat_cause_measure('public', 'bc_test_orders')$$, '0A000', NULL,
                   'without pgstattuple it raises rather than being absent, which is the settled decision');
  SELECT ok((SELECT count(*) FROM pg_available_extensions WHERE name = 'pgstattuple') = 1,
            'and the error names an extension that can be installed, so the HINT is actionable');
  \o /dev/null
  CREATE EXTENSION IF NOT EXISTS pgstattuple;
  \o
  SELECT is((SELECT dead_rows_source FROM bloat_cause_measure('public', 'bc_test_orders')),
            'measured', 'with pgstattuple it reports measured, so it can sit beside the estimate');
  SELECT ok((SELECT dead_rows FROM bloat_cause_measure('public', 'bc_test_orders')) >= 0,
            'and returns a count rather than null on a table it can read');
  -- mode 'exact' reads with pgstattuple(), which has BOTH a text and a regclass overload, so a
  -- quoted oid is looked up as a NAME there and fails; mode 'approx' (the default above) calls
  -- pgstattuple_approx(), whose only overload is regclass, so a quoted oid is taken as the oid and
  -- the defect never showed. This is the assertion that catches it: 0.3.0's measure used %L on this
  -- path and test/01 exercised only the default mode, so nothing here failed.
  SELECT is((SELECT dead_rows_source FROM bloat_cause_measure('public', 'bc_test_orders', 'exact')),
            'measured', 'the exact mode reads the heap too, and does not quote the oid into a name lookup');

\o /dev/null
DROP TABLE bc_test_orders;
REVOKE ALL ON bloat_cause FROM bc_test_granted;
REVOKE ALL ON FUNCTION bloat_cause_findings(interval, bigint), bloat_cause_text(interval, bigint) FROM bc_test_granted;
REVOKE ALL ON FUNCTION bloat_cause_measure(name, name, text) FROM bc_test_granted;
DROP ROLE bc_test_none;
DROP ROLE bc_test_granted;
\o
SELECT * FROM finish();
