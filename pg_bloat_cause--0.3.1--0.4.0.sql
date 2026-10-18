-- pg_bloat_cause 0.3.1 -> 0.4.0: the sampler, the history, and the alerting
--
-- Step 6 of README.md, settled in docs/detect.md before the SQL was written. Three things arrive:
--
--   bloat_cause_history       the sampled series, registered for pg_dump
--   bloat_cause_sample()      append one sample of every table worth a row
--   bloat_cause_prune()       drop samples older than an age
--   bloat_cause_notify()      raise one NOTIFY per onset or escalation
--   bloat_cause_notify_resolved()  raise one cleared NOTIFY when a watched table is below the floor
--   bloat_cause_alert         the state the two senders share, one row per subject per channel
--
-- Nothing existing changes: bloat_cause_findings(), bloat_cause_text(), bloat_cause_holder(),
-- bloat_cause_command() and bloat_cause_measure() keep their shapes, every estimate stays on the
-- statistics and pgstattuple stays optional and untouching. This script only adds objects and
-- rewrites nothing, so no CREATE OR REPLACE is needed and no grant is restated.
--
-- The sampler reads bloat_cause_findings() and never measures. It writes dead_rows_source =
-- 'estimated' on every row it records. A sample taken across a pg_stat_reset() or crash recovery
-- writes no row at all and is reported in not_established instead, so a reset cannot read as a table
-- that cleared. See docs/detect.md for the whole reasoning.

\echo Use "ALTER EXTENSION pg_bloat_cause UPDATE TO '0.4.0'" to load this file. \quit

-- -------------------------------------------------------------------------------------------------
-- bloat_cause_history: the sampled series.
-- -------------------------------------------------------------------------------------------------
-- One row per table per sample. The columns are the table's identity, the estimated dead figures,
-- the source label that says where the figures came from, and the context of the horizon holder that
-- was pinning the table at the time. holder_query is always NULL in 0.4.0: query text is stored only
-- through an explicit opt-in, and this release ships none (docs/detect.md), so the column exists and
-- stays empty rather than holding text that would have to be redacted on every sample.
CREATE TABLE @extschema@.bloat_cause_history (
  sampled_at        timestamptz NOT NULL,
  schemaname        name        NOT NULL,
  relname           name        NOT NULL,
  dead_rows         bigint,
  dead_pct          numeric,
  dead_bytes        bigint,
  dead_rows_source  text        NOT NULL,
  holder_pid        int,
  holder_xid_age    interval,
  holder_slot       text,
  holder_query      text,
  PRIMARY KEY (schemaname, relname, sampled_at)
);

-- Pruning reads by time across every key, which the primary key cannot serve.
CREATE INDEX bloat_cause_history_sampled_at_idx
  ON @extschema@.bloat_cause_history (sampled_at);

COMMENT ON TABLE @extschema@.bloat_cause_history IS
  'Samples written by bloat_cause_sample(), one row per table per sample. dead_rows, dead_pct and '
  'dead_bytes are estimates from pg_stat_user_tables, and dead_rows_source says so: it is '
  '''estimated'' on every row this table holds. A sample taken across a pg_stat_reset() or crash '
  'recovery writes NO row at all, so a reset cannot be read as a table that cleared; the gap in the '
  'series is the record and the sampler reports it in not_established. holder_pid, holder_xid_age and '
  'holder_slot are the horizon holder that was pinning the table when its cause was ''horizon '
  'holder'', NULL otherwise. holder_query is always NULL in 0.4.0: storing query text needs an '
  'explicit opt-in and this release ships none. Prune with bloat_cause_prune().';

-- The samples are the user's data, not the extension's, so pg_dump keeps them: a series is what
-- makes a trend readable after the fact.
SELECT pg_catalog.pg_extension_config_dump('@extschema@.bloat_cause_history', '');

-- -------------------------------------------------------------------------------------------------
-- bloat_cause_sample(): append one sample.
-- -------------------------------------------------------------------------------------------------
-- Reads bloat_cause_findings() and never measures, so it never touches pgstattuple. A table is
-- sampled when it is at or above both floors, or when it is already in the history, so a series that
-- starts does not silently stop when the table falls below the floor. A table below the floor and
-- not already in the history is counted, not recorded.
--
-- The floors are arguments with defaults, not a setting: these extensions have no configuration of
-- their own, and sampled_at is already an argument, so a GUC would add global state the history
-- table cannot reproduce. The same for the sampler as for limit_runway_sample().
--
-- One INSERT for the whole sample rather than one per table, so the row count is bounded by the
-- number of tables and the write is a single statement.
--
-- A sample taken across a statistics reset writes NO row and is counted in not_established. The gap in
-- the series is the record; writing a row would either record a false drop to zero or put a
-- dead_rows_source value the view never reports into the shared history, and 'unknown' is not a value
-- that column takes. The sender decides "unknown" for itself, from the reset time.
CREATE FUNCTION @extschema@.bloat_cause_sample(min_dead_pct numeric DEFAULT 0.1,
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
  reset_at timestamptz;
  h_since timestamptz;
  h_pid   int;
  h_slot  text;
  r       record;
  k       text;
  -- The rows to insert, one entry per array position, plus the per-kind counters.
  ins_schema name[]    := '{}';
  ins_rel    name[]    := '{}';
  ins_dr     bigint[]  := '{}';
  ins_dp     numeric[] := '{}';
  ins_db     bigint[]  := '{}';
  ins_src    text[]    := '{}';
  ins_hpid   int[]     := '{}';
  ins_hage   interval[]:= '{}';
  ins_hslot  text[]    := '{}';
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
  -- predates it writes no row: the drop to zero is never recorded, and the gap is reported instead.
  SELECT pg_stat_get_db_stat_reset_time(d.oid) INTO reset_at
    FROM pg_database d WHERE d.datname = current_database();

  -- The oldest horizon holder, the same one bloat_cause_findings() binds to every table: the
  -- primary has exactly one, and this is where its pid, age and slot come from.
  SELECT h.since, h.pid, h.slot_name::text INTO h_since, h_pid, h_slot
    FROM @extschema@.bloat_cause_holder() h
   ORDER BY h.xid_age DESC NULLS LAST
   LIMIT 1;

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
    -- A sample taken across a statistics reset is unknown, not a clear, and it writes NO row. The gap
    -- in the series is the record, and it is visible in the not_established count below rather than
    -- hidden in a row: dead_rows_source keeps its meaning, 'estimated' on every row the view and the
    -- sampler write, and 'unknown' is not a value it takes. The table is grouped under its cause kind,
    -- so the per-kind totals stay honest. Because no row is written, the sender cannot look for a
    -- marker: bloat_cause_notify_resolved() decides unknown from the reset time itself.
    IF r.prev_at IS NOT NULL AND reset_at IS NOT NULL AND reset_at > r.prev_at THEN
      k := coalesce(r.cause, 'no cause');
      ks := ks || k; c_s := c_s || 0; c_b := c_b || 0; c_x := c_x || 1;
      unknown_n := unknown_n + 1;
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
      ins_src := ins_src || 'estimated'::text;
      IF r.cause = 'horizon holder' THEN
        ins_hpid := ins_hpid || h_pid;
        ins_hage := ins_hage || (at - h_since);
        ins_hslot := ins_hslot || h_slot;
      ELSE
        ins_hpid := ins_hpid || NULL::int; ins_hage := ins_hage || NULL::interval; ins_hslot := ins_hslot || NULL::text;
      END IF;
    ELSE
      -- Below both floors and not in the series: counted, not recorded.
      k := coalesce(r.cause, 'no cause');
      ks := ks || k; c_s := c_s || 0; c_b := c_b || 1; c_x := c_x || 0;
      below_n := below_n + 1;
    END IF;
  END LOOP;

  INSERT INTO @extschema@.bloat_cause_history
    (sampled_at, schemaname, relname, dead_rows, dead_pct, dead_bytes, dead_rows_source,
     holder_pid, holder_xid_age, holder_slot, holder_query)
  SELECT at, u.schemaname, u.relname, u.dead_rows, u.dead_pct, u.dead_bytes, u.dead_rows_source,
         u.holder_pid, u.holder_xid_age, u.holder_slot, NULL
    FROM unnest(ins_schema, ins_rel, ins_dr, ins_dp, ins_db, ins_src,
                ins_hpid, ins_hage, ins_hslot)
      AS u(schemaname, relname, dead_rows, dead_pct, dead_bytes, dead_rows_source,
           holder_pid, holder_xid_age, holder_slot)
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
  'pg_stat_reset() or crash recovery writes no row and is reported in not_established. Runs with the '
  'caller''s rights and returns, per cause, how many it sampled, how many were below the floor, and '
  'how many were not established. Schedule it; sampled_at is for fixtures.';

-- -------------------------------------------------------------------------------------------------
-- bloat_cause_prune(): drop samples older than an age.
-- -------------------------------------------------------------------------------------------------
-- One statement, not batches: a function cannot commit between batches, so batching inside one buys
-- nothing. The sampled_at index bounds it.
CREATE FUNCTION @extschema@.bloat_cause_prune(older_than interval DEFAULT interval '35 days')
RETURNS bigint
LANGUAGE sql
AS $$
  WITH d AS (
    DELETE FROM @extschema@.bloat_cause_history
     WHERE sampled_at < statement_timestamp() - older_than
    RETURNING 1
  )
  SELECT count(*) FROM d
$$;

COMMENT ON FUNCTION @extschema@.bloat_cause_prune(interval) IS
  'Delete samples older than older_than, default 35 days: a month of history to explain a trend and '
  'to outlive a vacation. Returns how many rows went.';

-- -------------------------------------------------------------------------------------------------
-- bloat_cause_alert: the state the two senders share.
-- -------------------------------------------------------------------------------------------------
-- One row per subject per channel, holding the severity last notified. Escalation compares the
-- current rung against this, never against the previous sample: a quantity that only grows would be
-- "worse than last time" on every sample and would notify every sample. The level the contract
-- carries is the notification count, not the rung, so an incident that first appears already past
-- the first rung still alerts at level 1 and climbs one notification at a time.
CREATE TABLE @extschema@.bloat_cause_alert (
  channel       text        NOT NULL,
  subject       text        NOT NULL,
  severity      integer     NOT NULL,
  notify_count  integer     NOT NULL,
  dead_bytes    bigint      NOT NULL,
  dead_pct      numeric,
  cause         text,
  notified_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (channel, subject)
);

COMMENT ON TABLE @extschema@.bloat_cause_alert IS
  'One row per table per channel, holding the severity (escalation rung) last notified and the level '
  '(notification count) the shared pg_incident_watch contract carries. Escalation compares against '
  'severity, never against the previous sample, so a table that sits at the same rung stays silent. '
  'Managed by bloat_cause_notify() and bloat_cause_notify_resolved(); you should never need to touch '
  'it.';

-- bloat_cause_notify(): raise one NOTIFY per onset or escalation.
--
-- A table is notable when it is BOTH at least min_dead_pct dead AND at least min_dead_bytes of dead
-- space, so a huge table at 2 percent and a tiny table at 60 percent each stay quiet. The first rung
-- IS min_dead_bytes, and each rung above it is ten times the one below, with no fixed top. The rung
-- is compared against the highest already notified, so a large table that sits still notifies once.
--
-- The payload is the shared pg_incident_watch contract: tool, subject, sampled_at, event and channel,
-- plus level and previous_level for escalation. subject is the schema-qualified relation name,
-- format('%I.%I', schemaname, relname), the same identity bloat_cause_findings() prints and the same
-- one a listener reading a log a week later can resolve without the OID.
--
-- A statistics reset is neither an onset nor a resolution here, and no guard is invented for it.
-- pg_stat_reset() zeroes n_dead_tup, so every affected table leaves bloat_cause_findings() and this
-- loop, which walks the findings, simply never sees it: nothing is raised from a table that is no
-- longer notable, and nothing in this function clears state. A table that comes back after a reset is
-- a current, real reading, so the onset or escalation it raises from that reading is a real change,
-- not the reset mistaken for one. The one place a reset could be misread, a "cleared" for a table
-- whose counters were merely reset, is decided in bloat_cause_notify_resolved(), which refuses to
-- clear a subject whose latest sample predates the reset; because that state is kept, a mere
-- re-appearance cannot be re-raised as a fresh onset either.
CREATE FUNCTION @extschema@.bloat_cause_notify(channel text DEFAULT 'bloat_cause',
                                               min_dead_pct numeric DEFAULT 0.1,
                                               min_dead_bytes bigint DEFAULT 104857600,
                                               min_holder_age interval DEFAULT interval '1 minute')
RETURNS bigint
LANGUAGE plpgsql
-- A monitor never waits behind a lock, and reading the findings can.
SET lock_timeout = '1s'
AS $fn$
DECLARE
  ch        text    := channel;
  floor_p   numeric := coalesce(min_dead_pct, 0.1);
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

COMMENT ON FUNCTION @extschema@.bloat_cause_notify(text, numeric, bigint, interval) IS
  'Raise a NOTIFY on channel when a table is at least min_dead_pct dead AND at least min_dead_bytes '
  'of dead space, again on each ten-times rung above min_dead_bytes, and once per subject. The rung '
  'is compared against the highest already notified, never against the previous sample, so a table '
  'that sits still notifies once. The payload is the shared pg_incident_watch contract, carrying '
  'level and previous_level. Returns how many it raised, so zero is the normal result. Schedule it '
  'beside bloat_cause_sample().';

-- bloat_cause_notify_resolved(): one cleared NOTIFY when a watched table is no longer bad enough.
--
-- A table that is still watched (present in bloat_cause_findings()) and now below the alert threshold
-- is cleared. A table that has left the findings entirely is not watched, so it is NOT cleared:
-- absence of data is not recovery, and a table that dropped out of the sampled set must not read as
-- resolved.
--
-- "Unknown" is decided from the reset time, not from a marker row, because the sampler writes none
-- across a reset. A subject whose most recent history sample is older than the current statistics
-- reset time was last seen before the reset, and the drop to zero that followed must not be read as
-- recovery: it is held back and its state is kept. The rule that matters most is that a clear is
-- never sent when the state is unknown. A subject with no history at all has nothing older than the
-- reset and is not held back, which is what lets a fixture that never sampled still be cleared.
CREATE FUNCTION @extschema@.bloat_cause_notify_resolved(channel text DEFAULT 'bloat_cause',
                                                        min_dead_pct numeric DEFAULT 0.1,
                                                        min_dead_bytes bigint DEFAULT 104857600,
                                                        min_holder_age interval DEFAULT interval '1 minute')
RETURNS bigint
LANGUAGE plpgsql
SET lock_timeout = '1s'
AS $fn$
DECLARE
  ch       text    := channel;
  floor_p  numeric := coalesce(min_dead_pct, 0.1);
  floor_b  bigint  := coalesce(min_dead_bytes, 104857600);
  reset_at timestamptz;
  latest   timestamptz;
  s        record;
  f        record;
  raised   bigint := 0;
BEGIN
  -- The database statistics reset time. The sampler writes no row across a reset, so the sender cannot
  -- look for a marker: it compares the subject's latest sample against the reset time instead.
  SELECT pg_stat_get_db_stat_reset_time(d.oid) INTO reset_at
    FROM pg_database d WHERE d.datname = current_database();

  FOR s IN SELECT * FROM @extschema@.bloat_cause_alert a WHERE a.channel = ch LOOP
    SELECT * INTO f FROM @extschema@.bloat_cause_findings(min_holder_age) x
     WHERE format('%I.%I', x.schemaname, x.relname) = s.subject;

    -- Leaving the sampled set is no longer watched, not cleared.
    CONTINUE WHEN NOT FOUND;

    -- A subject whose most recent sample is older than the statistics reset time is unknown, not
    -- resolved: it was last seen before the reset, and the counters read as zero since. There is no
    -- marker row to key on, so the latest sample is compared against the reset time itself. A subject
    -- with no history at all (latest is NULL) has nothing that predates the reset and is not held
    -- back. This is the rule that matters most: NEVER send cleared when the state is unknown.
    SELECT max(h.sampled_at) INTO latest
      FROM @extschema@.bloat_cause_history h
     WHERE format('%I.%I', h.schemaname, h.relname) = s.subject;
    CONTINUE WHEN latest IS NOT NULL AND reset_at IS NOT NULL AND latest < reset_at;

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

COMMENT ON FUNCTION @extschema@.bloat_cause_notify_resolved(text, numeric, bigint, interval) IS
  'Raise one cleared NOTIFY per table that had alerted and is still watched but now below the alert '
  'threshold, then forget its state so the same table bloating again alerts from onset. A table that '
  'has left bloat_cause_findings() is not watched and is not cleared, and a subject whose most recent '
  'sample is older than the statistics reset time is unknown and is not cleared either: the sampler '
  'writes no row across a reset, so the sender compares the latest sample against the reset time. '
  'Run it beside bloat_cause_notify() with the same thresholds.';

-- The writers are closed like the readers. They write to this extension's own tables and are not
-- executable by PUBLIC by default; INSTALL.md names the grants a monitoring role needs.
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_sample(numeric, bigint, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_prune(interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_notify(text, numeric, bigint, interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_notify_resolved(text, numeric, bigint, interval) FROM PUBLIC;
