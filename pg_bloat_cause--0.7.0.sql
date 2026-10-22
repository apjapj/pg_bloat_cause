/* pg_bloat_cause--0.7.0.sql
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
 *   bloat_cause_context(schema, table)        autovacuum context for ONE table, from the statistics
 *   bloat_cause_history           table: the sampled series, registered for pg_dump
 *   bloat_cause_sample(pct, bytes, at)  append one sample of every table worth a row
 *   bloat_cause_prune(age)        drop samples older than an age
 *   bloat_cause_notify(channel, pct, bytes, age)        raise one NOTIFY per onset or escalation
 *   bloat_cause_notify_resolved(channel, pct, bytes, age)  raise one cleared NOTIFY
 *   bloat_cause_alert             table: what has already been notified, so it happens once
 *
 * holder_query is empty by default. When the session setting bloat_cause.holder_query is on, the
 * sampler stores the holding session's first statement, redacted of the credential shapes it knows
 * and truncated and marked; see docs/holder-query.md. The opt-in is the protection; the shape of the
 * history does not change.
 *
 * The sampler reads the estimate and never measures, so pgstattuple stays optional and is never
 * invoked by the view, the sampler, or anything that does not exist solely to measure one named
 * table. Every figure the sampler records is dead_rows_source = 'estimated'; a sample taken across a
 * pg_stat_reset() or crash recovery writes a marker row with stats_reset = true and NULL figures,
 * which re-baselines the series, and is reported in not_established. That marker is why a reset
 * cannot read as a table that cleared and does not leave the table unsampled until the pre-reset row
 * is pruned. The decisions behind the shape are in docs/design.md and docs/detect.md, each with the
 * scenario evidence that forced it.
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
  stats_reset       boolean     NOT NULL DEFAULT false,
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
  'recovery writes a marker row with stats_reset = true and NULL figures, so the series re-baselines '
  'immediately and the reset cannot be read as a table that cleared; that sample is still counted in '
  'not_established. stats_reset is false on every ordinary row. holder_pid, holder_xid_age and '
  'holder_slot are the horizon holder that was pinning the table when its cause was ''horizon '
  'holder'', NULL otherwise. holder_query is the holder''s first statement, stored only when the '
  'session sets bloat_cause.holder_query on; it is NULL otherwise, NULL for a prepared or standby '
  'holder, and redacted of the credential shapes the design names. It can still contain other '
  'secrets: the opt-in, not the redaction, is the control. Prune with bloat_cause_prune().';

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
-- The floors are arguments with defaults, not a setting, so a sample is reproducible from its
-- arguments alone. holder_query breaks the old no-configuration rule on purpose and in exactly one
-- place: it decides whether query text is stored at all, it is per-session so a scheduled job sets
-- it in its own session, and it is the standard PostgreSQL opt-in. Everything else stays argument-
-- driven. The same for the sampler as for limit_runway_sample().
--
-- One INSERT for the whole sample rather than one per table, so the row count is bounded by the
-- number of tables and the write is a single statement.
--
-- A sample taken across a statistics reset writes a MARKER row, flagged stats_reset = true, rather
-- than no row at all. Writing no row was a persistence flaw: the pre-reset row stayed the table's
-- latest sample, so reset_at > prev_at stayed true on every later sample and the table was never
-- sampled again (and its state never re-baselined) until that row was pruned, up to 35 days. The
-- marker is the first post-reset row, so the very next sample has a post-reset previous row and is
-- ordinary. The marker carries NO figures (dead_rows, dead_pct and dead_bytes are NULL): the change
-- across the reset cannot be computed from the pre-reset state, so recording a post-reset reading as
-- if it continued the series would invite a delta that does not exist. dead_rows_source stays
-- 'estimated' (it never takes a third value) and the marker is counted in not_established, not
-- sampled: a row is written, but the sample across the reset is exactly the thing that is not
-- established. The sender no longer needs the reset time to see this: it reads the flag off the row.
CREATE FUNCTION @extschema@.bloat_cause_sample(min_dead_pct numeric DEFAULT 10,
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

COMMENT ON FUNCTION @extschema@.bloat_cause_sample(numeric, bigint, timestamptz) IS
  'min_dead_pct is a percentage in 0..100, so 10 means ten percent. Append one sample of every table worth a row to bloat_cause_history: at or above both floors, or '
  'already in the series. Reads bloat_cause_findings() and never measures, so pgstattuple is never '
  'needed. Every figure it records is dead_rows_source = ''estimated''; a sample taken across a '
  'pg_stat_reset() or crash recovery writes a marker row with stats_reset = true and NULL figures, '
  'which re-baselines the series, and is reported in not_established. Runs with the caller''s rights '
  'and returns, per cause, how many it sampled, how many were below the floor, and how many were not '
  'established. holder_query is stored only when the session sets bloat_cause.holder_query on; it is '
  'the holder''s first statement, redacted and truncated and marked, and NULL otherwise. Schedule '
  'it; sampled_at is for fixtures.';

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
-- not the reset mistaken for one. This function deliberately NEVER consults the stats_reset marker
-- or the history: a flagged or unknown sample means "unknown, so do not clear", and it must not mean
-- "suppress alerts". A table over the threshold after a reset is still a current reading and still
-- alerts; a table whose dead bytes cross a higher rung after a reset still escalates, because the
-- state kept across the reset makes the new, higher rung an escalation. The one place a reset could
-- be misread, a "cleared" for a table whose counters were merely reset, is decided in
-- bloat_cause_notify_resolved(), which refuses to clear a subject whose latest sample is a reset
-- marker (or predates the reset). Because that state is kept, a mere re-appearance at the same rung
-- is not re-raised as a fresh onset, and a genuine escalation is.
CREATE FUNCTION @extschema@.bloat_cause_notify(channel text DEFAULT 'bloat_cause',
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

COMMENT ON FUNCTION @extschema@.bloat_cause_notify(text, numeric, bigint, interval) IS
  'min_dead_pct is a percentage in 0..100, so 10 means ten percent. Raise a NOTIFY on channel when a table is at least min_dead_pct dead AND at least min_dead_bytes '
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
-- "Unknown" is decided from the row the sampler wrote, not from dead_rows_source. The first sample
-- across a reset is a marker with stats_reset = true, so a subject whose latest sample is flagged is
-- unknown and is held back: its state is kept and no clear is sent. The reset time is still consulted
-- as well, for the window between a reset and the next sample, when the latest sample is an ordinary
-- pre-reset row and the reset time is newer than it. Either signal means unknown. The rule that
-- matters most is that a clear is never sent when the state is unknown. A subject with no history at
-- all has nothing that predates the reset and is not held back, which is what lets a fixture that
-- never sampled still be cleared. dead_rows_source is not consulted: unknown is not a value it takes,
-- and the reset is now its own column.
CREATE FUNCTION @extschema@.bloat_cause_notify_resolved(channel text DEFAULT 'bloat_cause',
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

COMMENT ON FUNCTION @extschema@.bloat_cause_notify_resolved(text, numeric, bigint, interval) IS
  'Raise one cleared NOTIFY per table that had alerted and is still watched but now below the alert '
  'threshold, then forget its state so the same table bloating again alerts from onset. A table that '
  'has left bloat_cause_findings() is not watched and is not cleared, and a subject whose latest '
  'sample is a reset marker (stats_reset = true) or predates the statistics reset time is unknown and '
  'is not cleared either: the sampler writes the marker row across a reset, and the sender reads that '
  'flag rather than dead_rows_source. Run it beside bloat_cause_notify() with the same thresholds.';

-- The writers are closed like the readers. They write to this extension's own tables and are not
-- executable by PUBLIC by default; INSTALL.md names the grants a monitoring role needs.
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_sample(numeric, bigint, timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_prune(interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_notify(text, numeric, bigint, interval) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_notify_resolved(text, numeric, bigint, interval) FROM PUBLIC;
