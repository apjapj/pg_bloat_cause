#!/bin/sh
# check-scenario-stats.sh: a scenario that reads a cumulative statistic must settle the statistics
# first.
#
# Why this exists. s15_measure read the estimate (pg_stat_user_tables.n_dead_tup, through
# bloat_cause_findings) immediately after an UPDATE and compared the measurement to it. On
# PostgreSQL 14 the stats collector writes that counter asynchronously, so in CI it was still zero, the
# findings row was absent, and the comparison failed. Nothing here read the scenarios for that shape,
# so it reached CI as a flake.
#
# It is the same asynchrony behind the earlier pg_stat_activity polling flake, which is why the class
# is worth a text check and not another careful read of each file. A counter that is written after the
# transaction that changed it is not readable at a fixed point in the script; settle_stats is the
# wait, and a scenario that names one must use it.
#
# What it checks. For each scenarios/sN_*.sh, after comments are removed, the first line that names a
# cumulative statistic from pg_stat_*_tables, or calls a function that reads one without naming it,
# must be preceded in the same file by a call to settle_stats. The function list is what covers
# s15_measure, which read the estimate through bloat_cause_findings and named the counter only in a
# comment. A deliberate long wait (the autovacuum scenarios sleep several naptimes before they read) is
# not enough on its own: the counter is written by the collector at its own cadence, so the rule is one
# shape everywhere. Comments are removed because a scenario that explains why it settles would
# otherwise be read as a scenario that does not.
#
# The list is short and named rather than inferred: when a new way to read the counters appears, it
# is a line below.
#
# Usage: ./scripts/check-scenario-stats.sh
set -eu
cd "$(dirname "$0")/.."

# The cumulative counters pg_stat_all_tables exposes. Each is written after the statement that changed
# it, by the stats collector on 14 and by the backend at transaction end on 15 and later, so none of
# them is safe to read without settling first.
stats='n_dead_tup|n_live_tup|n_mod_since_analyze|n_ins_since_vacuum|n_tup_ins|n_tup_upd|n_tup_del|n_tup_hot_upd|n_tup_newpage_upd'

# The functions that read those counters without naming them in the scenario. The extension's finding
# reads n_dead_tup and last_autovacuum, and these helpers wrap it or read pg_stat_user_tables
# directly, so a scenario that calls one is reading a cumulative statistic and must settle first too.
# This is the list that closes the s15 gap: s15_measure read the estimate through bloat_cause_findings
# and named n_dead_tup only in a comment, which is what let it reach CI. measured is deliberately NOT
# here: it calls pgstattuple, which reads the heap and not a counter, so it does not race.
funcs='bloat_cause_findings|bloat_cause_text|usual_query|finding|assert_finding'

fail=0
checked=0
for f in scenarios/s[0-9]*.sh; do
    [ -f "$f" ] || continue
    # Comments out, because prose about a counter is not a read of it. The line numbers reported below
    # are therefore into the code, not the file, which is why the offending line is printed too.
    code=$(grep -vE '^[[:space:]]*#' "$f")
    read_line=$(printf '%s\n' "$code" | grep -nE "($stats)|\b($funcs)\b" | head -1)
    [ -n "$read_line" ] || continue
    checked=$((checked + 1))
    read_no=${read_line%%:*}
    settle_no=$(printf '%s\n' "$code" | grep -nE '\bsettle_stats\b' | head -1 | cut -d: -f1)
    if [ -z "$settle_no" ] || [ "$settle_no" -ge "$read_no" ]; then
        printf '  FAIL  %s reads a cumulative statistic without settle_stats first:\n' "$f"
        printf '          %s\n' "${read_line#*:}"
        fail=1
    fi
done

# A check that saw nothing is worse than no check: if the pattern or the glob stops matching, this
# says so rather than reporting success on an empty set.
if [ "$checked" -eq 0 ]; then
    echo "  FAIL  no scenario read a cumulative statistic; the pattern or the scenario glob is wrong"
    exit 1
fi

[ "$fail" -eq 0 ] && printf '  ok    %d scenario(s) that read a cumulative statistic settle first\n' "$checked"
exit $fail
