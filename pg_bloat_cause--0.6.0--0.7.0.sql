/* pg_bloat_cause--0.6.0--0.7.0.sql
 *
 * 0.7.0 adds the statistics-based TOAST line and corrects min_dead_pct's default from 0.1 to 10.
 * The TOAST line is a secondary "then" line on the parent, never its own row and never primary.
 * pgstattuple remains the opt-in exact read; the default path reads statistics and catalog only.
 */
\echo Use "ALTER EXTENSION pg_bloat_cause UPDATE TO '0.7.0'" to load this file. \quit

-- -------------------------------------------------------------------------------------------------
-- bloat_cause_toast(): the TOAST line, from the TOAST table's own statistics.
-- -------------------------------------------------------------------------------------------------
-- TOAST is the parent's storage, vacuumed with it, so it is a secondary fact on the parent finding
-- and never its own row. The experiment in scripts/toast-estimate.sh shows pg_stat_all_tables does
-- carry live and dead tuples for the TOAST relation; on PostgreSQL 14 and 18 the dead-byte estimate
-- was 7 to 9 percent above pgstattuple_approx() and the dead percentage was exact. That is an
-- estimate, and the line says so; pgstattuple remains the opt-in exact read.
--
-- Material means the estimate itself is at least 10 percent dead AND at least 100 MB, the same pair
-- the heap notify rule uses. The boundary is applied to the estimate, which is why a boundary test
-- sits clear of 100 MB on both sides.
CREATE FUNCTION @extschema@.bloat_cause_toast(p_schema name, p_table name,
                                              p_parent_dead_bytes bigint DEFAULT NULL)
RETURNS TABLE (
  status              text,
  toast_relid         oid,
  toast_live          bigint,
  toast_dead          bigint,
  toast_bytes         bigint,
  dead_bytes          bigint,
  dead_pct            numeric,
  last_autovacuum     timestamptz,
  autovacuum_count    bigint,
  autovacuum_enabled  boolean,
  material            boolean,
  line                text
)
LANGUAGE plpgsql STABLE
SET lock_timeout = '1s'
AS $fn$
DECLARE
  v_relid  oid;
  v_toast  oid;
  v_opts   text[];
  v_live   bigint;
  v_dead   bigint;
  v_bytes  bigint;
  v_dbytes bigint;
  v_pct    numeric;
  v_av     boolean;
  v_mat    boolean;
  v_last   timestamptz;
  v_count  bigint;
BEGIN
  SELECT c.oid, c.reltoastrelid, tc.reloptions
    INTO v_relid, v_toast, v_opts
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_class tc ON tc.oid = c.reltoastrelid
   WHERE n.nspname = p_schema AND c.relname = p_table
     AND c.relkind IN ('r', 'm');

  IF v_relid IS NULL THEN
    RAISE EXCEPTION 'no table named %.%', p_schema, p_table USING ERRCODE = '42P01';
  END IF;

  IF coalesce(v_toast, 0) = 0 THEN
    RETURN QUERY SELECT 'none'::text, NULL::oid, NULL::bigint, NULL::bigint,
                        NULL::bigint, NULL::bigint, NULL::numeric,
                        NULL::timestamptz, NULL::bigint, NULL::boolean, false, NULL::text;
    RETURN;
  END IF;

  SELECT s.n_live_tup, s.n_dead_tup, s.last_autovacuum, s.autovacuum_count
    INTO v_live, v_dead, v_last, v_count
    FROM pg_stat_all_tables s
   WHERE s.relid = v_toast;

  IF NOT FOUND THEN
    RETURN QUERY SELECT 'not_established'::text, v_toast, NULL::bigint, NULL::bigint,
                        NULL::bigint, NULL::bigint, NULL::numeric,
                        NULL::timestamptz, NULL::bigint, NULL::boolean, false,
                        'TOAST: not established (no statistics row for the TOAST relation)'::text;
    RETURN;
  END IF;

  v_av := coalesce((SELECT option_value::bool FROM pg_options_to_table(v_opts)
                     WHERE option_name = 'autovacuum_enabled'), true)
          AND current_setting('autovacuum')::bool;

  IF coalesce(v_live, 0) + coalesce(v_dead, 0) = 0 THEN
    RETURN QUERY SELECT 'empty'::text, v_toast, v_live, v_dead, pg_relation_size(v_toast),
                        NULL::bigint, NULL::numeric, v_last, v_count, v_av, false,
                        CASE WHEN NOT v_av
                             THEN 'TOAST autovacuum is disabled separately (toast.autovacuum_enabled=false); its statistics are separate from the parent''s'
                             ELSE NULL::text END;
    RETURN;
  END IF;

  v_bytes  := pg_relation_size(v_toast);
  v_dbytes := (coalesce(v_dead, 0) * v_bytes / (v_live + v_dead))::bigint;
  v_pct    := round(100.0 * v_dead / (v_live + v_dead), 1);
  v_mat    := v_pct >= 10 AND v_dbytes >= 104857600;

  RETURN QUERY SELECT 'estimated'::text, v_toast, v_live, v_dead, v_bytes, v_dbytes, v_pct,
                      v_last, v_count, v_av, v_mat,
                      CASE
                        WHEN v_mat THEN
                          format('TOAST: ~%s, %s%% dead (estimated); VACUUM the parent cleans it too%s',
                                 pg_size_pretty(v_dbytes), v_pct,
                                 CASE WHEN NOT v_av
                                      THEN '; TOAST autovacuum is disabled separately (toast.autovacuum_enabled=false)'
                                      ELSE '' END)
                        WHEN NOT v_av THEN
                          'TOAST autovacuum is disabled separately (toast.autovacuum_enabled=false); its statistics are separate from the parent''s'
                        ELSE NULL::text
                      END;
END
$fn$;

COMMENT ON FUNCTION @extschema@.bloat_cause_toast(name, name, bigint) IS
  'The TOAST line for ONE parent table, from pg_stat_all_tables and pg_class. status is none, empty, '
  'estimated or not_established; the dead figures are estimated from the TOAST statistics, and the '
  'line says so. material means at least 10 percent dead AND at least 100 MB, applied to the estimate. '
  'The TOAST autovacuum setting is its own: toast.autovacuum_enabled=false is reported separately '
  'because the parent setting does not cover it. Never a row of its own and never the primary cause.';

CREATE OR REPLACE FUNCTION @extschema@.bloat_cause_findings(min_holder_age interval DEFAULT interval '1 minute',
                                                 min_standby_xid_gap bigint DEFAULT 1000)
RETURNS TABLE (
  schemaname        name,
  relname           name,
  relid             oid,
  dead_rows         bigint,
  dead_pct          numeric,
  dead_bytes        bigint,
  dead_rows_source  text,
  cause             text,
  cause_detail      text,
  cause_since       timestamptz,
  "then"            text[],
  unknowns          text[]
)
LANGUAGE plpgsql STABLE
AS $fn$
DECLARE
  newpage text := CASE WHEN current_setting('server_version_num')::int >= 160000
                       THEN 's.n_tup_newpage_upd' ELSE 'NULL::bigint' END;
  toast_join text := 'LEFT JOIN LATERAL (SELECT * FROM @extschema@.bloat_cause_toast(d.schemaname, d.relname, (d.n_dead_tup * d.heap_bytes / nullif(d.n_live_tup + d.n_dead_tup, 0))::bigint)) toast ON true';
BEGIN
  RETURN QUERY EXECUTE format($q$
  WITH
  -- Every horizon holder in the cluster, with the time it started where that is visible.
  -- The horizon holder, by asking bloat_cause_holder() rather than repeating the query. 0.1 through
  -- 0.2 kept this inline, and two copies of "what is holding the horizon back" is how they drift
  -- apart: one gets a fix and the other does not, and the sentences and the command disagree about
  -- which process is the blocker. bloat_cause_holder() is the single answer, and this is its first
  -- reader, so from 0.2 the holder is defined once and used everywhere.
  --
  -- Only the three columns the sentences use are taken: kind, who, since. The function returns more
  -- (pid, gid, slot_name, xid_age) because bloat_cause_command() needs the ones a statement needs,
  -- and none of those change what a sentence says, which is why every evidence file in this
  -- repository is byte-identical across this change. xid_age is still needed, to order.
  oldest AS (
    SELECT kind, who, since
      FROM @extschema@.bloat_cause_holder($1, $2)
     ORDER BY xid_age DESC NULLS LAST
     LIMIT 1
  ),
  t AS (
    SELECT s.schemaname, s.relname, s.relid, s.n_dead_tup, s.n_live_tup, s.n_ins_since_vacuum,
           s.n_tup_upd, s.n_tup_hot_upd, %s AS n_tup_newpage_upd,
           greatest(s.last_vacuum, s.last_autovacuum) AS last_clean,
           c.reltuples, c.reloptions,
           pg_relation_size(s.relid) AS heap_bytes
      FROM pg_stat_user_tables s
      JOIN pg_class c ON c.oid = s.relid
     WHERE s.n_dead_tup > 0
  ),
  opt AS (
    SELECT t.*,
           coalesce((SELECT option_value::bool FROM pg_options_to_table(t.reloptions) WHERE option_name = 'autovacuum_enabled'), true)
             AND current_setting('autovacuum')::bool AS av_on,
           coalesce((SELECT option_value::bigint FROM pg_options_to_table(t.reloptions) WHERE option_name = 'autovacuum_vacuum_threshold'),
                    current_setting('autovacuum_vacuum_threshold')::bigint)
           + coalesce((SELECT option_value::float8 FROM pg_options_to_table(t.reloptions) WHERE option_name = 'autovacuum_vacuum_scale_factor'),
                      current_setting('autovacuum_vacuum_scale_factor')::float8) * greatest(t.reltuples, 0) AS own_trigger,
           current_setting('autovacuum_vacuum_threshold')::bigint
           + current_setting('autovacuum_vacuum_scale_factor')::float8 * greatest(t.reltuples, 0) AS default_trigger,
           coalesce((SELECT option_value::bigint FROM pg_options_to_table(t.reloptions) WHERE option_name = 'autovacuum_vacuum_insert_threshold'),
                    current_setting('autovacuum_vacuum_insert_threshold')::bigint)
           + coalesce((SELECT option_value::float8 FROM pg_options_to_table(t.reloptions) WHERE option_name = 'autovacuum_vacuum_insert_scale_factor'),
                      current_setting('autovacuum_vacuum_insert_scale_factor')::float8) * greatest(t.reltuples, 0) AS own_insert_trigger
      FROM t
  ),
  -- A granted lock on the table, held by a client, in a mode that conflicts with the SHARE UPDATE
  -- EXCLUSIVE a vacuum needs. s7 measured that an ordinary autovacuum skips such a table rather than
  -- wait, so the lock is the evidence, not a waiting worker.
  locks AS (
    SELECT l.relation, min(a.pid) AS pid, string_agg(DISTINCT l.mode, ', ') AS modes, min(a.xact_start) AS since,
           min(coalesce(nullif(a.application_name, ''), 'no application_name')) AS app
      FROM pg_locks l
      JOIN pg_stat_activity a ON a.pid = l.pid
     WHERE l.locktype = 'relation' AND l.granted AND a.pid <> pg_backend_pid()
       AND a.backend_type = 'client backend'
       AND l.mode IN ('ShareUpdateExclusiveLock', 'ShareLock', 'ShareRowExclusiveLock', 'ExclusiveLock', 'AccessExclusiveLock')
     GROUP BY l.relation
  ),
  -- An anti-wraparound autovacuum waiting on a table. Unlike an ordinary one it does wait, visibly.
  wrap AS (
    SELECT l.relation, a.pid
      FROM pg_stat_activity a
      JOIN pg_locks l ON l.pid = a.pid AND NOT l.granted AND l.locktype = 'relation'
     WHERE a.backend_type = 'autovacuum worker' AND a.query LIKE '%%(to prevent wraparound)%%'
  ),
  judged AS (
    SELECT o.*,
           h.kind AS h_kind, h.who AS h_who, h.since AS h_since,
           -- Binding: a vacuum finished after the holder started and dead rows remain. For a standby
           -- the start is not visible, so a vacuum having run while its slot holds the oldest horizon
           -- is the test. With no vacuum at all, nothing is decided here: see unknowns.
           (h.kind IS NOT NULL AND o.last_clean IS NOT NULL
            AND (h.since IS NULL OR o.last_clean > h.since)) AS h_binds,
           -- Present but not established: no vacuum at all, or none since the holder started. Either
           -- way the dead rows may or may not be older than the holder, and only a VACUUM can tell.
           (h.kind IS NOT NULL AND NOT (o.last_clean IS NOT NULL AND (h.since IS NULL OR o.last_clean > h.since))) AS h_unknown,
           lk.pid AS lock_pid, lk.modes AS lock_modes, lk.since AS lock_since, lk.app AS lock_app,
           w.pid AS wrap_pid
      FROM opt o
      LEFT JOIN oldest h ON true
      LEFT JOIN locks lk ON lk.relation = o.relid
      LEFT JOIN wrap w ON w.relation = o.relid
  ),
  causes AS (
    SELECT j.*,
      array_remove(ARRAY[
        CASE WHEN j.h_binds THEN 'horizon holder' END,
        CASE WHEN j.wrap_pid IS NOT NULL THEN 'lock blocks anti-wraparound vacuum'
             WHEN j.lock_pid IS NOT NULL THEN 'lock keeps vacuum off' END,
        CASE WHEN NOT j.av_on THEN 'autovacuum disabled'
             WHEN j.n_dead_tup > j.default_trigger AND j.n_dead_tup <= j.own_trigger
                  AND coalesce(j.n_ins_since_vacuum, 0) <= j.own_insert_trigger THEN 'autovacuum thresholds not reached'
             WHEN j.n_dead_tup > j.own_trigger AND j.lock_pid IS NULL AND NOT coalesce(j.h_binds, false)
                  THEN 'autovacuum behind' END,
        CASE WHEN j.n_tup_upd > 0 AND j.n_tup_hot_upd::numeric / j.n_tup_upd < 0.5 THEN 'updates not HOT' END
      ], NULL) AS found
      FROM judged j
  ),
  described AS (
    SELECT c.*,
      ARRAY(SELECT CASE f
        WHEN 'horizon holder' THEN
          format('held back by %%s%%s%%s', c.h_who,
                 coalesce(' for ' || @extschema@.bloat_cause_age(statement_timestamp() - c.h_since), ''),
                 CASE WHEN c.h_kind = 'standby'
                      THEN '; the query holding it is on the standby, and the fix is there'
                      ELSE '' END)
        WHEN 'lock blocks anti-wraparound vacuum' THEN
          format('an anti-wraparound autovacuum is waiting on a lock that session %%s (%%s) has held for %%s (%%s)',
                 c.lock_pid, c.lock_app, @extschema@.bloat_cause_age(statement_timestamp() - c.lock_since), c.lock_modes)
        WHEN 'lock keeps vacuum off' THEN
          format('session %%s (%%s) has held %%s on it for %%s, which vacuum needs, so autovacuum skips the table',
                 c.lock_pid, c.lock_app, c.lock_modes, @extschema@.bloat_cause_age(statement_timestamp() - c.lock_since))
        WHEN 'autovacuum disabled' THEN
          format('autovacuum is disabled on this table (%%s dead rows against a threshold of %%s)', c.n_dead_tup, round(c.own_trigger))
        WHEN 'autovacuum thresholds not reached' THEN
          format('its own autovacuum thresholds (%%s dead rows, %%s inserted rows) are never reached', round(c.own_trigger), round(c.own_insert_trigger))
        WHEN 'autovacuum behind' THEN
          format('past its autovacuum threshold of %%s and not yet vacuumed', round(c.own_trigger))
        WHEN 'updates not HOT' THEN
          format('%%s of %%s updates were not HOT%%s', c.n_tup_upd - c.n_tup_hot_upd, c.n_tup_upd,
                 CASE WHEN c.n_tup_newpage_upd IS NULL
                      THEN '; on this version an indexed-column update cannot be told from a full page'
                      WHEN c.n_tup_upd - c.n_tup_hot_upd - c.n_tup_newpage_upd > 0
                      THEN format('; at least %%s because an indexed column changed', c.n_tup_upd - c.n_tup_hot_upd - c.n_tup_newpage_upd)
                      ELSE '; how many of them because an indexed column changed cannot be told' END)
        END FROM unnest(c.found) WITH ORDINALITY AS u(f, n) ORDER BY n) AS details
      FROM causes c
  )
  SELECT d.schemaname, d.relname, d.relid, d.n_dead_tup,
         round(100.0 * d.n_dead_tup / nullif(d.n_live_tup + d.n_dead_tup, 0), 1),
         (d.n_dead_tup * d.heap_bytes / nullif(d.n_live_tup + d.n_dead_tup, 0))::bigint,
         'estimated'::text,
         d.found[1],
         d.details[1],
         CASE d.found[1] WHEN 'horizon holder' THEN d.h_since
                         WHEN 'lock keeps vacuum off' THEN d.lock_since
                         WHEN 'lock blocks anti-wraparound vacuum' THEN d.lock_since END,
         coalesce(d.details[2:], '{}'::text[])
         || CASE WHEN toast.status IN ('estimated', 'empty') AND toast.line IS NOT NULL
                 THEN ARRAY[toast.line] ELSE '{}'::text[] END,
         -- A role without pg_read_all_stats sees other users' sessions with backend_xmin and xact_start
         -- hidden, so a session holding the horizon is simply absent from "holders" and the table's
         -- finding drops to the next cause down without a word. Found by testing the grants: the same
         -- table read "held back by session ..." with the role and "autovacuum is disabled" without it.
         -- Unknown must not be flattened into absent, so every row says what this role cannot see.
         CASE WHEN NOT (pg_has_role(current_user, 'pg_read_all_stats', 'USAGE')
                        OR (SELECT rolsuper FROM pg_roles WHERE rolname = current_user))
              THEN ARRAY['this role cannot see other users'' sessions (it lacks pg_read_all_stats), so a session holding these rows back would not appear here']
              ELSE '{}'::text[] END
         ||
         CASE WHEN d.h_unknown
              THEN ARRAY[format('%%s is present, but whether it holds these rows back is not established: %%s. Run VACUUM (VERBOSE) on it; "dead but not yet removable" above zero means it does',
                                d.h_who,
                                CASE WHEN d.last_clean IS NULL THEN 'this table has never been vacuumed'
                                     ELSE 'this table has not been vacuumed since it began' END)]
              ELSE '{}'::text[] END
         || CASE WHEN toast.status = 'not_established'
                 THEN ARRAY[toast.line] ELSE '{}'::text[] END
    FROM described d
%s
   WHERE cardinality(d.found) > 0 OR d.h_unknown
   ORDER BY 6 DESC NULLS LAST
  $q$, newpage, toast_join) USING min_holder_age, min_standby_xid_gap;
END
$fn$;

CREATE OR REPLACE FUNCTION @extschema@.bloat_cause_sample(min_dead_pct numeric DEFAULT 10,
                                               min_dead_bytes bigint DEFAULT 0,
                                               sampled_at timestamptz DEFAULT NULL)
RETURNS TABLE (kind text, sampled int, below_floor int, not_established int)
LANGUAGE plpgsql
-- A monitor never waits behind a lock, and reading the findings can.
SET lock_timeout = '1s'
AS $fn$
DECLARE
  at      timestamptz := coalesce(bloat_cause_sample.sampled_at, statement_timestamp());
  floor_p numeric     := coalesce(min_dead_pct, 10);
  floor_b bigint      := coalesce(min_dead_bytes, 0);
  -- The opt-in. current_setting(..., true) is NULL when never set; a typo, or the '' RESET leaves
  -- behind, is not one of the on words and so is off.
  query_on boolean := lower(coalesce(current_setting('bloat_cause.holder_query', true), 'off'))
                      IN ('on', 'true', '1', 'yes');
  reset_at timestamptz;
  h_since timestamptz;
  h_pid   int;
  h_slot  text;
  h_query text;
  r       record;
  k       text;
  -- The rows to insert, one entry per array position, plus the per-kind counters.
  ins_schema name[]    := '{}';
  ins_rel    name[]    := '{}';
  ins_dr     bigint[]  := '{}';
  ins_dp     numeric[] := '{}';
  ins_db     bigint[]  := '{}';
  ins_src    text[]    := '{}';
  ins_reset  boolean[] := '{}';
  ins_hpid   int[]     := '{}';
  ins_hage   interval[]:= '{}';
  ins_hslot  text[]    := '{}';
  ins_hq     text[]    := '{}';
  ks         text[]    := '{}';
  c_s        int[]     := '{}';
  c_b        int[]     := '{}';
  c_x        int[]     := '{}';
  sampled_n  int := 0;
  below_n    int := 0;
  unknown_n  int := 0;
BEGIN
  IF NOT has_table_privilege('@extschema@.bloat_cause_history', 'INSERT')
     OR NOT has_table_privilege('@extschema@.bloat_cause_history', 'SELECT') THEN
    RAISE EXCEPTION USING ERRCODE = 'insufficient_privilege',
      MESSAGE = 'bloat_cause_sample() needs SELECT and INSERT on bloat_cause_history; nothing was sampled',
      HINT = 'GRANT SELECT, INSERT ON bloat_cause_history TO the role that runs the sample (INSTALL.md).';
  END IF;

  -- The database statistics reset time. A sample taken after a reset for a table whose last sample
  -- predates it writes a marker row (stats_reset = true, NULL figures) so the series re-baselines,
  -- and is counted in not_established: the drop to zero is never recorded as a real reading.
  SELECT pg_stat_get_db_stat_reset_time(d.oid) INTO reset_at
    FROM pg_database d WHERE d.datname = current_database();

  -- The oldest horizon holder, the same one bloat_cause_findings() binds to every table: the
  -- primary has exactly one, and this is where its pid, age, slot and query come from. The query is
  -- read once here from pg_stat_activity; it is NULL for a prepared or standby holder, which has no
  -- pid, and it is NULL to a caller without pg_read_all_stats.
  SELECT h.since, h.pid, h.slot_name::text, a.query
    INTO h_since, h_pid, h_slot, h_query
    FROM @extschema@.bloat_cause_holder() h
    LEFT JOIN pg_stat_activity a ON a.pid = h.pid
   ORDER BY h.xid_age DESC NULLS LAST
   LIMIT 1;

  -- Opt-in, redaction, truncation, in that order. With the GUC off the column stays NULL whatever
  -- the holder ran, which is the default and the whole point.
  IF query_on AND h_query IS NOT NULL THEN
    -- Only the first statement. A multi-statement simple query is stored whole in pg_stat_activity,
    -- and the statements after the first are not this column's to keep.
    h_query := split_part(h_query, ';', 1);
    -- The credential shapes the design names: the literal after PASSWORD in CREATE/ALTER ROLE or
    -- USER. $rx$ is a dollar-quote tag only so the quotes below need no doubling; it names nothing.
    -- The pattern redacts to the end of the text, which also drops any clause after the password,
    -- deliberately: two statements differing only in a password must read the same afterwards.
    h_query := regexp_replace(
      h_query,
      $rx$(?i)(\m(?:CREATE|ALTER)\s+(?:ROLE|USER)\M[\s\S]*?\mPASSWORD(?:\s|/\*[\s\S]*?\*/)*)(?:[EU]&?)?(?:'|\$)[\s\S]*$rx$,
      $rx$\1'<redacted>'$rx$, 'g');
    -- A connection string: CREATE SUBSCRIPTION ... CONNECTION '<conninfo>' with password=... in it.
    h_query := regexp_replace(
      h_query,
      $rx$(?i)(\mCONNECTION\s+'[^']*?\mpassword\s*=\s*)(?:'(?:[^']|'')*'|[^\s';]+)$rx$,
      $rx$\1<redacted>$rx$, 'g');
    -- The same shape through dblink: dblink_connect('<conninfo>').
    h_query := regexp_replace(
      h_query,
      $rx$(?i)(\mdblink_connect\s*\(\s*'[^']*?\mpassword\s*=\s*)(?:'(?:[^']|'')*'|[^\s';]+)$rx$,
      $rx$\1<redacted>$rx$, 'g');
    -- The server's own cap, read at sample time. pg_stat_activity.query holds at most
    -- track_activity_query_size - 1 characters and does not say whether it cut the text, so the
    -- marker appears when the stored length REACHES that limit as well as when it passes the
    -- sampler's own 1024 bytes. A query the server cut is then never presented as complete; the
    -- cost is that a query that is exactly one character under the cap is marked too.
    IF length(h_query) >= pg_size_bytes(current_setting('track_activity_query_size'))::int - 1
       OR length(h_query) > 1024 THEN
      h_query := left(h_query, 1024) || ' [truncated]';
    END IF;
  ELSE
    h_query := NULL;
  END IF;

  FOR r IN
    WITH f AS (
      SELECT x.schemaname, x.relname, x.dead_rows, x.dead_pct, x.dead_bytes, x.cause
        FROM @extschema@.bloat_cause_findings() x
    ),
    hist AS (
      SELECT DISTINCT h.schemaname, h.relname FROM @extschema@.bloat_cause_history h
      UNION
      SELECT f.schemaname, f.relname FROM f
    )
    SELECT h.schemaname, h.relname,
           f.dead_rows, f.dead_pct, f.dead_bytes, f.cause,
           (f.relname IS NOT NULL) AS in_findings,
           prev.sampled_at AS prev_at
      FROM hist h
      LEFT JOIN f ON f.schemaname = h.schemaname AND f.relname = h.relname
      LEFT JOIN LATERAL (
        SELECT x.sampled_at FROM @extschema@.bloat_cause_history x
         WHERE x.schemaname = h.schemaname AND x.relname = h.relname
           AND x.sampled_at < at
         ORDER BY x.sampled_at DESC
         LIMIT 1
      ) prev ON true
      LEFT JOIN pg_class c ON c.relname = h.relname
                          AND c.relnamespace = (SELECT n.oid FROM pg_namespace n WHERE n.nspname = h.schemaname)
     -- A role samples only the tables it can read. PostgreSQL statistics views are not filtered by
     -- privilege the way pg_stat_activity is, so without this a role granted the sampler would read
     -- another role's tables into the shared history. The filter is the guarantee detect.md states.
     WHERE c.oid IS NOT NULL AND has_table_privilege(c.oid, 'SELECT')
  LOOP
    -- A sample taken across a statistics reset is unknown, not a clear, and it writes a MARKER row
    -- flagged stats_reset = true with NULL figures and no holder context. Writing no row at all
    -- (the previous design) left the pre-reset row as the table's latest sample, so reset_at >
    -- prev_at stayed true on every later sample and the table was never sampled again until that row
    -- was pruned, up to 35 days; that is the persistence flaw this row fixes. The marker is the first
    -- post-reset row, so the next sample's previous row is the marker, reset_at is no longer newer
    -- than it, and the series resumes with an ordinary row. The figures are NULL because the change
    -- across the reset cannot be computed: a post-reset reading recorded as if it continued the
    -- series would invite a delta that does not exist. dead_rows_source stays 'estimated' and is not
    -- a third value. The sample counts in not_established, not sampled: a row was written, but the
    -- sample across the reset is the thing that is not established. The table is grouped under its
    -- cause kind, so the per-kind totals stay honest.
    IF r.prev_at IS NOT NULL AND reset_at IS NOT NULL AND reset_at > r.prev_at THEN
      k := coalesce(r.cause, 'no cause');
      ks := ks || k; c_s := c_s || 0; c_b := c_b || 0; c_x := c_x || 1;
      unknown_n := unknown_n + 1;
      ins_schema := ins_schema || r.schemaname; ins_rel := ins_rel || r.relname;
      ins_dr := ins_dr || NULL::bigint; ins_dp := ins_dp || NULL::numeric; ins_db := ins_db || NULL::bigint;
      ins_src := ins_src || 'estimated'::text; ins_reset := ins_reset || true;
      ins_hpid := ins_hpid || NULL::int; ins_hage := ins_hage || NULL::interval; ins_hslot := ins_hslot || NULL::text;
      ins_hq := ins_hq || NULL::text;
      CONTINUE;
    END IF;

    -- Not in the current findings and no reset in between: the table genuinely left the sampled set
    -- (it was vacuumed, or it lost its cause). That is not this function's to record.
    CONTINUE WHEN NOT r.in_findings;

    IF (r.dead_pct >= floor_p AND r.dead_bytes >= floor_b) OR r.prev_at IS NOT NULL THEN
      -- Sampled: at or above both floors, or already in the series so it does not silently stop.
      k := coalesce(r.cause, 'no cause');
      ks := ks || k; c_s := c_s || 1; c_b := c_b || 0; c_x := c_x || 0;
      sampled_n := sampled_n + 1;
      ins_schema := ins_schema || r.schemaname; ins_rel := ins_rel || r.relname;
      ins_dr := ins_dr || r.dead_rows; ins_dp := ins_dp || r.dead_pct; ins_db := ins_db || r.dead_bytes;
      ins_src := ins_src || 'estimated'::text; ins_reset := ins_reset || false;
      IF r.cause = 'horizon holder' THEN
        ins_hpid := ins_hpid || h_pid;
        ins_hage := ins_hage || (at - h_since);
        ins_hslot := ins_hslot || h_slot;
        ins_hq := ins_hq || h_query;
      ELSE
        ins_hpid := ins_hpid || NULL::int; ins_hage := ins_hage || NULL::interval; ins_hslot := ins_hslot || NULL::text;
        ins_hq := ins_hq || NULL::text;
      END IF;
    ELSE
      -- Below both floors and not in the series: counted, not recorded.
      k := coalesce(r.cause, 'no cause');
      ks := ks || k; c_s := c_s || 0; c_b := c_b || 1; c_x := c_x || 0;
      below_n := below_n + 1;
    END IF;
  END LOOP;

  INSERT INTO @extschema@.bloat_cause_history
    (sampled_at, schemaname, relname, dead_rows, dead_pct, dead_bytes, dead_rows_source, stats_reset,
     holder_pid, holder_xid_age, holder_slot, holder_query)
  SELECT at, u.schemaname, u.relname, u.dead_rows, u.dead_pct, u.dead_bytes, u.dead_rows_source, u.stats_reset,
         u.holder_pid, u.holder_xid_age, u.holder_slot, u.holder_query
    FROM unnest(ins_schema, ins_rel, ins_dr, ins_dp, ins_db, ins_src, ins_reset,
                ins_hpid, ins_hage, ins_hslot, ins_hq)
      AS u(schemaname, relname, dead_rows, dead_pct, dead_bytes, dead_rows_source, stats_reset,
           holder_pid, holder_xid_age, holder_slot, holder_query)
  ON CONFLICT DO NOTHING;

  RETURN QUERY
    SELECT t.kk, sum(t.s)::int, sum(t.b)::int, sum(t.x)::int
      FROM unnest(ks, c_s, c_b, c_x) AS t(kk, s, b, x)
     GROUP BY t.kk
     ORDER BY t.kk;
END
$fn$;

CREATE OR REPLACE FUNCTION @extschema@.bloat_cause_notify(channel text DEFAULT 'bloat_cause',
                                               min_dead_pct numeric DEFAULT 10,
                                               min_dead_bytes bigint DEFAULT 104857600,
                                               min_holder_age interval DEFAULT interval '1 minute')
RETURNS bigint
LANGUAGE plpgsql
-- A monitor never waits behind a lock, and reading the findings can.
SET lock_timeout = '1s'
AS $fn$
DECLARE
  ch        text    := channel;
  floor_p   numeric := coalesce(min_dead_pct, 10);
  floor_b   bigint  := coalesce(min_dead_bytes, 104857600);
  f         record;
  prior     record;
  subj      text;
  rung      integer;
  v         numeric;
  new_level integer;
  prev_level integer;
  raised    bigint := 0;
BEGIN
  -- The ladder is min_dead_bytes times ten, so a first rung below one has no ladder to climb.
  IF floor_b < 1 THEN
    RAISE EXCEPTION 'min_dead_bytes must be at least 1: the escalation ladder starts at min_dead_bytes and steps by factors of ten'
      USING ERRCODE = '22023';
  END IF;

  FOR f IN SELECT * FROM @extschema@.bloat_cause_findings(min_holder_age) LOOP
    CONTINUE WHEN f.dead_pct IS NULL OR f.dead_bytes IS NULL;
    -- Gated on BOTH floors.
    CONTINUE WHEN f.dead_pct < floor_p OR f.dead_bytes < floor_b;

    subj := format('%I.%I', f.schemaname, f.relname);

    -- The rung: 1 at min_dead_bytes, 2 at ten times it, and on with no fixed top. Numeric so a very
    -- large table cannot overflow bigint while the ladder is being walked.
    rung := 1;
    v := floor_b;
    WHILE f.dead_bytes >= v * 10 LOOP
      rung := rung + 1;
      v := v * 10;
    END LOOP;

    SELECT * INTO prior FROM @extschema@.bloat_cause_alert a
     WHERE a.channel = ch AND a.subject = subj;

    IF NOT FOUND THEN
      -- Onset: the first time this table is notable on this channel. Always worth telling someone.
      INSERT INTO @extschema@.bloat_cause_alert
        (channel, subject, severity, notify_count, dead_bytes, dead_pct, cause, notified_at)
      VALUES (ch, subj, rung, 1, f.dead_bytes, f.dead_pct, f.cause, statement_timestamp());
      new_level  := 1;
      prev_level := NULL;
    ELSIF rung > prior.severity THEN
      -- Escalation: a higher rung than the highest already notified, never merely higher than the
      -- previous sample.
      UPDATE @extschema@.bloat_cause_alert a
         SET severity     = rung,
             notify_count = a.notify_count + 1,
             dead_bytes   = greatest(a.dead_bytes, f.dead_bytes),
             dead_pct     = f.dead_pct,
             cause        = f.cause,
             notified_at  = statement_timestamp()
       WHERE a.channel = ch AND a.subject = subj;
      new_level  := prior.notify_count + 1;
      prev_level := prior.notify_count;
    ELSE
      -- Notable but no higher than the last notification: stay quiet, which is the whole point.
      CONTINUE;
    END IF;

    PERFORM pg_notify(ch, json_build_object(
      -- The five required keys of the shared contract, in pg_lock_tree's order.
      'tool',              'pg_bloat_cause',
      'subject',           subj,
      'sampled_at',        statement_timestamp(),
      'channel',           ch,
      'event',             'alerting',
      -- The two escalation keys. level is the count read AFTER the increment: 1 at onset, and the
      -- prior count plus one at each escalation. previous_level is that minus one, so it is present
      -- and null at onset and a number at an escalation. An incident that first appears already past
      -- the first rung still alerts at level 1 and climbs one notification at a time.
      'level',             new_level,
      'previous_level',    prev_level,
      -- The figures, with the estimate label and dead_pct beside dead_bytes so a reader sees both.
      'dead_rows',         f.dead_rows,
      'dead_pct',          f.dead_pct,
      'dead_bytes',        f.dead_bytes,
      'dead_rows_source',  f.dead_rows_source,
      -- The cause, and the sentence that names the holder as a then: line rather than a second
      -- subject, so a listener's dedup key does not change identity when the holder changes.
      'cause',             f.cause,
      'cause_detail',      f.cause_detail
    )::text);
    raised := raised + 1;
  END LOOP;

  RETURN raised;
END
$fn$;

CREATE OR REPLACE FUNCTION @extschema@.bloat_cause_notify_resolved(channel text DEFAULT 'bloat_cause',
                                                        min_dead_pct numeric DEFAULT 10,
                                                        min_dead_bytes bigint DEFAULT 104857600,
                                                        min_holder_age interval DEFAULT interval '1 minute')
RETURNS bigint
LANGUAGE plpgsql
SET lock_timeout = '1s'
AS $fn$
DECLARE
  ch       text    := channel;
  floor_p  numeric := coalesce(min_dead_pct, 10);
  floor_b  bigint  := coalesce(min_dead_bytes, 104857600);
  reset_at     timestamptz;
  latest       timestamptz;
  latest_reset boolean;
  s        record;
  f        record;
  raised   bigint := 0;
BEGIN
  -- The database statistics reset time, kept for the window between a reset and the next sample. The
  -- sampler now writes a marker row (stats_reset = true) across a reset, and that flag is the primary
  -- signal; the reset time catches the case where the latest sample predates a reset that has not yet
  -- been sampled. Either one means unknown.
  SELECT pg_stat_get_db_stat_reset_time(d.oid) INTO reset_at
    FROM pg_database d WHERE d.datname = current_database();

  FOR s IN SELECT * FROM @extschema@.bloat_cause_alert a WHERE a.channel = ch LOOP
    SELECT * INTO f FROM @extschema@.bloat_cause_findings(min_holder_age) x
     WHERE format('%I.%I', x.schemaname, x.relname) = s.subject;

    -- Leaving the sampled set is no longer watched, not cleared.
    CONTINUE WHEN NOT FOUND;

    -- A subject whose latest sample is a reset marker (stats_reset = true) is unknown, not resolved:
    -- the sampler wrote that row precisely because the counters were reset, and the readings either
    -- side of it are not comparable. A latest sample that simply predates the reset time is unknown
    -- too, which covers the window before any post-reset sample is taken. A subject with no history
    -- at all (latest is NULL) has nothing that predates the reset and is not held back. This is the
    -- rule that matters most: NEVER send cleared when the state is unknown.
    SELECT h.sampled_at, h.stats_reset INTO latest, latest_reset
      FROM @extschema@.bloat_cause_history h
     WHERE format('%I.%I', h.schemaname, h.relname) = s.subject
     ORDER BY h.sampled_at DESC
     LIMIT 1;
    CONTINUE WHEN latest IS NOT NULL
                  AND (latest_reset OR (reset_at IS NOT NULL AND latest < reset_at));

    -- Still at or above both thresholds: still standing, so a resolution now would be noise.
    CONTINUE WHEN f.dead_pct >= floor_p AND f.dead_bytes >= floor_b;

    PERFORM pg_notify(ch, json_build_object(
      -- The same keys as the onset payload, so a listener can pair the two on subject.
      'tool',          'pg_bloat_cause',
      'subject',       s.subject,
      'sampled_at',    statement_timestamp(),
      'event',         'cleared',
      -- The last level the incident reached, read from the state. previous_level is deliberately
      -- ABSENT, not present-and-null: a cleared payload has no escalation.
      'level',         s.notify_count,
      'channel',       ch,
      -- What it reached, so a reader knows whether it was ever serious.
      'dead_at_most',  s.dead_bytes,
      'cause',         s.cause
    )::text);

    DELETE FROM @extschema@.bloat_cause_alert a WHERE a.channel = ch AND a.subject = s.subject;
    raised := raised + 1;
  END LOOP;

  RETURN raised;
END
$fn$;
