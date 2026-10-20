# Security policy

## Supported versions

| Version | Supported | Why |
|---|---|---|
| 0.5.0 | **yes** | the current release, tagged `v0.5.0` |
| 0.4.1, 0.4.0, 0.3.1, 0.3, 0.2, 0.1 | yes, by updating | `ALTER EXTENSION pg_bloat_cause UPDATE TO '0.5.0'`; 0.5.0 replaces `bloat_cause_sample()` only, so any earlier version reaches it |

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

The readers (`bloat_cause`, `bloat_cause_findings()`, `bloat_cause_text()`,
`bloat_cause_holder()`, `bloat_cause_command()` and `bloat_cause_measure()`) read only and run with
the **caller's** rights (`SECURITY INVOKER`; none is `SECURITY DEFINER`), as INSTALL.md explains.
The four writers added in 0.4.0 (`bloat_cause_sample()`, `bloat_cause_prune()`,
`bloat_cause_notify()` and `bloat_cause_notify_resolved()`) also run with the caller's rights and
write only to this extension's own two tables, `bloat_cause_history` and `bloat_cause_alert`; none
of them touches a user table. So the issues that matter most are about privilege and about writing:

- a role reading something its grants should hide, for example another user's session details
  without `pg_read_all_stats`;
- anything in the extension writing, locking for longer than a catalog read, or running code as
  another role, for example through an unqualified name and `search_path`;
- a role with no grants able to call a function: all are revoked from `PUBLIC` by default.

The `holder_query` column, added in 0.5.0, is query text and is therefore untrusted input as well as
output. It is only written when the session sets `bloat_cause.holder_query` on (off by default), and
`bloat_cause_sample()` redacts the credential shapes [docs/holder-query.md](docs/holder-query.md)
lists, but that is best-effort: a stored value can still contain a secret. A reader with `SELECT` on
`bloat_cause_history` can read it, and it is worth reporting if a credential shape on that list
survives, or if the sampler stores query text with the setting off.

A finding that names the wrong cause is a bug, not a vulnerability; please open an ordinary issue.
