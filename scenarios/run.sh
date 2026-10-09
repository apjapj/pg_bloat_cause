#!/usr/bin/env bash
# Run every scenario in turn against the server in the libpq variables, tearing down before each so
# one scenario's horizon holder cannot contaminate the next, and once more at the end.
#
# Two copies of each capture:
#   scenarios/out/<scenario>.pg<major>.txt       raw, untracked, the run exactly as it printed
#   scenarios/evidence/<scenario>.pg<major>.txt  masked by mask.sh and TRACKED: the file each numeric
#                                                claim in the READMEs links to
# EVIDENCE_DIR overrides the second, which is how two runs are compared for reproducibility.
. "$(dirname "$0")/lib.sh"
. "$HERE/mask.sh"
out="$HERE/out"; mkdir -p "$out"
evidence=${EVIDENCE_DIR:-"$HERE/evidence"}; mkdir -p "$evidence"
major=$((VER / 10000))
for s in "$HERE"/s[0-9]_*.sh "$HERE"/s[0-9][0-9]_*.sh; do
    name=$(basename "$s" .sh)
    "$HERE/teardown.sh" >/dev/null
    bash "$s" > "$out/$name.pg$major.txt" 2>&1
    case $? in 0) r=ran ;; 3) r=SKIP ;; *) r=FAILED ;; esac
    # An assertion about the extension's finding that did not hold fails the scenario, even though the
    # script itself ran to the end.
    [ "$r" = ran ] && grep -q '^  FAIL  ' "$out/$name.pg$major.txt" && r=FAILED
    mask_capture < "$out/$name.pg$major.txt" > "$evidence/$name.pg$major.txt"
    printf '  %-28s %s\n' "$name" "$r"
done
"$HERE/teardown.sh" >/dev/null
