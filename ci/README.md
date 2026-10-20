# ci

`ci/job.sh <major>` is the whole test job, so a red run reproduces on any machine with Docker, psql and
pg_prove by running the same command. `.github/workflows/ci.yml` runs it for PostgreSQL 14 to 19 on
GitHub-hosted runners, plus a lint job that needs no database. The server image is `ci/Dockerfile`: the
official `postgres` image, which ships `pgstattuple`, plus pgTAP.

## The evidence comparison is strict

The job's last step compares the masked scenario evidence it produces with what is committed, and a
difference fails the job.

It started report-only. The committed files were all made on one machine, a hosted runner has a
different host, a different `psql` and a different clock, and a comparison that is red for environmental
reasons on its first day teaches everyone to ignore red runs, which is what pg_lock_tree shipped past in
1.1.9 and 1.1.11. The first GitHub run, 38059460144 on `5302a8e`, settled it: on a GitHub-hosted runner
(image 20261002.596) with Ubuntu's psql 16 client against PostgreSQL 14 and 18 servers, both test jobs
reported the evidence `identical`. That is a third environment after two local image builds, so the
workflow is now strict.

**Report-only is still there for diagnosis.** `BC_EVIDENCE_STRICT=0 ./ci/job.sh <major>` prints the full
diff with the line `EVIDENCE DIFFERS (report-only)` and does not fail on it; unset or 1 fails. Use it to
see a difference without stopping at it, never to make a red run green.
