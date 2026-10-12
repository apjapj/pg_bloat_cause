# Security policy

## Supported versions

| Version | Supported | Why |
|---|---|---|
| 0.1 | **yes** | the current release, tagged `v0.1.0` |

Fixes are made on `main` and released as a new version. Released tags are not edited.

## Reporting a vulnerability

**Do not open a public issue.** There are two ways to report privately, and either is fine.

**By e-mail: linux.postgres+pg_bloat_cause@gmail.com.** This works today, and it keeps working: the
address does not depend on anything about this repository.

**By GitHub:** the **Report a vulnerability** button, on this repository's Security tab, under
Advisories. A report there is a private advisory that only you and the maintainers can see, and you
are credited on it. GitHub offers this on public repositories only, so it appears here once this
repository is public; the e-mail above is the channel that works either way.

Either way, please include the pg_bloat_cause version (`SELECT extversion FROM pg_extension WHERE extname =
'pg_bloat_cause'`), the PostgreSQL major version, the roles the statements ran as and their grants, and the
smallest set of statements that shows the problem.

You will get an acknowledgement within 7 days. This is a small project maintained in spare time, so
there is no fixed date for a fix; you will be told what is planned, and credited in the CHANGELOG
unless you ask not to be.

## What counts

pg_bloat_cause is pure SQL, reads only, and every function and the view run with the **caller's**
rights (`SECURITY INVOKER`; none is `SECURITY DEFINER`), as INSTALL.md explains. So the issues that
matter most are about privilege and about writing:

- a role reading something its grants should hide, for example another user's session details
  without `pg_read_all_stats`;
- anything in the extension writing, locking for longer than a catalog read, or running code as
  another role, for example through an unqualified name and `search_path`;
- a role with no grants able to call a function: all are revoked from `PUBLIC` by default.

A finding that names the wrong cause is a bug, not a vulnerability; please open an ordinary issue.
