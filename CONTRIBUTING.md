# contributing: changing this, and releasing it

Short version of what CI runs and what it will not catch for you. `pg_lock_tree`'s
CONTRIBUTING.md is the long version and is worth reading once; this file is what
applies to a repository with 13 scenarios, 19 tests and one release script.

## Make targets

| Target | What it does | Needs |
|---|---|---|
| `make install` | Installs the control file and every script in `DATA` via PGXS. | A superuser shell and the server headers (`postgresql-server-dev-NN`). |
| `make prove` | `pg_prove --dbname $(TESTDB) test/*.sql`. Default `TESTDB` is `postgres`; override it with `make prove TESTDB=...`. | An installed extension and a running server. The libpq variables in your environment pick the server. |
| `make lint` | Three scripts, no database: `scripts/lint-docs.sh`, `scenarios/check-evidence.sh`, `scripts/check-workflows.sh`. | Nothing. Safe anywhere, cheap enough for a pre-commit hook. |

CI runs `make lint` and the tests on PostgreSQL 14 and 18, and runs the scenario suite in
a container built from `ci/Dockerfile`. It does not run `make install` against your
machine, so an install that works in CI and not locally is a bug in the `DATA` list or in
`scenarios/install-extension.sh`, and both are checked by the lint.

## The rules a change must not break

These are the promises the documentation makes. Each has a test, so a change that
breaks one will go red rather than pass quietly.

- **The caller's rights.** Nothing is `SECURITY DEFINER`. Every function and the view run
  as the caller, so a monitoring role sees exactly what its grants allow.
- **Closed by default.** Every object is revoked from `PUBLIC`. A role with no grant is
  refused by the view and by both functions, and that refusal is asserted in the tests.
- **Never waits for a lock.** A table that cannot be locked in time is "not
  established", not a stalled monitor. A monitor that blocks is worse than one that
  reports less.
- **A limit or a cause is never a guess.** If it cannot be established from what this
  role can see, it says so and names what it cannot see.
- **Pure SQL, PostgreSQL 14 and later.** No C, no background worker, no
  `shared_preload_libraries`, no restart.

## Tests

`test/01_bloat_cause.sql` is one file with `plan(19)`. The plan must match the number of
assertions; the lint does not check that here, so if you add an assertion, count it.

### A test that cannot fail is not a test

An assertion that would pass whatever the code did is worse than no assertion, because
it counts towards the plan and reads as evidence. Two specific traps in this repository:

- A query that **errors** on a type cast and returns nothing compares equal to another
  empty result, so "the output matches" passes for the wrong reason. Run the query on its
  own and read the result before trusting a comparison built from it.
- A fixture built and then read within the same transaction can read statistics that are
  not visible yet. On PostgreSQL 14 the statistics collector writes asynchronously, so a
  freshly created table's dead-tuple count is not immediately observable; 15 and later
  keep statistics in shared memory and do not have this problem. Tests that read
  `pg_stat_user_tables` reuse a fixture whose statistics an earlier assertion already
  proved visible, rather than building a new one and waiting.

## Scenarios and evidence

```
./scenarios/run.sh          # every scenario, teardown before each; output in scenarios/out/
```

`scenarios/run.sh` sources `scenarios/mask.sh`, which replaces the volatile values (timestamps, pids, sizes,
rates) with named tokens. The masked capture is written to `scenarios/evidence/` and is
**committed**. Every numeric figure the documentation states is linked to the evidence
file it came from, and `scenarios/check-evidence.sh` fails if a figure in a document is
not in the file it links to.

CI compares the evidence byte for byte against what is committed. That comparison is
strict, deliberately: a comparison that is red for environmental reasons on its first
day teaches everyone to ignore red runs. So:

- **If you change what a scenario prints, regenerate the evidence and prove it is
  deterministic.** Run it three times and confirm the files are identical. A capture
  that varies between runs is a red run nobody can fix.
- `BC_EVIDENCE_STRICT=0 ./ci/job.sh <major>` prints the full diff and does not fail on
  it. Use it to diagnose a difference, never to make a red run green.

The one place files are hand-copied into a container is
`scenarios/install-extension.sh`, which copies by an **explicit file list** with a
per-file `md5sum` check. When you add a release or update script, add it there too. The
lint fails if a file is on disk, in `DATA`, and absent from that list, which is the class
of bug that once left a GitHub scenario job reporting the extension as not installed
while Forgejo stayed green.

## Proving a check fails

If you change a check, show it failing first. A check that was never seen to fail is not
evidence that it can.

```bash
# 1. break exactly one thing, and keep the break small enough to name in a sentence
# 2. reinstall, or copy the file into the container again; without this the next command
#    tests nothing
# 3. run the check and watch it fail. A check that passes here tells you the break did
#    not land, which is worth knowing before you change the check
# 4. restore, reinstall, and run it again to see it pass
```

## Releasing

1. Increment the version. The release script is `pg_bloat_cause--<new>.sql`, the `.control`
   `default_version` names it, and `DATA` lists it.
2. Add the file to `scenarios/install-extension.sh`'s `FILES` list.
3. Add a `CHANGELOG.md` entry. If it changes what a user sees, say what they will see
   differently.
4. Update the README status line and any document that names the version. The lint
   fails if a document claims the release is untagged or unreleased while a tag exists,
   and fails if the README header does not mention the current version.
5. `make lint`, `make prove` on 14 and 18, and the scenario suite green on both.
6. Tag it, one name at a time, never with `--tags`. A released tag is never edited,
   never amended and never moved.

## House style

No em-dashes or en-dashes in any document, comment, script or workflow. The lint checks
it, and a reader's eye catches it before anything else.