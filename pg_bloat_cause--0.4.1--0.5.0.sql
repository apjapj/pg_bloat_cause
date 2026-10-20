/* pg_bloat_cause--0.4.1--0.5.0.sql
 *
 * 0.5.0: bloat_cause_sample() grows the opt-in bloat_cause.holder_query. The history table and the
 * holder_query column already exist, so nothing is rewritten: this file replaces the one function.
 * When the GUC is on, new samples carry the holding session's first statement, redacted and
 * truncated; rows sampled before the opt-in stay NULL. Turning the GUC off does not erase text
 * already stored; UPDATE bloat_cause_history SET holder_query = NULL is the documented cleanup.
 */
\echo Use "ALTER EXTENSION pg_bloat_cause UPDATE TO '0.5.0'" to load this file. \quit

CREATE OR REPLACE FUNCTION @extschema@.bloat_cause_sample(min_dead_pct numeric DEFAULT 0.1,
                                               min_dead_bytes bigint DEFAULT 0,
                                               sampled_at timestamptz DEFAULT NULL)
RETURNS TABLE (kind text, sampled int, below_floor int, not_established int)
LANGUAGE plpgsql
-- A monitor never waits behind a lock, and reading the findings can.
SET lock_timeout = '1s'
AS $fn$
DECLARE
  at      timestamptz := coalesce(bloat_cause_sample.sampled_at, statement_timestamp());
  floor_p numeric     := coalesce(min_dead_pct, 0.1);
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

COMMENT ON FUNCTION @extschema@.bloat_cause_sample(numeric, bigint, timestamptz) IS
  'Append one sample of every table worth a row to bloat_cause_history: at or above both floors, or '
  'already in the series. Reads bloat_cause_findings() and never measures, so pgstattuple is never '
  'needed. Every figure it records is dead_rows_source = ''estimated''; a sample taken across a '
  'pg_stat_reset() or crash recovery writes a marker row with stats_reset = true and NULL figures, '
  'which re-baselines the series, and is reported in not_established. Runs with the caller''s rights '
  'and returns, per cause, how many it sampled, how many were below the floor, and how many were not '
  'established. holder_query is stored only when the session sets bloat_cause.holder_query on; it is '
  'the holder''s first statement, redacted and truncated and marked, and NULL otherwise. Schedule '
  'it; sampled_at is for fixtures.';
