#!/bin/sh
# check-new-function.sh: every function defined in the newest release script has a test that
# calls it, and a test that says so exists.
#
# Why this exists, because it is a rule about a failure and not about style. The first version of
# bloat_cause_holder() shipped broken and every gate in this repository was green. It did not
# parse, it did not bind its parameters, and it declared a column as an interval where age()
# returns an integer. pgTAP passed, all 11 scenarios ran, the evidence diff passed, lint passed,
# and the secret scans passed. Nothing caught it because nothing called it: no test, no scenario,
# and the evidence diff cannot see a function that returns no rows on an idle cluster.
#
# The bug is not exotic. It took five attempts to fix, and four of those attempts broke something
# that would have been caught by a single call. So the rule is narrow and mechanical: a function
# added in this release must be called by the test suite, in the same commit that adds it.
#
# What counts as calling it. The test file must name the function inside an assertion. A mention in
# a comment does not count, so the comment above the block cannot satisfy this, which is deliberate.
#
# Scope. Only the newest release script is checked. An update script may define functions the
# release script also defines, and those are covered by the release script's own entry. Functions
# that have existed since 0.1 are not re-checked: they were audited when they were added.

set -eu

die() { echo "  FAIL  $*" >&2; exit 1; }

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$here"

pass=0

# The newest release script: the highest version, no update arrows, no .in.
newest=$(ls pg_bloat_cause--*.sql 2>/dev/null \
         | grep -v -- '--.*--' \
         | sort -t- -k3 -n \
         | tail -1)
[ -n "$newest" ] || die "no release script found to check"

tests=$(ls test/*.sql 2>/dev/null)
[ -n "$tests" ] || die "no test files found"

# Every function this release defines, by its CREATE FUNCTION line, schema placeholder stripped.
funcs=$(sed -n 's/^CREATE FUNCTION \(@extschema@\.\)\?\([a-z_][a-z0-9_]*\)(.*/\2/p' "$newest" \
        | sort -u)

[ -n "$funcs" ] || die "no functions found in $newest, which cannot be right for a release script"

for f in $funcs; do
    # Called inside an assertion, not merely mentioned. Strip line comments first so a comment
    # naming the function cannot pass this, then look for it.
    called=no
    for t in $tests; do
        if sed 's/--.*$//' "$t" | grep -q "$f"; then
            called=yes
            break
        fi
    done
    if [ "$called" = yes ]; then
        echo "  ok    $f is called by a test"
        pass=$((pass + 1))
    else
        die "$f is defined in $newest and no test calls it. Add an assertion that calls it, in the same commit that adds the function. A mention in a comment does not count: the first version of bloat_cause_holder() shipped broken and every gate here was green, because nothing ran it."
    fi
done

# The check itself must not be deleted silently, since deleting it restores the blind spot. The list
# of checks moved from the Makefile's lint target to scripts/lint.sh, so it looks there now.
if ! grep -q 'check-new-function.sh' scripts/lint.sh; then
    die "scripts/check-new-function.sh exists but scripts/lint.sh does not run it, so it does nothing. Add it to scripts/lint.sh."
fi

echo "  $pass check(s) passed, 0 failed"