/* pg_bloat_cause--0.2.sql
 *
 * What's slowing down: for each table with dead rows, the cause, ranked as docs/ranking.md decides,
 * in one sentence. Diagnose only. Read-only: no writes, no VACUUM, no state of its own.
 *
 *   bloat_cause                   view: one row per table with a finding, most dead bytes first
 *   bloat_cause_findings(age)     the same, with the minimum horizon-holder age as an argument
 *   bloat_cause_text(age)         the sentence form, one line per table
 *   bloat_cause_holder(age, gap)  every horizon holder, structured: kind, pid, gid, slot, who
 *
 * The decisions behind the shape are in docs/design.md, each with the scenario evidence that forced it.
 */
\echo Use "CREATE EXTENSION pg_bloat_cause" to load this file. \quit

DO $floor$
BEGIN
  IF current_setting('server_version_num')::int < 140000 THEN
    RAISE EXCEPTION 'pg_bloat_cause needs PostgreSQL 14 or later; this is %', current_setting('server_version')
      USING HINT = 'The floor is 14 because the statistics it reads, and pg_stat_activity''s backend_xmin semantics it relies on, are what this version was tested against.';
  END IF;
END
$floor$;

-- Compact interval rendering for the sentence form: 45s, 12 min, 3 h 05 min, 4 days.
CREATE FUNCTION @extschema@.bloat_cause_age(i interval)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT CASE
    WHEN i IS NULL THEN NULL
    WHEN i < interval '1 minute' THEN extract(epoch FROM i)::int || 's'
    WHEN i < interval '1 hour'   THEN floor(extract(epoch FROM i) / 60)::int || ' min'
    WHEN i < interval '2 days'   THEN floor(extract(epoch FROM i) / 3600)::int || ' h '
                                      || lpad((floor(extract(epoch FROM i) / 60)::int % 60)::text, 2, '0') || ' min'
    ELSE floor(extract(epoch FROM i) / 86400)::int || ' days'
  END
$$;

-- The findings. One row per table with dead rows and at least one cause, secondary cause or unknown.
--
-- Ranking (docs/ranking.md): the primary cause is the most upstream one present, where upstream means
-- "stops the remedy for the others from working":
--   1 horizon holder that binds this table   (no VACUUM can remove the rows)
--   2 lock that keeps vacuum off the table   (no VACUUM can start on it)
--   3 autovacuum disabled, thresholds never reached, or behind   (only the automatic VACUUM is stopped)
--   4 updates that cannot be HOT             (blocks nothing; a tuning note)
-- Everything present below the primary goes in "then", in that order. A holder whose binding cannot be
-- established (the table was never vacuumed) goes in "unknowns" and is never a cause.
--
-- plpgsql only because n_tup_newpage_upd exists on 16 and later and a SQL body cannot mention a column
-- that may not exist; the query is built once with the right expression and run.
CREATE FUNCTION @extschema@.bloat_cause_findings(min_holder_age interval DEFAULT interval '1 minute',
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
         coalesce(d.details[2:], '{}'::text[]),
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
    FROM described d
   WHERE cardinality(d.found) > 0 OR d.h_unknown
   ORDER BY 6 DESC NULLS LAST
  $q$, newpage) USING min_holder_age, min_standby_xid_gap;
END
$fn$;

COMMENT ON FUNCTION @extschema@.bloat_cause_findings(interval, bigint) IS
  'One row per table with dead rows and a finding: the primary cause (most upstream, docs/ranking.md), secondary causes in "then", and causes present but not established in "unknowns". Dead rows and bytes are ESTIMATED from the statistics and every row says so. Session and prepared-transaction holders younger than min_holder_age are ignored; a standby counts only when its slot''s xmin trails the primary''s horizon by at least min_standby_xid_gap xids, a heuristic because the primary cannot see when the standby''s query began. Read-only.';

CREATE VIEW @extschema@.bloat_cause AS
  SELECT * FROM @extschema@.bloat_cause_findings();

COMMENT ON VIEW @extschema@.bloat_cause IS
  'bloat_cause_findings() with its defaults: why each table''s dead rows are not being cleaned up, most dead bytes first.';

-- The sentence form. One line per table.
CREATE FUNCTION @extschema@.bloat_cause_text(min_holder_age interval DEFAULT interval '1 minute',
                                             min_standby_xid_gap bigint DEFAULT 1000)
RETURNS SETOF text
LANGUAGE sql STABLE
AS $$
  SELECT format('%s: %s dead rows (%s%%, %s)', f.relname, f.dead_rows, f.dead_pct, f.dead_rows_source)
         || CASE WHEN f.cause IS NULL THEN '. Cause not established.'
                 ELSE ', ' || f.cause_detail || '.' END
         || coalesce((SELECT ' Then: ' || string_agg(t, '; ') || '.' FROM unnest(f."then") t), '')
         || coalesce((SELECT ' Not established: ' || string_agg(u, '; ') || '.' FROM unnest(f.unknowns) u), '')
    FROM @extschema@.bloat_cause_findings(min_holder_age, min_standby_xid_gap) f
$$;

COMMENT ON FUNCTION @extschema@.bloat_cause_text(interval, bigint) IS
  'The findings as sentences, one per table, most dead bytes first: the primary cause with its age, then the secondary causes, then what is present but not established.';

-- Privileges: closed by default, as pg_lock_tree does, and opened with explicit grants (INSTALL.md).
--
-- SECURITY INVOKER, deliberately, for both functions and the view. With SECURITY DEFINER the functions
-- would read pg_stat_activity with the owner's rights, so any role granted EXECUTE would see other
-- users' sessions without pg_read_all_stats, which is the privilege PostgreSQL uses to gate exactly
-- that; and current_user inside them would be the owner, so the note telling a role what it cannot
-- see could never fire. As invoker, a role sees what its own privileges allow, and the note says what
-- is missing. Measured before this was written: the view refused every non-superuser (no grant on it),
-- while the functions were executable by PUBLIC and gave such a role the note.
--
-- bloat_cause_age() stays PUBLIC: it formats an interval and reads nothing.
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

REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_findings(interval, bigint) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_text(interval, bigint) FROM PUBLIC;
-- bloat_cause_holder() is deliberately left executable by PUBLIC, which is a change of mind from the
-- first draft of 0.2 and is worth stating plainly. It was revoked there, on the reasoning that it
-- reads pg_stat_activity and pg_prepared_xacts. But 0.2 also makes bloat_cause_findings() call it,
-- and findings() is SECURITY INVOKER: PostgreSQL checks a function called from another function against
-- the CALLING role, not against the owner. Revoking the holder therefore breaks the grant INSTALL.md
-- tells people to use, and it breaks it at the first call rather than at install.
--
-- The reasoning that led to the revoke does not survive contact with the ownership model, because it
-- was never about the function: it is about what the calling role may read. A role without
-- pg_read_all_stats cannot see other users' backend_xmin and xact_start however it may execute this,
-- so it gets the same hidden rows and the same "not established" note it got from findings() in 0.1.
-- Measured on PostgreSQL 18 with one holder and one unprivileged role: with the grant in place
-- findings() returns the same rows it always did, and the role still cannot read the sessions
-- findings() is hiding. EXECUTE is not visibility.
--
-- SECURITY DEFINER was the other answer and is the wrong one here: it would run the holder's catalog
-- reads as the owner, so an unprivileged role calling findings() would see sessions it is not entitled
-- to. Measured the same way, a SECURITY DEFINER probe returned 1 session to a role that a plain SELECT
-- returned 0 for. That is a privilege escalation, so findings() stays INVOKER and so does this.
