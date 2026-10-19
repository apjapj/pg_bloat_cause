-- pg_bloat_cause 0.4.0 -> 0.4.1
--
-- 0.4.1 changes no SQL. It fixes the 0.3 to 0.3.1 update script, which used CREATE FUNCTION where
-- its own comment said CREATE OR REPLACE, so a database at 0.3 or earlier failed with "function
-- bloat_cause_measure already exists" and could not update. The corrected script ships in this
-- release. A database already at 0.4.0 has nothing to change; this file exists so the version can
-- be bumped.
--
-- Nothing below but the guard.

\echo Use "ALTER EXTENSION pg_bloat_cause UPDATE TO '0.4.1'" to load this file. \quit
