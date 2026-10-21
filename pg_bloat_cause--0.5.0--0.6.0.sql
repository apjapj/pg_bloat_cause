/* pg_bloat_cause--0.5.0--0.6.0.sql
 *
 * 0.6.0 adds bloat_cause_context(schema, table): the autovacuum context for one table, from
 * pg_stat_user_tables and pg_class. It answers "has autovacuum even tried?" next to the findings,
 * without changing any existing row type or calling pgstattuple.
 */
\echo Use "ALTER EXTENSION pg_bloat_cause UPDATE TO '0.6.0'" to load this file. \quit

-- -------------------------------------------------------------------------------------------------
-- bloat_cause_context(): the autovacuum context for one table.
-- -------------------------------------------------------------------------------------------------
-- The findings say why dead rows are not being removed. This answers the question that comes next:
-- has autovacuum even tried? It reads pg_stat_user_tables and pg_class only, so it is cheap and works
-- without pgstattuple. It is deliberately separate from bloat_cause_findings(): adding columns to a
-- function's row type is a drop and recreate, while a new function is an additive release.
--
-- Counts are cumulative since the last pg_stat_reset() or crash recovery, like the statistics they
-- come from. last_clean is greatest(last_vacuum, last_autovacuum), the same figure findings uses to
-- decide whether a vacuum has run since a horizon holder started. n_tup_newpage_upd is NULL on
-- PostgreSQL 14 and 15, where the statistic does not exist.
CREATE FUNCTION @extschema@.bloat_cause_context(p_schema name, p_table name)
RETURNS TABLE (
  schemaname                    name,
  relname                       name,
  relid                         oid,
  relkind                       "char",
  n_live_tup                    bigint,
  n_dead_tup                    bigint,
  n_mod_since_analyze           bigint,
  n_ins_since_vacuum            bigint,
  n_tup_ins                     bigint,
  n_tup_upd                     bigint,
  n_tup_del                     bigint,
  n_tup_hot_upd                 bigint,
  n_tup_newpage_upd             bigint,
  last_vacuum                   timestamptz,
  last_autovacuum               timestamptz,
  last_clean                    timestamptz,
  last_analyze                  timestamptz,
  last_autoanalyze              timestamptz,
  vacuum_count                  bigint,
  autovacuum_count              bigint,
  analyze_count                 bigint,
  autoanalyze_count             bigint,
  reltuples                     real,
  relpages                      integer,
  heap_bytes                    bigint,
  autovacuum_enabled            boolean,
  vacuum_threshold              bigint,
  vacuum_scale_factor           float8,
  vacuum_insert_threshold       bigint,
  vacuum_insert_scale_factor    float8,
  analyze_threshold             bigint,
  analyze_scale_factor          float8
)
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  -- n_tup_newpage_upd appeared in PostgreSQL 16. A SQL function naming it would fail to parse on
  -- 14 and 15, so the expression is chosen here and substituted into the dynamic query.
  newpage text := CASE WHEN current_setting('server_version_num')::int >= 160000
                       THEN 's.n_tup_newpage_upd' ELSE 'NULL::bigint' END;
BEGIN
  RETURN QUERY EXECUTE format($q$
    SELECT s.schemaname, s.relname, s.relid, c.relkind,
           s.n_live_tup, s.n_dead_tup, s.n_mod_since_analyze, s.n_ins_since_vacuum,
           s.n_tup_ins, s.n_tup_upd, s.n_tup_del, s.n_tup_hot_upd, %s,
           s.last_vacuum, s.last_autovacuum,
           greatest(s.last_vacuum, s.last_autovacuum) AS last_clean,
           s.last_analyze, s.last_autoanalyze,
           s.vacuum_count, s.autovacuum_count, s.analyze_count, s.autoanalyze_count,
           c.reltuples, c.relpages, pg_relation_size(s.relid),
           coalesce((SELECT option_value::bool FROM pg_options_to_table(c.reloptions)
                      WHERE option_name = 'autovacuum_enabled'), true)
             AND current_setting('autovacuum')::bool AS autovacuum_enabled,
           coalesce((SELECT option_value::bigint FROM pg_options_to_table(c.reloptions)
                      WHERE option_name = 'autovacuum_vacuum_threshold'),
                    current_setting('autovacuum_vacuum_threshold')::bigint)
             AS vacuum_threshold,
           coalesce((SELECT option_value::float8 FROM pg_options_to_table(c.reloptions)
                      WHERE option_name = 'autovacuum_vacuum_scale_factor'),
                    current_setting('autovacuum_vacuum_scale_factor')::float8)
             AS vacuum_scale_factor,
           coalesce((SELECT option_value::bigint FROM pg_options_to_table(c.reloptions)
                      WHERE option_name = 'autovacuum_vacuum_insert_threshold'),
                    current_setting('autovacuum_vacuum_insert_threshold')::bigint)
             AS vacuum_insert_threshold,
           coalesce((SELECT option_value::float8 FROM pg_options_to_table(c.reloptions)
                      WHERE option_name = 'autovacuum_vacuum_insert_scale_factor'),
                    current_setting('autovacuum_vacuum_insert_scale_factor')::float8)
             AS vacuum_insert_scale_factor,
           coalesce((SELECT option_value::bigint FROM pg_options_to_table(c.reloptions)
                      WHERE option_name = 'autovacuum_analyze_threshold'),
                    current_setting('autovacuum_analyze_threshold')::bigint)
             AS analyze_threshold,
           coalesce((SELECT option_value::float8 FROM pg_options_to_table(c.reloptions)
                      WHERE option_name = 'autovacuum_analyze_scale_factor'),
                    current_setting('autovacuum_analyze_scale_factor')::float8)
             AS analyze_scale_factor
      FROM pg_stat_user_tables s
      JOIN pg_class c ON c.oid = s.relid
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = $1 AND c.relname = $2
       AND c.relkind IN ('r', 'm', 'p')
  $q$, newpage) USING p_schema, p_table;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'no table named %.%', p_schema, p_table USING ERRCODE = '42P01';
  END IF;
END
$fn$;

COMMENT ON FUNCTION @extschema@.bloat_cause_context(name, name) IS
  'The autovacuum context for ONE table: live and dead row estimates, insert/update/HOT counts, '
  'the last manual and automatic vacuum and analyze times and counts, heap size, whether autovacuum '
  'is enabled, and the resolved vacuum, insert and analyze thresholds and scale factors. Read-only, '
  'statistics and catalogs only, no pgstattuple. n_tup_newpage_upd is NULL before PostgreSQL 16.';

-- Closed like the other readers: a role sees the table only when its own privileges allow it.
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_context(name, name) FROM PUBLIC;

