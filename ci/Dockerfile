# ci/Dockerfile: the server image the CI job runs, and that ci/job.sh builds locally too.
#
# The official postgres image already ships pgstattuple, which the scenarios use to measure what the
# statistics only estimate. pgTAP is the one addition, from the PostgreSQL apt repository the official
# image already has configured. Nothing here is private, so a GitHub-hosted runner can build it; the
# internal-tooling images used locally live in a registry the public runners cannot reach.
ARG PG_MAJOR=18
ARG APT_MAJOR=18
FROM postgres:${PG_MAJOR}
ARG PG_MAJOR
ARG APT_MAJOR
RUN apt-get update \
 && apt-get install -y --no-install-recommends "postgresql-${APT_MAJOR}-pgtap" \
 && rm -rf /var/lib/apt/lists/*
