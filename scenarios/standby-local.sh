#!/usr/bin/env bash
# scenarios/standby-local.sh <major> up|down: a primary and a hot standby as two local clusters on
# one host, for s3. The Docker-free counterpart of scenarios/standby.sh, and it exists because the
# Forgejo runner's job container has no Docker socket, so that script cannot run there at all.
#
#   primary  the runner image's own cluster, restarted with the scenario settings
#   standby  a pg_basebackup -R copy on port 5433, hot_standby_feedback = on
#
# The names are pinned so the evidence matches scenarios/standby.sh byte for byte: cluster_name
# bc_standby_<major> and slot standby_s3. s3's committed evidence quotes both, and an evidence diff
# naming a different cluster is a false failure that would train everyone to ignore the gate.
#
# Differences from the official postgres image that this has to absorb, all of them found by running
# it rather than by reading it:
#
#   * Debian keeps postgresql.conf and pg_hba.conf in /etc/postgresql/<major>/main, not in PGDATA.
#     pg_basebackup therefore copies NEITHER into the standby's data directory, and the standby
#     refuses to start without both. A minimal self-contained postgresql.conf is written, and the
#     hba and ident files are copied in. Inheriting the primary's config instead would carry over its
#     port, its socket directory and its hba path.
#   * There is no gosu, which the official image has. su is used instead.
#   * pg_ctl is not on su's PATH, so the full path under /usr/lib/postgresql is required.
#
# Usage:
#   scenarios/standby-local.sh <major> up
#   scenarios/standby-local.sh <major> down
set -euo pipefail
v=$1; action=${2:-}
PGBIN="/usr/lib/postgresql/$v/bin"
CONF="/etc/postgresql/$v/main"
SDY=/tmp/bc-standby-$v
SDY_PORT=5433

as_postgres() { su postgres -s /bin/bash -c "$*"; }

if [ "$action" = down ]; then
    as_postgres "$PGBIN/pg_ctl -D $SDY -m immediate stop" >/dev/null 2>&1 || true
    rm -rf "$SDY"
    echo "  standby-local: standby removed"
    exit 0
fi
[ "$action" = up ] || { echo "usage: $0 <major> up|down" >&2; exit 1; }

# Idempotent: a standby left over from an aborted attempt holds a slot name and a data directory that
# both have to go before pg_basebackup -C will run.
as_postgres "$PGBIN/pg_ctl -D $SDY -m immediate stop" >/dev/null 2>&1 || true
rm -rf "$SDY"

echo "  standby-local: primary settings on $CONF"
# The settings ci/job.sh passes to `postgres -c ...` on the Docker primary. wal_level needs a restart;
# the rest do not, but they are all set here so the primary and the committed evidence agree.
for kv in "wal_level = logical" \
          "max_prepared_transactions = 10" \
          "log_autovacuum_min_duration = 0" \
          "autovacuum_naptime = 10s"; do
    grep -qxF "$kv" "$CONF/postgresql.conf" || echo "$kv" >> "$CONF/postgresql.conf"
done
# Replication connections need their own pg_hba line, and pg_hba is first match wins, so an existing
# `host all all` line does not cover them: the pseudo-database is `replication`. Field order is
# TYPE DATABASE USER ADDRESS METHOD. A first draft wrote an extra `all`, which put 127.0.0.1/32 in
# the METHOD column; the server said "invalid authentication method" and refused to start.
grep -qxF "host replication all 127.0.0.1/32 trust" "$CONF/pg_hba.conf" \
  || echo "host replication all 127.0.0.1/32 trust" >> "$CONF/pg_hba.conf"

pg_ctlcluster "$v" main restart
for _ in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -p 5432 && break; sleep 1; done

# A slot left by a failed attempt is dropped first, or pg_basebackup -C fails with "already exists".
psql -X -q -h 127.0.0.1 -p 5432 -U postgres \
  -c "SELECT pg_drop_replication_slot('standby_s3') FROM pg_replication_slots WHERE slot_name = 'standby_s3'" >/dev/null

echo "  standby-local: pg_basebackup into $SDY"
mkdir -p "$SDY"; chown postgres "$SDY"; chmod 700 "$SDY"
as_postgres "$PGBIN/pg_basebackup -h 127.0.0.1 -p 5432 -U postgres -D $SDY -R -X stream -C -S standby_s3"

# See the header: Debian's configuration lives outside PGDATA, so the backup has neither of these.
cat > "$SDY/postgresql.conf" <<CONF
listen_addresses = '127.0.0.1'
port = $SDY_PORT
unix_socket_directories = '$SDY'
max_prepared_transactions = 10
hot_standby_feedback = on
cluster_name = 'bc_standby_$v'
CONF
cp "$CONF/pg_hba.conf" "$CONF/pg_ident.conf" "$SDY/"
chown postgres "$SDY"/postgresql.conf "$SDY"/pg_hba.conf "$SDY"/pg_ident.conf

echo "  standby-local: starting the standby on $SDY_PORT"
as_postgres "$PGBIN/pg_ctl -D $SDY -l $SDY.log -o '-c config_file=$SDY/postgresql.conf' -w -t 60 start"
for _ in $(seq 1 60); do pg_isready -q -h 127.0.0.1 -p "$SDY_PORT" && break; sleep 1; done

# Assert the two things s3 checks and skips itself without. A standby that came up but is not in
# recovery, or that lost hot_standby_feedback, would make s3 skip, and a skip is a silent hole in the
# suite that only shows up as an evidence diff.
inrec=$(psql -X -At -h 127.0.0.1 -p "$SDY_PORT" -U postgres -c "SELECT pg_is_in_recovery()")
fb=$(psql -X -At -h 127.0.0.1 -p "$SDY_PORT" -U postgres -c "SHOW hot_standby_feedback")
[ "$inrec" = t ] || { echo "  standby-local: $SDY_PORT is not in recovery. Refusing." >&2; exit 1; }
[ "$fb" = on ] || { echo "  standby-local: hot_standby_feedback is '$fb', not on. Refusing." >&2; exit 1; }
walsender=$(psql -X -At -h 127.0.0.1 -p 5432 -U postgres -c "SELECT application_name FROM pg_stat_replication")
echo "  standby-local: up. standby in recovery, feedback on, primary walsender '$walsender'"
[ "$walsender" = "bc_standby_$v" ] \
  || echo "  standby-local: WARNING walsender is '$walsender', expected 'bc_standby_$v'; s3 evidence will differ" >&2