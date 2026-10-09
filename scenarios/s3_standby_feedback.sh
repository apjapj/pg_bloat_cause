#!/usr/bin/env bash
# s3: a physical standby with hot_standby_feedback = on and a long query on the standby. The primary
# sees it as backend_xmin on the walsender, or as the xmin of a physical slot.
#
# Skipped, deliberately. It needs a second server, a base backup and streaming replication, and the
# matrix images are single servers. The evidence a primary can see (pg_stat_replication.backend_xmin
# and pg_replication_slots.xmin) has the same shape as s1's, so the attribution logic is exercised by
# s1; what is not exercised is reading it from the walsender. Building a primary/standby pair is the
# follow-up, and needs its own compose file.
. "$(dirname "$0")/lib.sh"
skip "needs a primary/standby pair; the matrix images are single servers"
