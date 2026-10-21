-- test/05_context.sql: bloat_cause_context() reports the autovacuum context for one table.
--
-- The findings say why dead rows are not being removed. This function answers the next question:
-- has autovacuum even tried? It must read the statistics only, resolve per-table reloptions against
-- the cluster defaults, and stay closed like the other readers.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;

CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_bloat_cause;
-- test/04_holder_query ends its update-path block at 0.5.0. The suite shares one database, so bring
-- the extension back to the default before calling a function added in 0.6.0.
ALTER EXTENSION pg_bloat_cause UPDATE;

DROP TABLE IF EXISTS bc_ctx_orders;
CREATE TABLE bc_ctx_orders (id int PRIMARY KEY, status text)
  WITH (autovacuum_enabled = false,
        autovacuum_vacuum_threshold = 42,
        autovacuum_vacuum_scale_factor = 0.5,
        autovacuum_analyze_threshold = 7,
        autovacuum_analyze_scale_factor = 0.2);
INSERT INTO bc_ctx_orders SELECT g, 'new' FROM generate_series(1, 100) g;
VACUUM (ANALYZE) bc_ctx_orders;
\o
SELECT pg_sleep(1);
SELECT pg_stat_clear_snapshot();

SELECT plan(13);

SELECT has_function('bloat_cause_context', ARRAY['name', 'name'],
                    'bloat_cause_context(name, name) exists');
SELECT is((SELECT count(*)::int FROM bloat_cause_context('public', 'bc_ctx_orders')), 1,
          'it returns exactly one row for one table');
SELECT is((SELECT relkind FROM bloat_cause_context('public', 'bc_ctx_orders')), 'r'::"char",
          'and the row is the ordinary table, with its relkind');
SELECT is((SELECT autovacuum_enabled FROM bloat_cause_context('public', 'bc_ctx_orders')), false,
          'autovacuum_enabled is false because the table reloption says so');
SELECT is((SELECT vacuum_threshold FROM bloat_cause_context('public', 'bc_ctx_orders')), 42::bigint,
          'the per-table vacuum threshold is used, not the cluster default');
SELECT is((SELECT vacuum_scale_factor FROM bloat_cause_context('public', 'bc_ctx_orders')), 0.5::float8,
          'and the per-table scale factor');
SELECT is((SELECT analyze_threshold FROM bloat_cause_context('public', 'bc_ctx_orders')), 7::bigint,
          'the per-table analyze threshold');
SELECT is((SELECT analyze_scale_factor FROM bloat_cause_context('public', 'bc_ctx_orders')), 0.2::float8,
          'and the per-table analyze scale factor');
SELECT ok((SELECT heap_bytes FROM bloat_cause_context('public', 'bc_ctx_orders')) > 0,
          'heap_bytes is the heap size, above zero');
SELECT ok((SELECT last_vacuum IS NOT NULL FROM bloat_cause_context('public', 'bc_ctx_orders')),
          'last_vacuum is recorded after a manual VACUUM');
SELECT ok((SELECT n_live_tup FROM bloat_cause_context('public', 'bc_ctx_orders')) > 0,
          'n_live_tup comes from the statistics, above zero');
SELECT throws_ok($$ SELECT * FROM bloat_cause_context('public', 'bc_ctx_missing') $$, '42P01',
                 'no table named public.bc_ctx_missing',
                 'a missing table raises instead of returning an empty row');
SELECT ok(NOT has_function_privilege('public', 'bloat_cause_context(name,name)', 'EXECUTE'),
          'the context is closed like the other readers');

-- ---------------------------------------------------------------- cleanup
\o /dev/null
DROP TABLE IF EXISTS bc_ctx_orders;
\o
SELECT * FROM finish();
