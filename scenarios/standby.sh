#!/usr/bin/env bash
# scenarios/standby.sh <major> <primary-port> <standby-port>: build a primary and a hot standby from
# the pg_lock_tree matrix image, for s3. Docker only; no database needed beforehand.
#
#   primary  bc-pri-<major>  wal_level=logical and the other scenario settings, as the README states
#   standby  bc-sby-<major>  pg_basebackup -R from the primary through its own physical slot
#                            standby_s3, then hot_standby_feedback = on
#
# The standby's entrypoint is replaced rather than configured afterwards, for the reason the README
# gives: the image's entrypoint exits when the server stops, so a server cannot be reconfigured and
# restarted in place. The slot is named standby_s3, not bloat_scen_*, so teardown.sh leaves it alone.
#
# Run scenarios/standby.sh <major> down to remove both.
set -euo pipefail
v=$1; net=bc-repl-$v; pri=bc-pri-$v; sby=bc-sby-$v
if [ "${2:-}" = down ]; then docker rm -f -v "$pri" "$sby" >/dev/null 2>&1; docker network rm "$net" >/dev/null 2>&1; exit 0; fi
pport=$2; sport=$3
# The image defaults to the local pg-dev-infra one; CI passes BC_IMAGE, built from ci/Dockerfile.
image=${BC_IMAGE:-pg-dev-infra-pg$v}
docker network create "$net" >/dev/null 2>&1 || true
docker run -d --rm --name "$pri" --network "$net" -p 127.0.0.1:"$pport":5432 -e POSTGRES_PASSWORD=test \
    "$image" postgres -c wal_level=logical -c max_prepared_transactions=10 \
    -c log_autovacuum_min_duration=0 -c autovacuum_naptime=10s >/dev/null
for _ in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -p "$pport" && break; sleep 1; done
sleep 2
# A standby refuses to start with max_prepared_transactions below the primary's (recovery aborts with
# "insufficient parameter settings"), so it is set to match above. A slot left by a failed attempt is
# dropped first, or pg_basebackup -C fails with "already exists".
PGPASSWORD=test psql -X -q -h 127.0.0.1 -p "$pport" -U postgres \
    -c "SELECT pg_drop_replication_slot('standby_s3') FROM pg_replication_slots WHERE slot_name = 'standby_s3'" >/dev/null
# Replication connections need their own pg_hba line; the image only allows them from localhost.
# pg_reload_conf() re-reads the file without stopping the server.
docker exec "$pri" bash -c 'echo "host replication all all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
PGPASSWORD=test psql -X -q -h 127.0.0.1 -p "$pport" -U postgres -c "SELECT pg_reload_conf()" >/dev/null
docker run -d --rm --name "$sby" --network "$net" -p 127.0.0.1:"$sport":5432 -e PGPASSWORD=test \
    --entrypoint bash "$image" -c "
      set -e
      mkdir -p \"\$PGDATA\" && chown postgres \"\$PGDATA\" && chmod 700 \"\$PGDATA\"
      gosu postgres pg_basebackup -h $pri -U postgres -D \"\$PGDATA\" -R -X stream -C -S standby_s3
      exec gosu postgres postgres -c hot_standby_feedback=on -c max_prepared_transactions=10 \
           -c cluster_name=bc_standby_$v" >/dev/null
for _ in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -p "$sport" && break; sleep 1; done
PGPASSWORD=test psql -X -At -h 127.0.0.1 -p "$sport" -U postgres -c "SELECT 'standby up, in recovery: ' || pg_is_in_recovery() || ', hot_standby_feedback: ' || current_setting('hot_standby_feedback')"
