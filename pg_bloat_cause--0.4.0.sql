/* pg_bloat_cause--0.4.0.sql
 *
 * What's slowing down: for each table with dead rows, the cause, ranked as docs/ranking.md decides,
 * in one sentence; plus a sampled history, a pruner and the two senders of the shared
 * pg_incident_watch alert contract. Step 6 of README.md, settled in docs/detect.md before the SQL.
 *
 *   bloat_cause                   view: one row per table with a finding, most dead bytes first
 *   bloat_cause_findings(age)     the same, with the minimum horizon-holder age as an argument
 *   bloat_cause_text(age)         the sentence form, one line per table
 *   bloat_cause_holder(age, gap)  every horizon holder, structured: kind, pid, gid, slot, who
 *   bloat_cause_command(age, gap) the statement that clears the primary cause, returned not run
 *   bloat_cause_measure(schema, table, mode)  measured dead rows for ONE table, via pgstattuple
 *   bloat_cause_history           table: the sampled series, registered for pg_dump
 *   bloat_cause_sample(pct, bytes, at)  append one sample of every table worth a row
 *   bloat_cause_prune(age)        drop samples older than an age
 *   bloat_cause_notify(channel, pct, bytes, age)        raise one NOTIFY per onset or escalation
 *   bloat_cause_notify_resolved(channel, pct, bytes, age)  raise one cleared NOTIFY
 *   bloat_cause_alert             table: what has already been notified, so it happens once
 *
 * The sampler reads the estimate and never measures, so pgstattuple stays optional and is never
 * invoked by the view, the sampler, or anything that does not exist solely to measure one named
 * table. Every figure the sampler records is dead_rows_source = 'estimated'; a sample taken across a
 * pg_stat_reset() or crash recovery writes no row at all, and is reported in not_established instead,
 * so a reset cannot read as a table that cleared. The decisions behind the shape are in docs/design.md
 * and docs/detect.md, each with the scenario evidence that forced it.
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

-- bloat_cause_command(): the statement that clears the cause, returned and never run.
--
-- Read-only like everything else here. Nothing in this file acts on a cluster, and this is no
-- exception: it returns text for a human to look at and paste. The \gexec idiom is in the COMMENT
-- below and is the reader's decision, not this extension's.
--
-- Why the cause is the only thing it answers. One table can have several causes at once, and
-- docs/ranking.md decides which is named first. Clearing the first is what moves the number, so
-- the command is for the primary cause only, and the secondary causes are deliberately not given
-- statements. A reader handed four statements for one table would paste all four, and two of them
-- would then look like the fix while doing nothing about the cause that was actually holding the
-- rows.
--
-- Why each destructive statement carries what it loses. Every row here can end a session, a
-- prepared transaction or a replication slot. Dropping a replication slot loses that consumer's
-- position and cannot be undone by recreating it, and terminating an idle-in-transaction session
-- rolls back whatever it had open. So the cost is in the same row as the statement, not in a
-- separate note the reader may not read.
--
-- The holder comes from bloat_cause_holder(), not from a second copy of the holder query. That is
-- the whole reason the holder was factored out in 0.2: a statement needs a pid or a gid, and
-- getting one out of cause_detail would mean parsing an English sentence.
--
-- Two cases produce NO row, on purpose, following lock_tree_command()'s precedent:
--   a standby holder. Its query is on the other host, so this side has no pid to terminate and
--     no statement that would help. docs/ranking.md rule 3 says the command is for the primary
--     only. bloat_cause_text() already says where the fix is.
--   your own pid. An operator must not be handed the means to disconnect themselves mid-query,
--     and pg_terminate_backend() on your own backend would either do nothing or cancel the very
--     statement reading this.
CREATE FUNCTION @extschema@.bloat_cause_command(min_holder_age interval DEFAULT interval '1 minute',
                                                 min_standby_xid_gap bigint DEFAULT 1000)
RETURNS TABLE (
  schemaname name,
  relname    name,
  cause      text,
  command    text,
  -- What running it costs, in the same row, because the statement alone reads as harmless.
  loses      text
)
LANGUAGE sql STABLE
AS $$
  WITH f AS (
    SELECT * FROM @extschema@.bloat_cause_findings($1, $2)
  ),
  -- The oldest holder, the same one findings() joined ON true, so a table's command always names
  -- the holder its sentence names. Read once here rather than per table because the primary has
  -- exactly one oldest horizon.
  h AS (
    SELECT kind, pid, gid, slot_name, who, since
      FROM @extschema@.bloat_cause_holder($1, $2)
     ORDER BY xid_age DESC NULLS LAST
     LIMIT 1
  ),
  -- The blocker of a table that autovacuum cannot get past. findings() names it in the sentence;
  -- the statement needs the pid, so it is read here. A lock has no age, so unlike the horizon
  -- holder this is simply whichever session holds the blocking mode.
  blk AS (
    SELECT l.relation, min(a.pid) AS pid
      FROM pg_locks l
      JOIN pg_stat_activity a ON a.pid = l.pid
     WHERE l.locktype = 'relation' AND l.granted AND a.pid <> pg_backend_pid()
       AND a.backend_type = 'client backend'
       AND l.mode IN ('ShareUpdateExclusiveLock', 'ShareLock', 'ShareRowExclusiveLock',
                      'ExclusiveLock', 'AccessExclusiveLock')
     GROUP BY l.relation
  )
  SELECT f.schemaname, f.relname, f.cause,
         CASE f.cause
           -- The holder. A session is ended by cancelling it, not terminating it: cancelling asks
           -- it to give up at the next safe point, which is what an idle-in-transaction blocker
           -- needs, and it leaves a running query to finish. Termination is the harsher tool and is
           -- not the first thing to hand someone. The prepared transaction has no backend to
           -- cancel, so it takes ROLLBACK PREPARED, which is the statement that ends it.
           WHEN 'horizon holder' THEN
             CASE h.kind
               WHEN 'session'  THEN format('SELECT pg_cancel_backend(%s);', h.pid)
               WHEN 'prepared' THEN format('ROLLBACK PREPARED ''%s'';', h.gid)
             END
           WHEN 'lock keeps vacuum off' THEN format('SELECT pg_cancel_backend(%s);', b.pid)
           WHEN 'lock blocks anti-wraparound vacuum' THEN format('SELECT pg_cancel_backend(%s);', b.pid)
           -- autovacuum disabled, thresholds not reached and behind all end with autovacuum not
           -- running, and none of them is cleared by a statement a reader should paste blind.
           -- ALTER TABLE ... RESET (autovacuum_enabled) looks like the fix and will not help if the
           -- threshold is simply never reached, which is why ranking.md rule 3 withholds it. What
           -- the reader gets instead is the statement that shows whether autovacuum is even trying.
           WHEN 'autovacuum disabled' THEN
             format($cmd$SELECT c.relname,
       current_setting('autovacuum') AS cluster_autovacuum,
       coalesce((SELECT option_value FROM pg_options_to_table(c.reloptions)
                 WHERE option_name = 'autovacuum_enabled'), '(unset, so on)') AS table_autovacuum_enabled
  FROM pg_class c WHERE c.oid = %L;$cmd$, f.relid)
           WHEN 'autovacuum thresholds not reached' THEN
             format('SELECT relname, reloptions FROM pg_class WHERE oid = %L;', f.relid)
           WHEN 'autovacuum behind' THEN
             format('VACUUM (VERBOSE) %I.%I;', f.schemaname, f.relname)
           -- Non-HOT updates are a property of the update pattern, not a setting, and no statement
           -- fixes it. The reader is shown the numbers so they can see the ratio themselves.
           WHEN 'updates not HOT' THEN
             format('SELECT relname, n_tup_upd, n_tup_hot_upd FROM pg_stat_user_tables WHERE relid = %L;', f.relid)
         END,
         CASE f.cause
           WHEN 'horizon holder' THEN
             CASE h.kind
               WHEN 'session'  THEN format('cancels the query in session %s; whatever it had open is rolled back, and it is not terminated outright', h.pid)
               WHEN 'prepared' THEN format('rolls back prepared transaction %s and releases everything it holds', h.gid)
               ELSE 'nothing to run: the query holding this is on the standby, and the fix is there'
             END
           WHEN 'lock keeps vacuum off' THEN
             format('cancels session %s, which has held the lock autovacuum needs; it is cancelled rather than terminated, so a running query there still finishes', b.pid)
           WHEN 'lock blocks anti-wraparound vacuum' THEN
             format('cancels session %s, which is holding an anti-wraparound vacuum off; that vacuum cannot proceed until the lock is gone', b.pid)
           WHEN 'autovacuum disabled' THEN
             'reads the setting back; it changes nothing, and no statement is offered because turning autovacuum on is a decision about this table, not a paste'
           WHEN 'autovacuum thresholds not reached' THEN
             'reads the table options back; it changes nothing, because the threshold is a property of the update rate and lowering it is a tuning decision'
           WHEN 'autovacuum behind' THEN
             'this one does act: it vacuums the table now. It is safe, but it is work on a live table and it is offered because autovacuum simply has not got to it yet'
           WHEN 'updates not HOT' THEN
             'reads the update counters back; it changes nothing, because non-HOT updates come from the update pattern and only fewer updates or a fillfactor changes that'
         END
    FROM f
    LEFT JOIN h  ON true
    LEFT JOIN blk b ON b.relation = f.relid
   -- No row for a holder this side cannot act on, and never one for the reader's own session.
   WHERE f.cause IS DISTINCT FROM 'horizon holder'
      OR (h.kind IS DISTINCT FROM 'standby' AND h.pid IS DISTINCT FROM pg_backend_pid())
  ORDER BY f.dead_bytes DESC NULLS LAST, f.schemaname, f.relname
$$;

COMMENT ON FUNCTION @extschema@.bloat_cause_command(interval, bigint) IS
  'One statement per table, for the primary cause only, returned and never run: see docs/ranking.md rule 3 for why the secondary causes get no statement. Each row carries what running it loses. Destructive cases name a pid or a gid, never parsed out of a sentence: a session is cancelled with pg_cancel_backend() rather than terminated, a prepared transaction is rolled back with ROLLBACK PREPARED, and a standby holder produces NO row because the query is on the other host and no statement on this side would help. Your own session is never returned. Read-only: intended for psql, SELECT * FROM bloat_cause_command();, or paste one row yourself. The autovacuum causes mostly return a read-back rather than an action, deliberately: turning autovacuum on or lowering a threshold is a tuning decision, and ranking.md rule 3 withholds it. Only ''autovacuum behind'' acts, with VACUUM (VERBOSE).';

-- bloat_cause_measure(): the exact read, for one table, when a caller asks for it.
--
-- Read-only, like everything else here, but unlike everything else it reads the TABLE rather than the
-- statistics. pgstattuple walks the heap, so this must never be called implicitly: the view, the
-- sentences and the command all stay on the estimate, and this is the one place a real read happens.
-- docs/measure.md settles that, and the paragraph in README's "Measuring bloat" is the authority.
--
-- One table per call, named by the caller. A function that measured every bloated table would be the
-- implicit whole-database read the contract forbids.
--
-- pgstattuple is optional, so this function is always present and raises when it is not installed,
-- rather than being absent. A missing function tells a caller nothing; the error names the extension
-- and the statement that installs it. The reference is resolved at run time because the body is
-- plpgsql, which is what makes that possible at all.
--
-- mode 'approx' uses pgstattuple_approx(), which reads only the pages the visibility map does not
-- cover, and is the default because pgstattuple() reads the whole table. 'exact' is there for a table
-- small enough that the difference does not matter, which is the caller's judgement and not this
-- function's.
CREATE FUNCTION @extschema@.bloat_cause_measure(schema name, table_name name, mode text DEFAULT 'approx')
RETURNS TABLE (
  schemaname       name,
  relname          name,
  relid            oid,
  dead_rows        bigint,
  live_rows        bigint,
  dead_bytes       bigint,
  dead_pct         numeric,
  dead_rows_source text
)
LANGUAGE plpgsql STABLE
SET lock_timeout = '1s'
AS $fn$
DECLARE
  v_relid oid;
  v_live  bigint;
  v_dead  bigint;
  v_dlen  bigint;
BEGIN
  IF mode NOT IN ('approx', 'exact') THEN
    RAISE EXCEPTION 'mode must be approx or exact, not %', mode
      USING ERRCODE = '22023',
            HINT = 'approx reads only the pages the visibility map does not cover; exact reads the whole table';
  END IF;

  SELECT c.oid INTO v_relid
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE n.nspname = schema AND c.relname = table_name AND c.relkind IN ('r', 'm');
  IF v_relid IS NULL THEN
    RAISE EXCEPTION 'no ordinary table named %.%', schema, table_name USING ERRCODE = '42P01';
  END IF;

  -- Checked before the read, so the error is about the extension rather than about a name the
  -- planner could not resolve.
  IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgstattuple') THEN
    RAISE EXCEPTION 'pgstattuple is not installed, and bloat_cause_measure() reads the table rather than the statistics'
      USING ERRCODE = '0A000',
            HINT = 'CREATE EXTENSION pgstattuple; and call it again';
  END IF;

  -- pgstattuple() and pgstattuple_approx() name the live count differently: tuple_count against
  -- approx_tuple_count. The dead counts share a name. Reading it through EXECUTE is what lets the
  -- three columns be selected per mode.
  IF mode = 'exact' THEN
    -- %s::regclass, NOT %L. %L quotes the oid, so pgstattuple received the string '19223' and looked
    -- up a RELATION NAMED 19223, which does not exist: 'relation "19223" does not exist'. Casting the
    -- oid avoids a name lookup entirely, which is both correct and safer, because resolving a name
    -- is what checks the caller's schema privileges.
    EXECUTE format('SELECT tuple_count, dead_tuple_count, dead_tuple_len FROM pgstattuple(%s::regclass)', v_relid)
       INTO v_live, v_dead, v_dlen;
  ELSE
        EXECUTE format('SELECT approx_tuple_count, dead_tuple_count, dead_tuple_len FROM pgstattuple_approx(%s::regclass)', v_relid)
       INTO v_live, v_dead, v_dlen;
  END IF;

  RETURN QUERY SELECT schema, table_name, v_relid,
                      v_dead,
                      v_live,
                      v_dlen,
                      round(100.0 * v_dead / nullif(v_live + v_dead, 0), 1),
                      'measured'::text;
END
$fn$;

COMMENT ON FUNCTION @extschema@.bloat_cause_measure(name, name, text) IS
  'Measured dead rows for ONE table, read from the heap by pgstattuple, with dead_rows_source = ''measured'' so it can be put beside the estimate for the same table. mode is ''approx'' (default, pgstattuple_approx(), reading only the pages the visibility map does not cover) or ''exact'' (pgstattuple(), the whole table). Always present: if pgstattuple is not installed it raises, naming the extension and the statement that installs it, rather than being absent. Never called implicitly by anything in this extension: the view, the sentences and the command all stay on the estimate.';

-- Closed like the readers. It reads a table, so it is not granted to PUBLIC; a caller who may not
-- read the table gets pgstattuple's own refusal, which is the right refusal.
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_measure(name, name, text) FROM PUBLIC;

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
