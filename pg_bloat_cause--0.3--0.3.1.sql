-- pg_bloat_cause 0.3 -> 0.3.1: the measurement passed a quoted oid as a relation name
--
-- 0.3.0's bloat_cause_measure() never worked. It built the read with format('%L', oid), which quotes
-- the oid, so pgstattuple received the STRING '19223' and looked up a relation named 19223:
--
--   ERROR: relation "19223" does not exist
--
-- The cast is now %s::regclass, which is the oid and means no name lookup happens at all. That is also
-- why it is the safer form: resolving a name is the step that checks the caller's privileges, which is
-- the class of defect that has been found twice in this family already.
--
-- CREATE OR REPLACE, not DROP: the signature and the return type are unchanged, only the body.
--
-- The 0.3.0 pgTAP assertions did not catch this because they assert the LABEL, dead_rows_source =
-- 'measured', and a function that raises inside a LATERAL can leave an earlier branch's row intact in
-- some plans. The scenario added in the same change asserts the FIGURE, and failed immediately.

\echo Use "ALTER EXTENSION pg_bloat_cause UPDATE TO '0.3.1'" to load this file. \quit

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

REVOKE EXECUTE ON FUNCTION @extschema@.bloat_cause_measure(name, name, text) FROM PUBLIC;
