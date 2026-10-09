# scenarios/mask.sh: turn a raw scenario capture into evidence that is comparable between runs.
# Sourced by run.sh. Reads stdin, writes stdout.
#
# The token names are pg_lock_tree's (scripts/capture.sh): <PID>, <AGE>, <TIMESTAMP>. Its expressions
# are NOT reused, and that is deliberate. Its broadest rules replace any number of three or more digits
# between spaces with <PID>, which suits a lock tree and would erase exactly what this evidence exists
# to show: 100,000 dead rows, 6,000 in pg_attribute, a threshold of 20,050. So every rule here names the
# field it masks, and every row count, dead-row count, percentage and threshold passes through untouched.
#
# Two tokens are new, for values pg_lock_tree never prints: <XID>, a transaction id (oldest xmin,
# backend_xid, a prepared transaction's xid, catalog_xmin), and <XIDAGE>, the age of one in xids.
#
# The same ordering rule as pg_lock_tree applies in a new form: timestamps before ages, so the
# hh:mm:ss inside a timestamp is not first replaced by an age token.

MASKS=(
  # terminal colour from say()
  's/\x1b\[[0-9;]*m//g'
  # timestamps: last_autovacuum, last_vacuum, pg_prepared_xacts.prepared
  's/[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?(\+[0-9]{2})?/<TIMESTAMP>/g'
  # intervals: now() - xact_start, now() - prepared
  's/\b[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?\b/<AGE>/g'
  # xids in VACUUM VERBOSE, both formats (14: "oldest xmin: N"; 15 and later: "removable cutoff: N,
  # which was M XIDs old")
  's/oldest xmin: [0-9]+/oldest xmin: <XID>/g'
  's/removable cutoff: [0-9]+, which was [0-9]+ XIDs old/removable cutoff: <XID>, which was <XIDAGE> XIDs old/g'
  # a holder session's row: pid | application_name | state | backend_xid | backend_xmin | xid_age | open_for
  's/^ *[0-9]+ \| (bloat_scen_[a-z0-9]+) +\| ([a-z ]+[a-z]) +\| +[0-9]+ \| +\| +[0-9]+ \|/<PID> | \1 | \2 | <XID> | | <XIDAGE> |/'
  # the prepared transaction's row: gid | transaction | xid_age | ...
  's/^ (bloat_scen_gxid) +\| +[0-9]+ \| +[0-9]+ \|/ \1 | <XID> | <XIDAGE> |/'
  # the slot's row: ... | xmin | catalog_xmin | catalog_xmin_age
  's/^ (bloat_scen_slot) +\| logical +\| f +\| +\| +[0-9]+ \| +[0-9]+$/ \1 | logical | f | | <XID> | <XIDAGE>/'
  # s9's evidence row for the holder: cause | what | how_much (an xid age)
  's/^ (horizon holder) \| (bloat_scen_s9) +\| [0-9]+ *$/ \1 | \2 | <XIDAGE>/'
  # s3: a physical slot's xmin age
  's/(xmin set, xmin age )[0-9]+/\1<XIDAGE>/'
  # the extension's own sentences: a session's pid, and the age after "for"
  's/session [0-9]+ \(/session <PID> (/g'
  's/ for [0-9]+(s| min| h [0-9]{2} min| days)([.,;]| \()/ for <AGE>\2/g'
  # an autovacuum worker's pid
  's/^ *[0-9]+ \| (Lock|autovacuum worker)/<PID> | \1/'
  # pg_attribute is the CATALOG, not the fixture: how many rows it has removed and kept depends on
  # everything the cluster has done before, and so does its dead-but-not-removable count, which moved
  # between runs once a standby was attached (6,000 and 6,021). s2 reports the rows its own churn added
  # on a separate line, and that line is the evidence.
  # s2 prefixes those lines with "pg_attribute" so this rule cannot touch the user table's line, whose
  # "100000 removed" is the point of the scenario. <N> is the one token here that is not a value type.
  's/^(  pg_attribute tuples: )[0-9]+ removed, [0-9]+ remain, [0-9]+ are dead/\1<N> removed, <N> remain, <N> are dead/'
  's/^(  pg_attribute DETAIL: +)[0-9]+ dead row versions/\1<N> dead row versions/'
  # The same on 14, whose VACUUM VERBOSE reports the catalog's counts on an INFO line instead.
  's/^(  pg_attribute INFO: +table "pg_attribute": found )[0-9]+ removable, [0-9]+ nonremovable row versions in [0-9]+ out of [0-9]+ pages/\1<N> removable, <N> nonremovable row versions in <N> out of <N> pages/'
)

mask_capture() {
    local args=() e
    for e in "${MASKS[@]}"; do args+=(-e "$e"); done
    # NOTICE lines report what already existed, which depends on the previous run, not on this one.
    # psql's column padding depends on the width of values that are then masked, so runs of spaces are
    # squeezed to one and table rule lines are dropped. The content of every cell is unchanged.
    grep -v '^NOTICE:' | sed -E "${args[@]}" | sed -E -e 's/ +/ /g' -e 's/ +$//' -e '/^-+(\+-+)*$/d'
}
