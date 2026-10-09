#!/usr/bin/env bash
# Remove everything the scenarios left: holder sessions, the prepared transaction, the slot, the schema.
. "$(dirname "$0")/lib.sh"
val "SELECT count(pg_terminate_backend(pid)) FROM pg_stat_activity WHERE application_name LIKE 'bloat_scen_%'" >/dev/null
for f in "$RUNDIR"/holder_*.pid; do
    [ -f "$f" ] || continue
    pid=$(cat "$f"); pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; rm -f "$f"
done
for g in $(val "SELECT gid FROM pg_prepared_xacts WHERE gid LIKE 'bloat_scen_%'"); do
    psql_q -c "ROLLBACK PREPARED '$g'"
done
val "SELECT count(pg_drop_replication_slot(slot_name)) FROM pg_replication_slots WHERE slot_name LIKE 'bloat_scen_%'" >/dev/null
psql_q -c "DROP SCHEMA IF EXISTS $SCHEMA CASCADE" 2>/dev/null
echo "  teardown done"
