#!/usr/bin/env bash
# s8: updates that cannot be HOT. Four tables, 20,000 rows each, every row updated once:
#
#   s8_indexed_room   update an INDEXED column, fillfactor 70 (room on the page)
#   s8_indexed_full   update an INDEXED column, fillfactor 100 (no room)
#   s8_plain_full     update an unindexed column, fillfactor 100 (no room)
#   s8_plain_room     update an unindexed column, fillfactor 50 (room): the HOT control
#
# The question is whether n_tup_newpage_upd (16 and later) can say WHY an update was not HOT. It counts
# updates whose new version went to another page. If it is clean, "no room" shows up there and
# "indexed column" does not. s8_indexed_full is the case built to test that.
. "$(dirname "$0")/lib.sh"
setup_schema
for spec in "indexed_room 70" "indexed_full 100" "plain_full 100" "plain_room 50"; do
    set -- $spec
    psql_q -c "DROP TABLE IF EXISTS $SCHEMA.s8_$1" \
           -c "CREATE TABLE $SCHEMA.s8_$1 (id int PRIMARY KEY, k int, v text) WITH (fillfactor = $2, autovacuum_enabled = false)" \
           -c "CREATE INDEX ON $SCHEMA.s8_$1 (k)" \
           -c "INSERT INTO $SCHEMA.s8_$1 SELECT g, g, repeat('x', 100) FROM generate_series(1, 20000) g"
done
psql_q -c "UPDATE $SCHEMA.s8_indexed_room SET k = k + 1" \
       -c "UPDATE $SCHEMA.s8_indexed_full SET k = k + 1" \
       -c "UPDATE $SCHEMA.s8_plain_full   SET v = repeat('y', 100)" \
       -c "UPDATE $SCHEMA.s8_plain_room   SET v = repeat('y', 100)"
settle_stats

usual_query s8_indexed_room,s8_indexed_full,s8_plain_full,s8_plain_room
say "evidence: HOT and new-page counts"
if [ "$VER" -ge 160000 ]; then newpage="n_tup_newpage_upd"; else newpage="NULL::bigint"; fi
psql -X -P pager=off -c "
SELECT relname, n_tup_upd, n_tup_hot_upd, $newpage AS n_tup_newpage_upd,
       n_tup_upd - n_tup_hot_upd AS non_hot
  FROM pg_stat_user_tables WHERE schemaname = '$SCHEMA' AND relname LIKE 's8_%' ORDER BY relname"
[ "$VER" -ge 160000 ] || note "n_tup_newpage_upd does not exist before 16: on this version the finding cannot separate 'no room' from 'indexed column' and must say so"
expected "s8_plain_room all HOT. s8_indexed_* not HOT because an indexed column changed. s8_plain_full
  not HOT because the page had no room (fillfactor 100). See the README for whether newpage tells
  s8_indexed_full apart from s8_plain_full."
