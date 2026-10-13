-- pg_bloat_cause 0.1 -> 0.2: one function, and nothing else changes
--
-- 0.2 adds bloat_cause_holder(), the horizon holder in structured form. It exists because
-- bloat_cause_command() has to emit a statement naming a pid or a gid, and 0.1 named the holder
-- only in cause_detail, which is prose. There is no way to get a pid out of an English sentence
-- without parsing it, and parsing prose produces the wrong pid silently when a wording changes.
--
-- Nothing existing is altered. bloat_cause_findings() keeps its own inline copy of the holder
-- logic in this release, so every sentence and every evidence file is byte-identical to 0.1. The
-- switch to the shared function is a separate change whose only claim is that nothing moves, and
-- that is checked by the scenario suite refusing to pass if any evidence file differs.
--
-- The new function is granted the way the other two are: not to PUBLIC, because it reads
-- pg_stat_activity and pg_prepared_xacts.

\echo Use "ALTER EXTENSION pg_bloat_cause UPDATE TO '0.2'" to load this file. \quit

CREATE FUNCTION @extschema@.bloat_cause_holder(min_holder_age interval DEFAULT interval '1 minute',
                                               min_standby_xid_gap bigint DEFAULT 1000)
RETURNS TABLE (
  kind             text,
  pid              int,
  gid              text,
  slot_name        name,
  application_name text,
  state            text,
  who              text,
  since            timestamptz,
  xid_age          integer
)
LANGUAGE plpgsql STABLE
AS $fn$
BEGIN
  -- The two parameters ride in as EXECUTE placeholders, bound by the USING clause below, which
  -- is the mechanism bloat_cause_findings() uses. format() is what makes that necessary rather
  -- than optional: it substitutes percent specifiers only, so a template written with positional
  -- parameters and then passed to format() arrives at the engine with them still literal text and
  -- fails with "there is no parameter". Copying this function's shape from findings() without
  -- copying its USING clause is how the first version of this shipped broken.
  --
  -- A note for whoever edits the comments above, because it cost an afternoon: do not name the
  -- dollar-quote tags inside a dollar-quoted body. Writing a tag pair in a comment here closes a
  -- quote that was never opened, the parser ends the function body early, and the error you get
  -- is "mismatched parentheses" pointing at the USING clause several dozen lines away.
  RETURN QUERY EXECUTE format($q$
  SELECT 'session' AS kind,
         a.pid AS pid,
         NULL::text AS gid,
         NULL::name AS slot_name,
         coalesce(nullif(a.application_name, ''), 'no application_name') AS application_name,
         a.state AS state,
         -- The same three arguments as before, in the same order, so `who` is unchanged.
         format('session %%s (%%s, %%s)', a.pid,
                coalesce(nullif(a.application_name, ''), 'no application_name'), a.state) AS who,
         a.xact_start AS since,
         age(coalesce(a.backend_xid, a.backend_xmin)) AS xid_age
    FROM pg_stat_activity a
   WHERE a.pid <> pg_backend_pid()
     AND a.backend_type = 'client backend'
     AND (a.backend_xid IS NOT NULL OR a.backend_xmin IS NOT NULL)
     AND a.xact_start < statement_timestamp() - $1
  UNION ALL
  SELECT 'prepared' AS kind,
         NULL::int AS pid,
         p.gid AS gid,
         NULL::name AS slot_name,
         NULL::text AS application_name,
         NULL::text AS state,
         format('prepared transaction %%L', p.gid) AS who,
         p.prepared AS since,
         age(p.transaction) AS xid_age
    FROM pg_prepared_xacts p
   WHERE p.prepared < statement_timestamp() - $1
  UNION ALL
  -- A standby's feedback through its physical slot. The primary cannot see when the standby's
  -- query began, so "since" is NULL; s3 measured that the walsender's backend_xmin is NULL here
  -- and the slot's xmin is where the horizon is.
  SELECT 'standby' AS kind,
         NULL::int AS pid,
         NULL::text AS gid,
         sl.slot_name AS slot_name,
         coalesce(r.application_name, 'unknown') AS application_name,
         NULL::text AS state,
         format('standby %%s through slot %%s', coalesce(r.application_name, 'unknown'), sl.slot_name) AS who,
         NULL::timestamptz AS since,
         age(sl.xmin) AS xid_age
    FROM pg_replication_slots sl
    LEFT JOIN pg_stat_replication r ON r.pid = sl.active_pid
   WHERE sl.slot_type = 'physical' AND sl.xmin IS NOT NULL
     -- Only when the standby holds back further than anything on the primary itself, by at least
     -- min_standby_xid_gap xids. An idle standby's slot always has an xmin, and between its feedback
     -- messages (wal_receiver_status_interval, 10 s by default) that xmin LAGS the primary's own
     -- horizon by however many xids were assigned meanwhile. The primary cannot tell that lag from a
     -- query holding the standby's xmin still: it never sees when the standby's query began, and this
     -- extension keeps no history to see the xmin not moving. So the gap is a heuristic, in xids, and
     -- it is a parameter. Found by the scenario suite, where an idle standby's lag made every table in
     -- one s8 run report a standby as present.
     --
     -- The default of 1000 is a documented guess, not a tuned value, and it is too LOW for a busy
     -- primary: at a few hundred xids a second, one feedback interval (10 s) is several thousand xids
     -- of ordinary lag, so an idle standby on such a cluster can still trip it. Expect to raise it on
     -- busy primaries, to roughly the xids assigned in two or three feedback intervals. The scenario
     -- clusters are quiet, which is why 1000 held there.
     --
     -- The ::text::xid round trip is load-bearing: pg_snapshot_xmin() returns xid8 and age() takes
     -- xid, and there is no direct cast between the two. Through text keeps the low 32 bits, which is
     -- what age() needs.
     AND age(sl.xmin) - age(pg_snapshot_xmin(pg_current_snapshot())::text::xid) >= $2
  $q$) USING min_holder_age, min_standby_xid_gap;
END
$fn$;

COMMENT ON FUNCTION @extschema@.bloat_cause_holder(interval, bigint) IS
  'Every horizon holder in the cluster, structured: a client session, a prepared transaction, or a standby holding back through its physical slot. One row per holder, oldest first when ordered by xid_age. bloat_cause_findings() reads this rather than keeping its own copy, and bloat_cause_command() needs it because a statement to run needs a pid or a gid rather than an English sentence. A logical replication slot is deliberately absent: it holds catalog_xmin, which protects catalog rows and is reported separately, never as a user-table holder. s2 asserts that.';

REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_holder(interval, bigint) FROM PUBLIC;
