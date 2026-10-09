#!/usr/bin/env bash
# scenarios/check-evidence.sh: every figure the READMEs link to an evidence file must appear in it.
#
# The READMEs cite numbers as links, [100,000](scenarios/evidence/s2_logical_slot.pg18.txt), so a
# reader can open the run behind each one. This reads every such link and fails if the linked file
# does not exist or does not contain the figure. Thousands separators and a trailing % are dropped
# before matching (the figure as written also counts), and the match is on a whole number, so 6,000
# cannot be satisfied by 16000.
# Needs no database: it checks the documents against the committed evidence, not against a server.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0 n=0
check_doc() {
    # Paths resolve against the document's own directory, which is what a renderer does: README.md
    # links to scenarios/evidence/..., docs/ranking.md to ../scenarios/evidence/...
    local doc=$1 base link fig path file want
    base=$(dirname "$doc")
    while IFS= read -r link; do
        fig=${link#\[}; fig=${fig%%\]*}
        path=${link#*\(}; path=${path%\)}
        file="$base/$path"
        want=$(printf '%s' "$fig" | tr -d ',%')
        n=$((n + 1))
        if [ ! -f "$file" ]; then
            printf '  FAIL  %s cites %s, which does not exist\n' "$doc" "$path"; fail=1
        # Either form counts, because the captures print both: psql's 100000 and the scripts' 110,000.
        elif ! grep -qE "(^|[^0-9.,])(${want//./\\.}|${fig%\%})([^0-9,]|$)" "$file"; then
            printf '  FAIL  %s cites %s in %s, which does not contain it\n' "$doc" "$fig" "$path"; fail=1
        fi
    done < <(grep -oE '\[[0-9][0-9,.]*%?\]\(([.][.]/)?(scenarios/)?evidence/[^)]+\)' "$doc")
}
for doc in README.md scenarios/README.md docs/*.md; do
    [ -f "$doc" ] && check_doc "$doc"
done

if [ "$n" -eq 0 ]; then
    echo "  FAIL  no evidence links found at all, so nothing was checked"; exit 1
fi
[ "$fail" -eq 0 ] && echo "  ok    all $n linked figures appear in the evidence file they cite"
exit "$fail"
