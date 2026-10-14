# measuring bloat: the explicit measurement, and how it will be tested

**Status: not implemented.** This is the plan for `bloat_cause_measure()`, settled before any code so
the next session starts from decisions rather than from questions. It is written down because the
decisions were made in conversation and a conversation is not a place to keep them.

`README.md` §"Measuring bloat" already states the contract this implements, and it is the authority:

> Exact measurement uses `pgstattuple` when it is installed; otherwise an estimate from `pg_class`
> and `pg_stats`. `pgstattuple()` reads the whole table, so it must never run implicitly across a
> database. `pgstattuple_approx()` reads only the pages the visibility map does not cover and is the
> better default when exact is asked for on a large table.

## What it will be

```
bloat_cause_measure(schema name, table name, mode text DEFAULT 'approx')
  RETURNS TABLE (
    schemaname name, relname name, relid oid,
    dead_rows bigint, live_rows bigint, dead_bytes bigint, dead_pct numeric,
    dead_rows_source text
  )
```

One table per call, named by the caller. `mode` is `'approx'` for `pgstattuple_approx()` or `'exact'`
for `pgstattuple()`. `dead_rows_source` is `'measured'`, so a caller can put the row beside the
estimate for the same table and see both.

## Settled decisions

**Always present, and it raises a clear error when `pgstattuple` is absent.** plpgsql resolves a
function reference at run time, so the function can exist whether or not `pgstattuple` does. Called
without it, the error names the missing extension and what to install, rather than the function being
absent and the caller left with "function does not exist" and no next step. The alternative, creating
it only when `pgstattuple` is present, was considered and rejected for that reason.

**It is never called implicitly.** `bloat_cause_findings()` keeps `dead_rows_source = 'estimated'`
and does not change. The whole point of "must never run implicitly across a database" is that reading
the view stays cheap, and a measurement is something a caller asks for about a table they choose.

**One table per call, never a loop.** Same reason. A function that measured every bloated table would
be exactly the implicit whole-database read the contract forbids.

## The order of work, and why it is that order

1. **The scenarios**, with the contract above and the function not yet written.
2. **The CI matrix dimension** for with and without `pgstattuple`.
3. **The README**, if and only if the implementation shows it needs amending.
4. **`bloat_cause_measure()` itself, last.**

Building the harness before the thing it tests is deliberate, and it is what this repository learned
the hard way: `bloat_cause_holder()` shipped broken with every gate green because nothing called it,
and the `DEFAULT nextval()` detection in `pg_limit_runway` raised for an unprivileged caller because
only the privileged path was exercised. A feature written first gets a test written to match it. A
test written first gets a feature written to match the test.

## Verification, and the paths that will actually find faults

**An unprivileged role, first and not last.** `pgstattuple` on a table a role does not own is its own
permission question, and `pg_read_all_stats` does not grant it. This is the path that found the
`findings()` defect and the s18 permission regression, and reading the SQL found neither.

**With `pgstattuple` and without it.** The second is the new matrix dimension, and it is only
meaningful once there is a branch that differs. It is due here rather than earlier for that reason.

**The measured row against the estimate for the same table.** `pgstattuple` and `pg_class` count the
same thing differently, so a scenario should show both and assert the relationship rather than assert
a number.

## What must not change

- `bloat_cause`, `bloat_cause_text()` and `bloat_cause_findings()` keep their shapes and their
  `estimated` source.
- `pgstattuple` stays optional: never required, never invoked by the view or by any existing function.
- Version: this is `0.3.0`, a new release script and a new update path. It is not an edit to `0.2`,
  which is released and tagged.

## The next concrete step

Write the two scenarios against the contract above, with `bloat_cause_measure()` absent so they fail
loudly, then add the function to make them pass. The names are not given here because a document that
cites a path that does not exist yet is a document the link lint rejects, correctly, and it did. If that feels backwards, it is: it is the order that stops the function being written to
whatever the test happened to check.
