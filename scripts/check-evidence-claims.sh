#!/bin/sh
# check-evidence-claims.sh: every catalog a README feature table names is one the release script
# actually reads.
#
# Why this exists. A feature table's last column says where the evidence comes from, and that is a
# claim about the code. Six of those claims were wrong across two repositories in one afternoon, all
# the same way: a catalog listed that the release script never referenced. pg_bloat_cause named
# pg_stat_user_tables.autovacuum_count, n_mod_since_analyze and pg_stat_progress_vacuum; pg_limit_runway
# named mxid_age(relminmxid). Every gate passed on all four, because no gate read the prose.
#
# It was found by a manual pass, and a manual pass has to be remembered. This does not.
#
# What it checks. For each README line that begins a feature-table row (`| **`), every pg_ identifier
# on that line must appear in the newest release script, after SQL comments are stripped. Comments are
# stripped because a catalog named in a comment is not a catalog that is read: pg_bloat_cause mentions
# pg_lock_tree in a comment saying it does NOT depend on it, and a grep would count that as evidence.
#
# The allowlist. Some names are legitimately there without being read: a document may say explicitly
# that something is NOT used, or name a tool rather than a catalog (pg_dump, pg_restore). Those go in
# scripts/evidence-claims.allow, one per line, "#" for a comment, and each entry should say why. An
# allowlist is the part that rots, so it is a file that shows up in review rather than a case inside
# this script.
#
# Scope. README.md only, and only the feature tables in it. A prose paragraph elsewhere may mention a
# catalog for many reasons a rule cannot judge.

set -eu

die() { echo "  FAIL  $*" >&2; exit 1; }

here=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$here"

pass=0
allow="scripts/evidence-claims.allow"

# The release script named by the control file, not the result of sorting versions. Sorting got this
# wrong on the first port to pg_limit_runway, choosing --0.2.sql over --0.2.2.sql and checking against
# an older release: a rule that passes for the wrong reason is worse than no rule. The control file
# states the version unambiguously and is what the extension actually installs.
ctl=$(ls *.control 2>/dev/null | head -1)
[ -n "$ctl" ] || die "no .control file found"
ver=$(sed -n "s/^default_version[[:space:]]*=[[:space:]]*'\(.*\)'/\1/p" "$ctl")
[ -n "$ver" ] || die "no default_version in $ctl"
base=$(basename "$ctl" .control)
newest="$base--$ver.sql"
[ -f "$newest" ] || die "the control file names version $ver but $newest does not exist"
[ -n "$newest" ] || die "no release script found"
[ -f README.md ] || die "no README.md found"

# The script with comments removed, so a mention does not read as evidence. Both comment forms, and the
# block form is removed across lines because a multi-line comment would otherwise leak its middle.
stripped=$(mktemp); trap 'rm -f "$stripped"' EXIT
sed -e 's/--.*$//' "$newest" | sed -e ':a' -e '/\/\*[^*]*$/{N;ba' -e '}' -e 's|/\*[^*]*\*\+\([^/*][^*]*\*\+\)*/||g' > "$stripped"

# Every pg_ identifier in a feature-table row.
tokens=$(grep '^| \*\*' README.md | grep -oE 'pg_[a-z_]+' | sort -u)
[ -n "$tokens" ] || die "no feature-table rows found in README.md, which cannot be right"

bad=""
for id in $tokens; do
    if grep -q "$id" "$stripped"; then
        pass=$((pass + 1))
        continue
    fi
    if [ -f "$allow" ] && grep -qxF "$id" "$allow"; then
        pass=$((pass + 1))
        continue
    fi
    if [ -f "$allow" ] && grep -qE "^$id[[:space:]]" "$allow"; then
        pass=$((pass + 1))
        continue
    fi
    bad="$bad $id"
done

if [ -n "$bad" ]; then
    die "the README feature table names catalogs that $newest does not read:$bad. Either the claim is wrong or the SQL moved. If the name is there on purpose, add it to $allow with a reason."
fi

echo "  $pass check(s) passed, 0 failed"
