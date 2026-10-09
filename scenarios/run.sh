#!/usr/bin/env bash
# Run every scenario in turn against the server in the libpq variables, tearing down before each so
# one scenario's horizon holder cannot contaminate the next, and once more at the end. Output goes to
# scenarios/out/<scenario>.pg<major>.txt.
. "$(dirname "$0")/lib.sh"
out="$HERE/out"; mkdir -p "$out"
major=$((VER / 10000))
for s in "$HERE"/s[0-9]_*.sh; do
    name=$(basename "$s" .sh)
    "$HERE/teardown.sh" >/dev/null
    bash "$s" > "$out/$name.pg$major.txt" 2>&1
    case $? in 0) r=ran ;; 3) r=SKIP ;; *) r=FAILED ;; esac
    printf '  %-28s %s\n' "$name" "$r"
done
"$HERE/teardown.sh" >/dev/null
