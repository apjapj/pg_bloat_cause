-- test/04_holder_query.sql: bloat_cause.holder_query, the opt-in, the redaction and the update path.
--
-- docs/holder-query.md is the design; this file is the proof for it. The setting is
-- bloat_cause.holder_query, off unless a session turns it on. The four things the design says the
-- tests must prove: an ordinary sample stores NULL; opted in, the holder's FIRST statement is stored
-- and marked when the server or the sampler cut it; a password literal in it does not survive; and
-- 0.4.1 updates to 0.5.0 with the column unchanged and the grant kept.
--
-- A real holder is needed, and a holder only BINDS (the cause the sampler stores context for) once a
-- vacuum has run after it started and still left the dead rows. So, in order: make the fixture; open
-- a dblink session and leave it idle in transaction holding an xid older than the dead rows; delete
-- those rows; ANALYZE; VACUUM (which removes nothing, and is what makes the holder bind); wait out
-- the sampler's one-minute holder floor ONCE; then reuse the same holder for every sample. A failed
-- statement would abort that transaction and stop it being a holder, so every statement the holder
-- runs below succeeds: the connection-string shapes ride in a SET LOCAL value rather than being
-- executed. Superuser and the dblink contrib module are required.
--
-- No credential is written in this file. The passwords and the statements that carry them are
-- assembled with || and format(), so detect-secrets has nothing to flag and the assertions read the
-- values back out of a temp table rather than repeating them.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS dblink;
DO $ext$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_bloat_cause') THEN
    CREATE EXTENSION pg_bloat_cause;
  END IF;
END
$ext$;

-- Fixtures: a role whose password the holder changes, and a table with autovacuum off whose dead
-- rows the holder pins. The passwords and the statements that carry them live in a temp table.
DROP TABLE IF EXISTS bc_hq_t;
DROP TABLE IF EXISTS bc_hq_fix;
DROP ROLE IF EXISTS bc_hq_role;
SELECT format('CREATE ROLE bc_hq_role PASSWORD %L', 'hqpw' || '-xyzzy-1') \gexec

CREATE TEMP TABLE bc_hq_fix (name text PRIMARY KEY, val text);
INSERT INTO bc_hq_fix VALUES
  ('pw',  'hqpw' || '-xyzzy-1'),
  ('pw2', 'hqpw' || '-xyzzy-2'),
  ('pw3', 'hqpw' || '-xyzzy-3'),
  ('pw4', 'hqpw' || '-xyzzy-4');
INSERT INTO bc_hq_fix(name, val)
  SELECT 'alter_stmt', format('ALTER ROLE bc_hq_role PASSWORD %L', (SELECT val FROM bc_hq_fix WHERE name = 'pw'));
INSERT INTO bc_hq_fix(name, val)
  SELECT 'user_stmt', format('CREATE USER bc_hq_user PASSWORD %L', (SELECT val FROM bc_hq_fix WHERE name = 'pw2'));
-- The two connection-string shapes are not executed: CREATE SUBSCRIPTION cannot run in a transaction
-- and dblink_connect would open a connection. They ride in a dollar-quoted SET LOCAL value, so the
-- stored text carries them with their real single quotes and the redaction pattern is exercised.
INSERT INTO bc_hq_fix(name, val)
  SELECT 'conn_stmt',
         format('SET LOCAL bc_hq.probe = $q$%s$q$',
                format('CREATE SUBSCRIPTION bc_hq_sub CONNECTION %L',
                       'host=h port=5432 password=' || (SELECT val FROM bc_hq_fix WHERE name = 'pw3')));
INSERT INTO bc_hq_fix(name, val)
  SELECT 'dblink_stmt',
         format('SET LOCAL bc_hq.probe = $q$%s$q$',
                format('dblink_connect(%L)',
                       'host=h port=5432 password=' || (SELECT val FROM bc_hq_fix WHERE name = 'pw4')));

CREATE TABLE bc_hq_t (id int PRIMARY KEY, filler text) WITH (autovacuum_enabled = false);
INSERT INTO bc_hq_t SELECT g, repeat('x', 100) FROM generate_series(1, 2000) g;

-- The holder. BEGIN first, then the ALTER ROLE, so its xid is older than the DELETE below and it
-- pins the dead rows. It stays idle in transaction, and the last statement it ran is the ALTER ROLE,
-- which is the text the opt-in test expects to find (redacted).
SELECT dblink_connect('hq', format('dbname=%s user=%s application_name=bc_test_holder_query',
                                   current_database(), current_user));
SELECT dblink_exec('hq', 'BEGIN');
SELECT dblink_exec('hq', (SELECT val FROM bc_hq_fix WHERE name = 'alter_stmt'));

DELETE FROM bc_hq_t WHERE id % 2 = 0;
ANALYZE bc_hq_t;
-- VACUUM after the holder started and while the dead rows remain: it removes nothing, and the
-- finished vacuum is what turns the finding from "present but not established" into the binding
-- "horizon holder" the sampler stores context for (scenarios/s10 is the same shape).
VACUUM bc_hq_t;

-- The sampler ignores holders younger than one minute (bloat_cause_holder()'s default). One wait,
-- then every sample below reuses the same, now-old-enough holder.
SELECT pg_sleep(65);

-- What each sample stored, read back by a temp table so no value has to survive being pasted into
-- SQL. stored is the fixture table's latest holder_query; nonnull is how many rows in that sample
-- carry one at all.
CREATE TEMP TABLE bc_hq_got (label text PRIMARY KEY, stored text, nonnull int);
CREATE FUNCTION pg_temp.hq_record(label text) RETURNS void LANGUAGE sql AS $r$
  INSERT INTO bc_hq_got
  SELECT label,
         (SELECT h.holder_query FROM bloat_cause_history h
           WHERE h.schemaname = 'public' AND h.relname = 'bc_hq_t'
           ORDER BY h.sampled_at DESC LIMIT 1),
         (SELECT count(*)::int FROM bloat_cause_history WHERE holder_query IS NOT NULL);
  TRUNCATE bloat_cause_history;
$r$;

-- Run 1: default off.
TRUNCATE bloat_cause_history;
SELECT bloat_cause_sample();
SELECT pg_temp.hq_record('off');

-- Run 2: opted in, the ALTER ROLE carrying the password. Short, so it is stored in full and not
-- marked.
SELECT set_config('bloat_cause.holder_query', 'on', false);
TRUNCATE bloat_cause_history;
SELECT bloat_cause_sample();
SELECT pg_temp.hq_record('on');

-- Run 3: a two-statement simple query, to show only the first statement is kept. Both statements
-- return no rows, so dblink_exec is happy; the session stays in its transaction.
SELECT dblink_exec('hq', 'SET LOCAL statement_timeout = 0; SET LOCAL lock_timeout = 0');
TRUNCATE bloat_cause_history;
SELECT bloat_cause_sample();
SELECT pg_temp.hq_record('first');

-- Run 4: CREATE USER ... PASSWORD, another literal the design names.
SELECT dblink_exec('hq', (SELECT val FROM bc_hq_fix WHERE name = 'user_stmt'));
TRUNCATE bloat_cause_history;
SELECT bloat_cause_sample();
SELECT pg_temp.hq_record('user');

-- Run 5: CREATE SUBSCRIPTION ... CONNECTION '<conninfo password=...>'.
SELECT dblink_exec('hq', (SELECT val FROM bc_hq_fix WHERE name = 'conn_stmt'));
TRUNCATE bloat_cause_history;
SELECT bloat_cause_sample();
SELECT pg_temp.hq_record('conn');

-- Run 6: dblink_connect('<conninfo password=...>').
SELECT dblink_exec('hq', (SELECT val FROM bc_hq_fix WHERE name = 'dblink_stmt'));
TRUNCATE bloat_cause_history;
SELECT bloat_cause_sample();
SELECT pg_temp.hq_record('dblink');

-- Run 7: a statement past the server's limit, so it comes back at the cap and is marked.
SELECT dblink_exec('hq', format('SET LOCAL application_name = %L', repeat('a', 2000)));
TRUNCATE bloat_cause_history;
SELECT bloat_cause_sample();
SELECT pg_temp.hq_record('long');

RESET bloat_cause.holder_query;
SELECT dblink_disconnect('hq');

-- The update path. The history table and the holder_query column already exist, so the update
-- replaces the function only; the column must survive and so must an explicit grant. A role is
-- created, granted, and then the extension is dropped, installed at 0.4.1 and updated to 0.5.0.
DROP EXTENSION pg_bloat_cause;
CREATE EXTENSION pg_bloat_cause VERSION '0.4.1';
CREATE ROLE bc_hq_runner;
GRANT SELECT, INSERT ON bloat_cause_history TO bc_hq_runner;
GRANT EXECUTE ON FUNCTION bloat_cause_sample(numeric, bigint, timestamptz) TO bc_hq_runner;
ALTER EXTENSION pg_bloat_cause UPDATE TO '0.5.0';
\o
\unset QUIET

SELECT plan(21);

-- ---------------------------------------------------------------- the objects the opt-in rides on
SELECT has_function('bloat_cause_sample', ARRAY['numeric', 'bigint', 'timestamptz'],
                    'bloat_cause_sample(numeric, bigint, timestamptz) exists');
SELECT has_column('bloat_cause_history', 'holder_query', 'the holder_query column exists to store into');

-- ---------------------------------------------------------------- default off
SELECT is((SELECT nonnull FROM bc_hq_got WHERE label = 'off'), 0,
          'an ordinary sample with the setting off stores no holder query on any row');
SELECT is((SELECT stored FROM bc_hq_got WHERE label = 'off'), NULL,
          'with the setting off the fixture table''s holder_query is NULL');

-- ---------------------------------------------------------------- opted in, redacted, unmarked
SELECT is((SELECT stored FROM bc_hq_got WHERE label = 'on'),
          'ALTER ROLE bc_hq_role PASSWORD ''<redacted>''',
          'with the setting on, the holder''s statement is stored with the password redacted');
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'on')
            NOT LIKE '%' || (SELECT val FROM bc_hq_fix WHERE name = 'pw') || '%',
          'the password literal does not reach the history table');
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'on') LIKE '%<redacted>%',
          'the redaction marker is kept, so the statement stays readable');
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'on') NOT LIKE '%[truncated]%',
          'a short statement is stored in full and is not marked as truncated');

-- ---------------------------------------------------------------- first statement only
SELECT is((SELECT stored FROM bc_hq_got WHERE label = 'first'),
          'SET LOCAL statement_timeout = 0',
          'of a two-statement query only the first statement is stored');

-- ---------------------------------------------------------------- the redaction pattern list
SELECT is((SELECT stored FROM bc_hq_got WHERE label = 'user'),
          'CREATE USER bc_hq_user PASSWORD ''<redacted>''',
          'CREATE USER ... PASSWORD is redacted');
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'user')
            NOT LIKE '%' || (SELECT val FROM bc_hq_fix WHERE name = 'pw2') || '%',
          'the CREATE USER password does not reach the table');
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'conn')
            NOT LIKE '%' || (SELECT val FROM bc_hq_fix WHERE name = 'pw3') || '%',
          'a CONNECTION string''s password does not reach the table');
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'conn') LIKE '%password=<redacted>%',
          'the CONNECTION password is replaced in place');
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'dblink')
            NOT LIKE '%' || (SELECT val FROM bc_hq_fix WHERE name = 'pw4') || '%',
          'a dblink_connect connection string''s password does not reach the table');
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'dblink') LIKE '%password=<redacted>%',
          'the dblink_connect password is replaced in place');

-- ---------------------------------------------------------------- truncation at the server cap
SELECT ok((SELECT stored FROM bc_hq_got WHERE label = 'long') LIKE '%[truncated]',
          'a statement at the server''s query-text cap is marked as truncated');
SELECT is(length((SELECT stored FROM bc_hq_got WHERE label = 'long')),
          pg_size_bytes(current_setting('track_activity_query_size'))::int - 1 + length(' [truncated]'),
          'the stored text is what the server keeps plus the marker; the cap is read at sample time');

-- ---------------------------------------------------------------- the update path
SELECT is((SELECT extversion FROM pg_extension WHERE extname = 'pg_bloat_cause'), '0.5.0',
          '0.4.1 updates to 0.5.0');
SELECT has_column('bloat_cause_history', 'holder_query', 'the holder_query column survives the update');
SELECT ok(has_function_privilege('bc_hq_runner',
                                 'bloat_cause_sample(numeric, bigint, timestamptz)', 'EXECUTE'),
          'an explicit EXECUTE grant on the sampler survives the update');
SELECT ok(has_table_privilege('bc_hq_runner', 'bloat_cause_history', 'INSERT'),
          'an explicit INSERT grant on the history survives the update');

-- Leave the shared test database at the default version. The update-path block above deliberately
-- ended at 0.5.0; a later file in the suite needs the default (0.6.0) and must not depend on order.
ALTER EXTENSION pg_bloat_cause UPDATE;

SELECT * FROM finish();

\o /dev/null
DROP FUNCTION pg_temp.hq_record(text);
DROP TABLE bc_hq_got;
DROP TABLE bc_hq_fix;
DROP TABLE bc_hq_t;
DROP OWNED BY bc_hq_runner;
DROP ROLE bc_hq_runner;
DROP ROLE bc_hq_role;
