# ci

`ci/job.sh <major>` is the whole test job, so a red run reproduces on any machine with Docker, psql and
pg_prove by running the same command. `.github/workflows/ci.yml` runs it for PostgreSQL 14 and 18 on
GitHub-hosted runners, plus a lint job that needs no database. The server image is `ci/Dockerfile`: the
official `postgres` image, which ships `pgstattuple`, plus pgTAP.

## The evidence comparison is report-only, for now, and must be tightened

The job's last step compares the masked scenario evidence it produces with what is committed. Two
consecutive runs here are byte-identical, on two different image builds, but the committed files were
all made on one machine, and a hosted runner has a different host, a different `psql`, and a slower or
busier clock. A comparison that is red for environmental reasons on its first day teaches everyone to
ignore red runs, which is the failure this project was burned by in pg_lock_tree 1.1.9 and 1.1.11.

So the workflow sets `BC_EVIDENCE_STRICT=0`: a difference prints the full diff and the line
`EVIDENCE DIFFERS (report-only)`, and does not fail the job. Everything else, pgTAP and every scenario
assertion about the extension's finding, fails the job as usual. Locally the default is strict.

**To do after the first GitHub runs:** read the evidence step of each. If it says `identical`, remove the
`BC_EVIDENCE_STRICT: "0"` line from the workflow. If it shows a diff, decide whether it is a regression
or the environment, fix the fixture or the mask for the latter, and then remove the line. It is not
meant to stay.
