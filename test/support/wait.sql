-- test/support/wait.sql: wait for the exact statistics state the next assertion reads.
--
-- Loaded by each test file with \ir support/wait.sql. One shared loop, because the fixed sleeps and
-- the per-file loops this replaces each waited for part of the state and not the state itself: on a
-- server with an asynchronous statistics collector (14, and 15 for the reset time) a condition can
-- become true before the rows the assertion reads are visible.
--
-- condition_sql must return exactly one boolean, and the failure names what it was waiting for, so
-- a timeout reads as one sentence rather than as a wrong assertion further down. The statistics
-- snapshot is cleared on every attempt, not once before the loop: a cached snapshot can keep a
-- condition false for the whole timeout even after the collector has caught up.
--
-- PG14 flush boundary. On 14 a backend sends its own pending counts to the collector only when a
-- top-level command ends and the 500 ms report interval has elapsed; it never sends them while a
-- command is running. A wait implemented as one function call is therefore one command, and the
-- fixture counts it is waiting for would stay in the backend for the whole timeout. Every caller
-- therefore runs a separate SELECT pg_sleep(1.2); immediately before the call. That sleep is the
-- flush boundary, not the assertion: 1.2 s is longer than the observed ~1 s stats update on 15-18
-- (0.6 s was measured to be too short there; see the design note), so the command ends after the
-- interval and the counts are reported. The exact predicate below is still
-- what decides correctness; a longer sleep cannot make a wrong predicate pass, and the forced repro
-- proves the predicate waits by pausing the collector across it.
--
-- The same rule applies inside an open transaction block: an explicit BEGIN ... COMMIT is still one
-- command boundary from the client's point of view only when it commits, so a test that needs to see
-- its own fresh counts must not wait inside BEGIN.

CREATE OR REPLACE FUNCTION pg_temp.wait_until(
    condition_sql text,
    description   text,
    timeout       interval DEFAULT interval '30 seconds'
) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    deadline timestamptz := clock_timestamp() + timeout;
    ready    boolean;
BEGIN
    LOOP
        PERFORM pg_stat_clear_snapshot();
        EXECUTE condition_sql INTO ready;
        EXIT WHEN ready;
        IF clock_timestamp() >= deadline THEN
            RAISE EXCEPTION 'timed out after % waiting for %', timeout, description;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END
$$;
