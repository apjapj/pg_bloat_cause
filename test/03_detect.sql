-- test/03_detect.sql: the alerting, from step 6 and docs/detect.md.
--
-- Alerting's hard part is not raising a notification, it is raising the right number of them. This
-- file plants a table whose dead bytes cross one rung at a time, calls bloat_cause_notify(), and
-- asserts one notification per rung, silence at the same rung, and a cleared event that carries the
-- last level with previous_level absent.
--
-- pgTAP cannot read a NOTIFY off the wire, so the payloads are captured the way pg_lock_tree's
-- test/11_alert.sql captures its own: a shadow schema defines pg_notify(text, text), and the sender
-- is called with that schema first in search_path. The function calls pg_notify unqualified, so the
-- recorder is what it reaches and the JSON is stored where SQL can assert on it.
--
-- The escalation ladder is min_dead_bytes times ten. A fixture cannot conjure gigabytes, so the
-- fixture's own dead_bytes is read and the first rung is set to it; the next calls lower the first
-- rung by ten, which raises the current rung by one against the highest already notified.
\set ON_ERROR_STOP 1
\set QUIET 1
\o /dev/null
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS pgtap;
CREATE EXTENSION IF NOT EXISTS pg_bloat_cause;

-- The recorder. Its search_path position, first, is what makes it win over pg_catalog's pg_notify.
DROP SCHEMA IF EXISTS bc_det_shadow CASCADE;
CREATE SCHEMA bc_det_shadow;
CREATE TABLE bc_det_shadow.notifications (
  seq     bigserial PRIMARY KEY,
  channel text,
  payload text
);
CREATE FUNCTION bc_det_shadow.pg_notify(channel text, payload text)
RETURNS void
LANGUAGE plpgsql
AS $shadow$
BEGIN
  INSERT INTO bc_det_shadow.notifications (channel, payload) VALUES (channel, payload);
END
$shadow$;

-- The fixture: autovacuum disabled, so it always has a cause and stays in the findings, and half its
-- rows dead.
DROP TABLE IF EXISTS bc_det;
DROP TABLE IF EXISTS bc_det_gone;
DROP TABLE IF EXISTS bc_det_unk;
CREATE TABLE bc_det (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_det SELECT g, 'new' FROM generate_series(1, 3000) g;
ANALYZE bc_det;
UPDATE bc_det SET v = 'paid' WHERE id % 2 = 0;

-- The state this file owns, cleared so a rerun starts from onset.
TRUNCATE bloat_cause_alert;
DELETE FROM bloat_cause_history WHERE relname LIKE 'bc_det%';
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

-- The rungs. b is the current dead_bytes, so b is rung 1, b/10 rung 2 and b/100 rung 3.
\o /dev/null
SELECT dead_bytes AS b, dead_bytes / 10 AS b10, dead_bytes / 100 AS b100,
       dead_bytes * 10 AS b10up
  FROM bloat_cause_findings() WHERE relname = 'bc_det' \gset
\o
SELECT plan(47);

SELECT ok(:b::bigint > 0, 'the fixture has estimated dead bytes to climb the ladder with');

-- ---------------------------------------------------------------- the objects

SELECT has_table('bloat_cause_alert', 'the alert state table exists');
SELECT col_is_pk('bloat_cause_alert', ARRAY['channel', 'subject'],
                 'one row per subject per channel, the dedup key the contract fixes');
SELECT has_function('bloat_cause_notify', ARRAY['text', 'numeric', 'bigint', 'interval'],
                    'bloat_cause_notify(channel, pct, bytes, age) exists');
SELECT has_function('bloat_cause_notify_resolved', ARRAY['text', 'numeric', 'bigint', 'interval'],
                    'bloat_cause_notify_resolved(channel, pct, bytes, age) exists');
SELECT ok(NOT has_function_privilege('public', 'bloat_cause_notify(text,numeric,bigint,interval)', 'EXECUTE')
          AND NOT has_function_privilege('public', 'bloat_cause_notify_resolved(text,numeric,bigint,interval)', 'EXECUTE'),
          'neither sender is executable by PUBLIC');

-- ---------------------------------------------------------------- onset, and the silence that matters

\o /dev/null
SET search_path = bc_det_shadow, public, pg_catalog;
SELECT bloat_cause_notify(min_dead_bytes => :b) AS onset \gset
SELECT bloat_cause_notify(min_dead_bytes => :b) AS same1 \gset
SELECT bloat_cause_notify(min_dead_bytes => :b10) AS esc1 \gset
SELECT bloat_cause_notify(min_dead_bytes => :b100) AS esc2 \gset
SELECT bloat_cause_notify(min_dead_bytes => :b100) AS same2 \gset
RESET search_path;
\o

SELECT is(:onset::int, 1, 'the first call at rung 1 is the onset and notifies once');
SELECT is(:same1::int, 0, 'a second call at the same rung is silent, which is the whole point');
SELECT is(:esc1::int, 1, 'the first higher rung escalates once');
SELECT is(:esc2::int, 1, 'the second higher rung escalates once');
SELECT is(:same2::int, 0, 'and a further call at that rung is silent again');
SELECT is((SELECT count(*)::int FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'event' = 'alerting'
              AND payload::jsonb ->> 'subject' = 'public.bc_det'),
          3, 'three alerting payloads in all, one per rung, so no rung repeated');
SELECT is((SELECT string_agg(payload::jsonb ->> 'level', ',' ORDER BY seq)
             FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det'),
          '1,2,3', 'level is the count read after the increment: 1 at onset, then 2 and 3');
SELECT is((SELECT string_agg(coalesce(payload::jsonb ->> 'previous_level', 'null'), ',' ORDER BY seq)
             FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det'),
          'null,1,2', 'previous_level is null at onset and the prior level at each escalation');
SELECT is((SELECT notify_count FROM bloat_cause_alert WHERE subject = 'public.bc_det'), 3,
          'the state counts three notifications for the subject');
SELECT is((SELECT severity FROM bloat_cause_alert WHERE subject = 'public.bc_det'), 3,
          'and records the highest rung reached, not the previous sample');

-- ---------------------------------------------------------------- the payload contract

-- The required keys are the shared pg_incident_watch contract, the same five every tool sends, plus
-- the two escalation keys pg_lock_tree 1.2.0 ships on the alerting event. Asserted as a set, so the
-- shape cannot drift from the family without this failing.
SELECT ok((SELECT payload::jsonb ?& ARRAY['tool', 'subject', 'sampled_at', 'channel', 'event',
                                          'level', 'previous_level']
             FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det'
            ORDER BY seq LIMIT 1),
          'the alerting payload carries the five required keys plus level and previous_level, the '
          || 'same set pg_lock_tree 1.2.0 sends');
SELECT is((SELECT payload::jsonb ->> 'tool' FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det' ORDER BY seq LIMIT 1),
          'pg_bloat_cause', 'tool names this extension');
SELECT is((SELECT payload::jsonb ->> 'subject' FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det' ORDER BY seq LIMIT 1),
          'public.bc_det', 'subject is the schema-qualified relation name, the identity a listener '
          || 'can resolve without the oid');
SELECT is((SELECT payload::jsonb ->> 'channel' FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det' ORDER BY seq LIMIT 1),
          'bloat_cause', 'channel is the tool''s short name');
SELECT is((SELECT payload::jsonb ->> 'dead_rows_source' FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det' ORDER BY seq LIMIT 1),
          'estimated', 'and the figures carry the estimate label, because the sample never measures');
SELECT ok((SELECT (payload::jsonb ? 'dead_pct') AND (payload::jsonb ? 'dead_bytes')
             FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det' ORDER BY seq LIMIT 1),
          'with dead_pct beside dead_bytes, so a reader sees both');

-- ---------------------------------------------------------------- clearing carries the last level

\o /dev/null
SET search_path = bc_det_shadow, public, pg_catalog;
-- A first rung above the table's dead bytes: still watched, below the alert threshold, so it clears.
SELECT bloat_cause_notify_resolved(min_dead_bytes => :b10up) AS cleared \gset
RESET search_path;
\o
SELECT is(:cleared::int, 1, 'a watched table below the alert threshold is cleared once');
SELECT is((SELECT payload::jsonb ->> 'event' FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det' ORDER BY seq DESC LIMIT 1),
          'cleared', 'with the cleared event');
SELECT is((SELECT (payload::jsonb ->> 'level')::int FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det' ORDER BY seq DESC LIMIT 1),
          3, 'carrying the last level the incident reached, 3');
SELECT ok((SELECT NOT (payload::jsonb ? 'previous_level') FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det' ORDER BY seq DESC LIMIT 1),
          'and previous_level absent, not present-and-null: a cleared payload has no escalation');
SELECT is((SELECT count(*)::int FROM bloat_cause_alert WHERE subject = 'public.bc_det'), 0,
          'the state is forgotten when it clears');

-- ---------------------------------------------------------------- leaving the sampled set is not a clear

-- bc_det has served its purpose; drop it so the next fixtures are the only notable tables.
\o /dev/null
DROP TABLE bc_det;
CREATE TABLE bc_det_gone (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_det_gone SELECT g, 'new' FROM generate_series(1, 3000) g;
ANALYZE bc_det_gone;
UPDATE bc_det_gone SET v = 'paid' WHERE id % 2 = 0;
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

\o /dev/null
SELECT dead_bytes AS g FROM bloat_cause_findings() WHERE relname = 'bc_det_gone' \gset
SET search_path = bc_det_shadow, public, pg_catalog;
SELECT bloat_cause_notify(min_dead_bytes => :g) AS gone_onset \gset
RESET search_path;
-- Its counters are reset, so it leaves the findings while it still exists. That is the "dropped
-- below the floor" case: no longer watched, so no cleared event and the state is kept.
SELECT pg_stat_reset_single_table_counters('bc_det_gone'::regclass);
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

SELECT is(:gone_onset::int, 1, 'the second fixture is an onset too');
SELECT is((SELECT count(*)::int FROM bloat_cause_findings() WHERE relname = 'bc_det_gone'), 0,
          'its counters are reset, so it has left the findings and is no longer watched');
\o /dev/null
SET search_path = bc_det_shadow, public, pg_catalog;
SELECT bloat_cause_notify_resolved(min_dead_bytes => 1) AS res_gone \gset
RESET search_path;
\o
SELECT is(:res_gone::int, 0,
          'a table that left the sampled set is not cleared: absence of data is not recovery');
SELECT is((SELECT count(*)::int FROM bloat_cause_alert WHERE subject = 'public.bc_det_gone'), 1,
          'and its alert state is kept, so it is not silently forgotten either');

-- ---------------------------------------------------------------- a reset is unknown, not resolved

-- The same shape as the reset case in test/02, but through the sender. A sample taken before
-- pg_stat_reset() is the subject's latest sample; the reset then zeroes the counters and the sampler
-- would write a marker row across it. The table accumulates a few new dead rows, so it is still in
-- the findings and the clear path is reached. The sender must see that the latest sample predates
-- the reset, call the state unknown, and NOT send cleared. Two signals make a subject unknown: a
-- latest sample predating the reset time (below), and a latest sample flagged stats_reset = true
-- (the marker path, asserted second).
\o /dev/null
DROP TABLE IF EXISTS bc_det_unk;
CREATE TABLE bc_det_unk (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_det_unk SELECT g, 'new' FROM generate_series(1, 3000) g;
ANALYZE bc_det_unk;
UPDATE bc_det_unk SET v = 'paid' WHERE id % 2 = 0;
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

\o /dev/null
SELECT dead_bytes AS u FROM bloat_cause_findings() WHERE relname = 'bc_det_unk' \gset
SET search_path = bc_det_shadow, public, pg_catalog;
SELECT bloat_cause_notify(min_dead_bytes => :u) AS unk_onset \gset
RESET search_path;
-- The last sample before the reset, recorded as the sampler would record it: 'estimated'.
INSERT INTO bloat_cause_history
       (sampled_at, schemaname, relname, dead_rows, dead_pct, dead_bytes, dead_rows_source)
SELECT statement_timestamp(), 'public', 'bc_det_unk', dead_rows, dead_pct, dead_bytes, 'estimated'
  FROM bloat_cause_findings() WHERE relname = 'bc_det_unk';
-- The reset moves the database statistics reset time past that sample. A few new dead rows then put
-- the table back in the findings, below the alert threshold, which is the state that would clear if
-- the reset were mistaken for recovery.
SELECT pg_stat_reset();
UPDATE bc_det_unk SET v = 'refund' WHERE id <= 10;
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

\o /dev/null
SET search_path = bc_det_shadow, public, pg_catalog;
SELECT bloat_cause_notify_resolved(min_dead_bytes => :u * 10) AS res_unk \gset
RESET search_path;
\o
SELECT is(:unk_onset::int, 1, 'the third fixture is an onset too');
SELECT ok((SELECT (payload::jsonb ->> 'level')::int = 1 FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det_unk'
              AND payload::jsonb ->> 'event' = 'alerting'),
          'and carries level 1 at onset');
SELECT is((SELECT count(*)::int FROM bloat_cause_findings() WHERE relname = 'bc_det_unk'), 1,
          'after the reset it is back in the findings, so the guard is what is tested, not absence');
SELECT is(:res_unk::int, 0,
          'a subject whose latest sample is older than the reset time is unknown, not cleared');
SELECT is((SELECT count(*)::int FROM bloat_cause_alert WHERE subject = 'public.bc_det_unk'), 1,
          'and its state is kept');

-- The marker path: the sampler's post-reset row is flagged stats_reset = true and, because it is
-- written by the first sample after the reset, it is dated after the reset. The reset-time comparison
-- alone would see a known subject here; the flag is what holds it back.
\o /dev/null
INSERT INTO bloat_cause_history
       (sampled_at, schemaname, relname, dead_rows, dead_pct, dead_bytes, dead_rows_source, stats_reset)
VALUES (statement_timestamp(), 'public', 'bc_det_unk', NULL, NULL, NULL, 'estimated', true);
\o
SET search_path = bc_det_shadow, public, pg_catalog;
SELECT bloat_cause_notify_resolved(min_dead_bytes => :u * 10) AS res_unk_marker \gset
RESET search_path;
\o
SELECT is(:res_unk_marker::int, 0,
          'a subject whose latest sample is a reset marker is unknown, not cleared');
SELECT is((SELECT count(*)::int FROM bloat_cause_alert WHERE subject = 'public.bc_det_unk'), 1,
          'and its state is kept with the marker, too');

-- ---------------------------------------------------------------- a reset does not suppress an alert

-- The guard in bloat_cause_notify_resolved() must mean "unknown, so no clear" and never "suppress
-- alerts". bloat_cause_notify() walks the current findings and never consults the marker or the
-- reset, so a table over the threshold right after a reset still raises a real onset.
\o /dev/null
DROP TABLE IF EXISTS bc_det_over;
CREATE TABLE bc_det_over (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_det_over SELECT g, 'new' FROM generate_series(1, 3000) g;
ANALYZE bc_det_over;
UPDATE bc_det_over SET v = 'paid' WHERE id % 2 = 0;
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

-- The reset moves the statistics reset time and zeroes every counter; the new dead rows put the
-- table back in the findings above the threshold.
\o /dev/null
SELECT pg_stat_reset();
UPDATE bc_det_over SET v = 'due' WHERE id % 3 = 0;
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

\o /dev/null
SELECT dead_bytes AS ob FROM bloat_cause_findings() WHERE relname = 'bc_det_over' \gset
SET search_path = bc_det_shadow, public, pg_catalog;
SELECT bloat_cause_notify(min_dead_bytes => :ob) AS over_onset \gset
RESET search_path;
\o
SELECT is(:over_onset::int, 1,
          'a table over the threshold right after a reset still alerts: the reset does not suppress');
SELECT is((SELECT count(*)::int FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det_over'
              AND payload::jsonb ->> 'event' = 'alerting'), 1,
          'with one alerting payload for the subject');
SELECT is((SELECT severity FROM bloat_cause_alert WHERE subject = 'public.bc_det_over'), 1,
          'and the state records the onset');

-- ---------------------------------------------------------------- the series resumes after a reset

-- The persistence flaw, reproduced: write a pre-reset sample, reset, then sample again. Before the
-- marker, the pre-reset row stayed the table's latest sample, so reset_at stayed newer than prev_at
-- and every later sample wrote no row; the table was never sampled again until that row was pruned.
-- The marker re-baselines the series: the first post-reset sample is flagged, the second is ordinary,
-- and a new incident on the table alerts.
\o /dev/null
DROP TABLE IF EXISTS bc_det_persist;
CREATE TABLE bc_det_persist (id int PRIMARY KEY, v text) WITH (autovacuum_enabled = false);
INSERT INTO bc_det_persist SELECT g, 'new' FROM generate_series(1, 3000) g;
ANALYZE bc_det_persist;
UPDATE bc_det_persist SET v = 'paid' WHERE id % 2 = 0;
DELETE FROM bloat_cause_history WHERE relname = 'bc_det_persist';
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

\o /dev/null
-- t0 is the moment this block starts. The pre-reset sample is backdated a second before it and the
-- post-reset samples are a second and two seconds after it, so the samples straddle the reset time
-- without depending on its resolution: on older servers the statistics reset time can be coarser than
-- statement_timestamp(), and a sample dated in the same second as the reset could fall on the wrong
-- side of it.
SELECT set_config('bc_d.t0', statement_timestamp()::text, false);
-- The pre-reset sample.
SELECT coalesce(sum(sampled),0)::int AS sampled FROM bloat_cause_sample(
         min_dead_pct => 0.1, min_dead_bytes => 0,
         sampled_at => current_setting('bc_d.t0')::timestamptz - interval '1 second') \gset
-- The reset, then the first post-reset sample: the marker. The wait is for the reset time to
-- propagate: on a server with a separate statistics collector (14 and 15) pg_stat_reset() updates
-- pg_stat_get_db_stat_reset_time() asynchronously, and a sample taken in the same instant would still
-- read the old time and miss the reset. The sample's own sampled_at is explicit, so the wait changes
-- nothing about what the row is dated.
SELECT pg_stat_reset();
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();
\o /dev/null
SELECT coalesce(sum(not_established),0)::int AS nes FROM bloat_cause_sample(
         min_dead_pct => 0.1, min_dead_bytes => 0,
         sampled_at => current_setting('bc_d.t0')::timestamptz + interval '1 second') \gset
-- New dead rows, then the second post-reset sample, which must be ordinary.
UPDATE bc_det_persist SET v = 'late' WHERE id % 3 = 0;
\o
SELECT pg_sleep(10);
SELECT pg_stat_clear_snapshot();

\o /dev/null
SELECT coalesce(sum(sampled),0)::int AS sampled2 FROM bloat_cause_sample(
         min_dead_pct => 0.1, min_dead_bytes => 0,
         sampled_at => current_setting('bc_d.t0')::timestamptz + interval '2 seconds') \gset
\o
SELECT is((SELECT count(*)::int FROM bloat_cause_history
            WHERE relname = 'bc_det_persist'
              AND sampled_at = current_setting('bc_d.t0')::timestamptz + interval '1 second'
              AND stats_reset = true), 1,
          'the first post-reset sample is the marker row');
SELECT is((SELECT count(*)::int FROM bloat_cause_history
            WHERE relname = 'bc_det_persist'
              AND sampled_at = current_setting('bc_d.t0')::timestamptz + interval '2 seconds'
              AND stats_reset = false), 1,
          'the second post-reset sample is ordinary, so the series resumed');
SELECT ok(:nes::int >= 1, 'and the marker sample is counted as not established');

-- A new incident on the table alerts, because notify() reads the current findings and never treats
-- the reset as suppression.
\o /dev/null
SELECT dead_bytes AS pb FROM bloat_cause_findings() WHERE relname = 'bc_det_persist' \gset
SET search_path = bc_det_shadow, public, pg_catalog;
SELECT bloat_cause_notify(min_dead_bytes => :pb) AS persist_onset \gset
RESET search_path;
\o
SELECT is(:persist_onset::int, 1, 'a new incident on the table after the reset alerts');
SELECT is((SELECT count(*)::int FROM bc_det_shadow.notifications
            WHERE payload::jsonb ->> 'subject' = 'public.bc_det_persist'
              AND payload::jsonb ->> 'event' = 'alerting'), 1,
          'with one alerting payload for the subject');
SELECT is((SELECT notify_count FROM bloat_cause_alert WHERE subject = 'public.bc_det_persist'), 1,
          'and its state starts at level 1, a fresh onset');

-- ---------------------------------------------------------------- cleanup

\o /dev/null
DELETE FROM bloat_cause_history WHERE relname LIKE 'bc_det%';
TRUNCATE bloat_cause_alert;
DROP TABLE IF EXISTS bc_det_gone;
DROP TABLE IF EXISTS bc_det_unk;
DROP TABLE IF EXISTS bc_det_over;
DROP TABLE IF EXISTS bc_det_persist;
DROP SCHEMA IF EXISTS bc_det_shadow CASCADE;
\o
SELECT * FROM finish();
