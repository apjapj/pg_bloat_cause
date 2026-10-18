-- test/02_history.sql: the sampler, the history and the pruner, from step 6 and docs/detect.md.
--
-- The behaviours that matter here are the ones a single sample cannot show: that a table below the
-- floors is not recorded unless it is already in the series, that a sample taken across a
-- pg_stat_reset() is recorded as unknown rather than as a table that cleared, that the pruner drops
-- only what is old, and that a role granted the sampler sees only the tables it can read.
--
-- Written red-first where practical: it asserts the contract docs/detect.md settled before the SQL
-- existed. It calls every function 0.4.0 adds, because a function nothing calls is a function nobody
-- knows is broken (the bloat_cause_holder lesson).
--
-- The sample instants are held in the session setting bc_h.t0 and reused, because sampled_at is an
-- argument and every assertion has to name the same instant the sample wrote. Normal samples are
-- near t0 rather than backdated: the sampler compares the database statistics reset time, which on a
-- fresh cluster is the container's start, so a backdated fixture sample for a table with an earlier
-- sample would be read as a reset. Only the reset test backdates, and only where that is the point.
--
-- It leaves the history empty of its own rows and drops its fixtures, so test/03_detect.sql starts
-- on an idle database.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_bloat_cause;
-- One instant for the whole file, so every sampled_at the test passes is one the assertions can name.
SELECT set_config('bc_h.t0', statement_timestamp()::text, false);
\o
SELECT plan(24);

-- ---------------------------------------------------------------- the objects

SELECT has_table('bloat_cause_history', 'the history table exists');
SELECT columns_are('bloat_cause_history',
  ARRAY['sampled_at', 'schemaname', 'relname', 'dead_rows', 'dead_pct', 'dead_bytes',
        'dead_rows_source', 'holder_pid', 'holder_xid_age', 'holder_slot', 'holder_query'],
  'bloat_cause_history has exactly the columns docs/detect.md settles');
SELECT col_is_pk('bloat_cause_history', ARRAY['schemaname', 'relname', 'sampled_at'],
                 'one row per table per sample, the primary key detect.md settles');
SELECT has_function('bloat_cause_sample',
                    ARRAY['numeric', 'bigint', 'timestamp with time zone'],
                    'bloat_cause_sample(pct, bytes, at) exists');
SELECT has_function('bloat_cause_prune', ARRAY['interval'],
                    'bloat_cause_prune(older_than) exists');
SELECT ok(NOT has_function_privilege('public', 'bloat_cause_sample(numeric,bigint,timestamptz)', 'EXECUTE')
          AND NOT has_function_privilege('public', 'bloat_cause_prune(interval)', 'EXECUTE'),
          'neither writer is executable by PUBLIC: they write, unlike the readers');
SELECT ok(NOT has_table_privilege('public', 'bloat_cause_history', 'SELECT')
          AND NOT has_table_privilege('public', 'bloat_cause_history', 'INSERT'),
          'and the history is not readable or writable by PUBLIC');

-- The series is the user's data, so pg_dump carries it: the registration lives in the extconfig
-- column of pg_extension and resolves to this table.
SELECT is((SELECT count(*)::int
             FROM pg_extension e,
                  unnest(coalesce(e.extconfig, '{}'::oid[])) AS cfg(oid),
                  pg_class c
            WHERE e.extname = 'pg_bloat_cause' AND c.oid = cfg.oid
              AND c.relname = 'bloat_cause_history'),
          1, 'bloat_cause_history is registered with pg_extension_config_dump, so pg_dump keeps it');

-- ---------------------------------------------------------------- the fixture

-- autovacuum disabled and half the rows dead, so the table has a cause and needs no second session.
\o /dev/null
DROP TABLE IF EXISTS bc_h_series;
DROP TABLE IF EXISTS public.bc_h_other;
DELETE FROM bloat_cause_history WHERE relname IN ('bc_h_series', 'bc_h_other');
CREATE TABLE bc_h_series (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_h_series SELECT g, 'new' FROM generate_series(1, 2000) g;
ANALYZE bc_h_series;
UPDATE bc_h_series SET v = 'paid' WHERE id % 2 = 0;
\o
SELECT pg_sleep(1.5);
SELECT pg_stat_clear_snapshot();

-- ---------------------------------------------------------------- below the floor, then in the series

-- A byte floor above anything this table has: it is below the floor and not yet in the series, so no
-- row is written and it is counted instead.
\o /dev/null
SELECT sum(sampled)::int AS sampled, sum(below_floor)::int AS below_floor,
       sum(not_established)::int AS not_established
  FROM bloat_cause_sample(min_dead_pct => 0.1, min_dead_bytes => 1000000000,
                          sampled_at => current_setting('bc_h.t0')::timestamptz + interval '10 seconds')
\gset
\o
SELECT is((SELECT count(*)::int FROM bloat_cause_history
            WHERE relname = 'bc_h_series'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz + interval '10 seconds'), 0,
          'a table below both floors and not in the series gets no row');
SELECT ok(:below_floor::int >= 1,
          'and it is counted as below the floor rather than silently dropped');

-- Above the floor: at least one row, labelled estimated.
\o /dev/null
SELECT sum(sampled)::int AS sampled, sum(below_floor)::int AS below_floor,
       sum(not_established)::int AS not_established
  FROM bloat_cause_sample(min_dead_pct => 0.1, min_dead_bytes => 0,
                          sampled_at => current_setting('bc_h.t0')::timestamptz + interval '20 seconds')
\gset
\o
SELECT is((SELECT dead_rows_source FROM bloat_cause_history
            WHERE relname = 'bc_h_series'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz + interval '20 seconds'),
          'estimated', 'a table at or above both floors is sampled, and the row says estimated');
SELECT ok((SELECT dead_rows FROM bloat_cause_history
            WHERE relname = 'bc_h_series'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz + interval '20 seconds') > 0,
          'with the statistics'' dead-row count, above zero');
SELECT is(:sampled::int >= 1, true,
          'and the return value counts it as sampled');

-- Already in the series: sampled even when now below a floor, so a series that starts does not
-- silently stop.
\o /dev/null
SELECT sum(sampled)::int AS sampled, sum(below_floor)::int AS below_floor,
       sum(not_established)::int AS not_established
  FROM bloat_cause_sample(min_dead_pct => 0.1, min_dead_bytes => 1000000000,
                          sampled_at => current_setting('bc_h.t0')::timestamptz + interval '30 seconds')
\gset
\o
SELECT is((SELECT count(*)::int FROM bloat_cause_history
            WHERE relname = 'bc_h_series'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz + interval '30 seconds'), 1,
          'a table already in the series is sampled even below the floor');
SELECT is((SELECT dead_rows_source FROM bloat_cause_history
            WHERE relname = 'bc_h_series'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz + interval '30 seconds'),
          'estimated', 'and that row is an estimate too, because the sample never measures');

-- ---------------------------------------------------------------- a role granted only the sampler

-- PostgreSQL's statistics views are not filtered by privilege the way pg_stat_activity is, so
-- without a guard a role granted the sampler would read another role's tables into the shared
-- history. The sampler filters to the tables the caller can read, and this is the assertion for it:
-- the role samples its own table and not the one it was not granted.
\o /dev/null
DROP SCHEMA IF EXISTS bc_h_mine CASCADE;
DROP ROLE IF EXISTS bc_h_runner;
CREATE ROLE bc_h_runner;
CREATE SCHEMA bc_h_mine AUTHORIZATION bc_h_runner;
CREATE TABLE public.bc_h_other (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO public.bc_h_other SELECT g, 'new' FROM generate_series(1, 2000) g;
ANALYZE public.bc_h_other;
UPDATE public.bc_h_other SET v = 'paid' WHERE id % 2 = 0;
DELETE FROM bloat_cause_history WHERE relname IN ('mine', 'bc_h_other');
SET ROLE bc_h_runner;
CREATE TABLE bc_h_mine.mine (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_h_mine.mine SELECT g, 'new' FROM generate_series(1, 2000) g;
ANALYZE bc_h_mine.mine;
UPDATE bc_h_mine.mine SET v = 'paid' WHERE id % 2 = 0;
RESET ROLE;
GRANT EXECUTE ON FUNCTION bloat_cause_sample(numeric, bigint, timestamptz) TO bc_h_runner;
GRANT EXECUTE ON FUNCTION bloat_cause_findings(interval, bigint) TO bc_h_runner;
GRANT SELECT, INSERT ON bloat_cause_history TO bc_h_runner;
\o
SELECT pg_sleep(1.5);
SELECT pg_stat_clear_snapshot();

\o /dev/null
SET ROLE bc_h_runner;
SELECT sum(sampled)::int AS sampled, sum(below_floor)::int AS below_floor,
       sum(not_established)::int AS not_established
  FROM bloat_cause_sample(min_dead_pct => 0.1, min_dead_bytes => 0,
                          sampled_at => current_setting('bc_h.t0')::timestamptz + interval '40 seconds')
\gset
RESET ROLE;
\o
SELECT is((SELECT count(*)::int FROM bloat_cause_history
            WHERE schemaname = 'bc_h_mine' AND relname = 'mine'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz + interval '40 seconds'), 1,
          'a role granted the sampler samples a table it owns');
SELECT is((SELECT count(*)::int FROM bloat_cause_history
            WHERE schemaname = 'public' AND relname = 'bc_h_other'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz + interval '40 seconds'), 0,
          'and does not sample a table it was not granted, even though the statistics view shows it');

-- ---------------------------------------------------------------- a statistics reset is unknown

-- pg_stat_reset() zeroes n_dead_tup and moves the database statistics reset time. The next sample
-- of a table whose last sample predates the reset is recorded as unknown, with null figures, so the
-- drop to zero cannot read as a table that cleared. A caller passing sampled_at lays a fixture, so
-- the first sample here is backdated before the reset.
\o /dev/null
DROP TABLE IF EXISTS bc_h_reset;
CREATE TABLE bc_h_reset (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_h_reset SELECT g, 'new' FROM generate_series(1, 2000) g;
ANALYZE bc_h_reset;
UPDATE bc_h_reset SET v = 'paid' WHERE id % 2 = 0;
DELETE FROM bloat_cause_history WHERE relname = 'bc_h_reset';
\o
SELECT pg_sleep(1.5);
SELECT pg_stat_clear_snapshot();

\o /dev/null
SELECT sum(sampled)::int AS sampled, sum(below_floor)::int AS below_floor,
       sum(not_established)::int AS not_established
  FROM bloat_cause_sample(min_dead_pct => 0.1, min_dead_bytes => 0,
                          sampled_at => current_setting('bc_h.t0')::timestamptz - interval '1 minute')
\gset
SELECT pg_stat_reset();
SELECT sum(sampled)::int AS sampled, sum(below_floor)::int AS below_floor,
       sum(not_established)::int AS not_established
  FROM bloat_cause_sample(min_dead_pct => 0.1, min_dead_bytes => 0,
                          sampled_at => current_setting('bc_h.t0')::timestamptz + interval '50 seconds')
\gset
\o
SELECT is((SELECT dead_rows_source FROM bloat_cause_history
            WHERE relname = 'bc_h_reset' ORDER BY sampled_at DESC LIMIT 1),
          'unknown', 'a sample taken across a pg_stat_reset() is recorded as unknown');
SELECT is((SELECT dead_rows IS NULL AND dead_bytes IS NULL FROM bloat_cause_history
            WHERE relname = 'bc_h_reset' ORDER BY sampled_at DESC LIMIT 1),
          true, 'with null figures, so the reset cannot read as a drop to zero');
SELECT ok(:not_established::int >= 1,
          'and the return value counts it as not established rather than as sampled');

-- ---------------------------------------------------------------- pruning

-- An old sample is dropped by the pruner and a recent one is kept, so the cutoff is asserted in both
-- directions. The old row is laid with a past sampled_at, which is what that argument is for. A
-- dedicated fixture, because the pg_stat_reset() above zeroed every other table's counters.
\o /dev/null
DROP TABLE IF EXISTS bc_h_old;
CREATE TABLE bc_h_old (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_h_old SELECT g, 'new' FROM generate_series(1, 2000) g;
ANALYZE bc_h_old;
UPDATE bc_h_old SET v = 'paid' WHERE id % 2 = 0;
DELETE FROM bloat_cause_history WHERE relname = 'bc_h_old';
\o
SELECT pg_sleep(1.5);
SELECT pg_stat_clear_snapshot();

\o /dev/null
SELECT sum(sampled)::int AS sampled, sum(below_floor)::int AS below_floor,
       sum(not_established)::int AS not_established
  FROM bloat_cause_sample(min_dead_pct => 0.1, min_dead_bytes => 0,
                          sampled_at => current_setting('bc_h.t0')::timestamptz - interval '40 days')
\gset
SELECT bloat_cause_prune(older_than => interval '35 days') AS pruned \gset
\o
SELECT is(:sampled::int, 1, 'the old fixture is sampled at the past instant');
SELECT ok(:pruned::bigint >= 1, 'bloat_cause_prune() drops samples older than the given age');
SELECT is((SELECT count(*)::int FROM bloat_cause_history
            WHERE relname = 'bc_h_old'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz - interval '40 days'), 0,
          'and the old row is gone');
SELECT is((SELECT count(*)::int FROM bloat_cause_history
            WHERE relname = 'bc_h_series'
              AND sampled_at = current_setting('bc_h.t0')::timestamptz + interval '20 seconds'), 1,
          'while a row inside the window is kept');

-- ---------------------------------------------------------------- cleanup

\o /dev/null
DELETE FROM bloat_cause_history
 WHERE relname IN ('bc_h_series', 'bc_h_reset', 'bc_h_old', 'bc_h_other', 'mine');
DROP TABLE IF EXISTS bc_h_series;
DROP TABLE IF EXISTS bc_h_reset;
DROP TABLE IF EXISTS bc_h_old;
DROP TABLE IF EXISTS public.bc_h_other;
DROP SCHEMA IF EXISTS bc_h_mine CASCADE;
REVOKE ALL ON bloat_cause_history FROM bc_h_runner;
REVOKE ALL ON FUNCTION bloat_cause_sample(numeric, bigint, timestamptz) FROM bc_h_runner;
REVOKE ALL ON FUNCTION bloat_cause_findings(interval, bigint) FROM bc_h_runner;
DROP ROLE IF EXISTS bc_h_runner;
\o
SELECT * FROM finish();
