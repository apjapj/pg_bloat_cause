#!/usr/bin/env bash
# lint-docs.sh: check that the documentation's claims match the code.
#
# The portable core of pg_lock_tree's scripts/lint-docs.sh, carrying the checks that are
# unambiguous and repo-generic. The object-exists, test-plan, capture and anchor checks from
# the original are NOT here: they name pg_lock_tree objects and would report a bloat_cause or
# runway object as missing. This is deliberately less than the original, not a rewrite of it.
#
# The bug this exists for: a README that said 0.1 while the extension was 0.2 and tagged, and
# nothing caught it. The check below that would have caught it is "the control version appears
# in the README header", because the stale banner never mentioned the real version.
#
# Usage: ./scripts/lint-docs.sh
#
# Pure text and git. Needs no database, no network, no superuser, so it is safe anywhere and
# cheap enough for a pre-commit hook. Everything here can be checked mechanically; nothing here
# reads prose for meaning.
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
pass=0
ok()  { printf '  \033[32mok\033[    \033[0m %s\n' "$1"; pass=$((pass+1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); }
step(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

# The extension name, from the single .control file at the repo root. A repo with no .control
# (pg_incident_watch) has no version or install to check; the path and style checks still run.
ctrl=$(ls ./*.control 2>/dev/null | head -1)
ext=""; ver=""
if [ -n "$ctrl" ]; then
  ext=$(basename "$ctrl" .control)
  ver=$(sed -n "s/^default_version = '\(.*\)'/\1/p" "$ctrl")
fi

# Every documentation file. Defined in one place so it cannot be written in three and checked
# in one. Missing files are skipped, so a repo without scenarios/ does not fail here.
DOCS_ALL="README.md INSTALL.md SECURITY.md CONTRIBUTING.md docs/*.md scenarios/README.md"

# Every tracked file, NUL-separated, honouring .gitignore via git ls-files. Falls back to a
# find when there is no repository (a downloaded tarball), so the style check is not vacuous
# there: a linter that passes because it saw nothing is worse than no linter.
tracked_files() {
  if git rev-parse --git-dir >/dev/null 2>&1; then
    git ls-files -z
  else
    find . -type f -not -path './.git/*' -print0
  fi
}

step "the version is the same everywhere it is written down"

if [ -z "$ext" ]; then
  ok "no .control file, so there is no version to check (this repo ships no extension yet)"
else
  # Newest release script. The version component is (.[0-9]+)* rather than .[0-9]+, so a version
  # like 0.2.1 is recognised; a bare .[0-9]+ would match nothing and the guard would exit 2.
  # Update paths carry a second -- and are excluded, so 0.1--0.2 never sorts as a release.
  latest=$(ls "${ext}"--[0-9]*.sql 2>/dev/null \
    | grep -E "^${ext}--[0-9]+(\.[0-9]+)*\.sql$" | sort -V | tail -1)
  latest_ver=""
  if [ -n "$latest" ]; then
    latest_ver=$(basename "$latest" .sql); latest_ver=${latest_ver#${ext}--}
  fi

  [ -n "$ver" ] && [ "$ver" = "$latest_ver" ] \
    && ok "control default_version is $ver, and the newest release script is $latest_ver" \
    || bad "control says ${ver:-<none>} but the newest release script is ${latest_ver:-<none>}"

  # The README must mention the real version in its header. A stale banner names an older
  # version and never mentions the current one, so requiring the current version to appear up
  # top catches it without parsing which word is "the" version. Scoped to the first 12 lines:
  # the status line lives there, and later prose may legitimately discuss old versions.
  if [ -f README.md ] && [ -n "$ver" ]; then
    if head -12 README.md | grep -qE "(^|[^0-9.])${ver//./\\.}([^0-9.]|$)"; then
      ok "README header mentions the current version $ver"
    else
      bad "README header does not mention the current version $ver; the status line is stale"
    fi
  fi
fi

# Every release and update script must be installed: either listed literally in DATA, or
# covered by a wildcard in the Makefile. pg_lock_tree installs update paths via a UPGRADES
# wildcard; runway lists them in DATA. Both are correct, so both are accepted.
if [ -n "$ext" ] && [ -f Makefile ]; then
  step "every SQL file gets installed"
  for f in "${ext}"--*.sql; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    if grep -q "$b" Makefile; then
      ok "$b is installed by the Makefile"
    elif grep -qE "${ext}--\*--\*\.sql" Makefile; then
      ok "$b installs via the UPGRADES wildcard"
    else
      bad "$b exists but the Makefile never installs it"
    fi
  done

  # No file twice in DATA: GNU install refuses to install the same file twice in one command.
  data_line=$(sed -n 's/^DATA[[:space:]]*=[[:space:]]*//p' Makefile | head -1)
  dup=$(printf '%s\n' "$data_line" | tr ' ' '\n' | grep -v '^$' | sort | uniq -d)
  [ -z "$dup" ] && ok "no file is listed twice in DATA, which install would refuse" \
    || bad "DATA lists these more than once and install stops: $(printf '%s' "$dup" | tr '\n' ' ')"

  # A name in DATA with no file behind it: PGXS fails on it as hard.
  missing=$(printf '%s\n' "$data_line" | tr ' ' '\n' | grep -v '^$' | while read -r f; do
             [ -f "$f" ] || printf '%s ' "$f"; done)
  [ -z "$missing" ] && ok "every name in DATA has a file on disk behind it" \
    || bad "DATA lists files that do not exist: $missing"
fi

# A path or link in a doc is relative to that doc, not the repo root. Glob and shell
# metacharacters mark a pattern, not a path, and are skipped. Fragments (#anchor) are stripped
# and only the file part is checked; matching anchors to headings is not ported here.
step "every local path the docs mention exists"
for f in $DOCS_ALL; do
  [ -f "$f" ] || continue
  dir=$(dirname "$f")
  link_targets=$(grep -oE '\]\([A-Za-z0-9_./#-]+\)' "$f" 2>/dev/null | sed -E 's/^\]\(//; s/\)$//')
  without_links=$(sed -E 's/\[[^][]*\]\([^)]*\)/@LINK@/g' "$f")
  bare=$(printf '%s\n' "$without_links" \
         | grep -oE '`[A-Za-z0-9_][A-Za-z0-9_./-]*\.(sql|md|sh|control)`' 2>/dev/null | tr -d '`')
  paths=$(printf '%s\n%s\n' "$link_targets" "$bare" \
          | grep -vE '^(https?:|mailto:|[^ ]*[?*<>][^ ]*$|[^ ]*[0-9]\.x[^ ]*$|#)' | sort -u)
  for p in $paths; do
    case "$p" in
      *#*) p=${p%%#*} ;;                    # fragment: test the file part only
    esac
    [ -n "$p" ] || continue
    case "$p" in
      /*) continue ;;                       # absolute path, not this repo's business
    esac
    if [ -e "$dir/$p" ] || [ -e "$p" ]; then :; else bad "$f mentions '$p', which does not exist"; fi
  done
done

step "house style"
# No em-dashes or en-dashes in any document. The house rule, and the one a reader's eye
# catches before anything else.
dashfiles=$(tracked_files | tr '\0' '\n' \
  | grep -E '\.(md|sql|sh|yml|yaml)$' \
  | while IFS= read -r p; do grep -lP '\x{2013}|\x{2014}' "$p" 2>/dev/null; done)
if [ -z "$dashfiles" ]; then
  ok "no em-dashes or en-dashes in any .md, .sql, .sh or workflow file"
else
  bad "these files contain an em-dash or en-dash: $(printf '%s' "$dashfiles" | tr '\n' ' ')"
fi

printf '\n\033[1m%d checks passed, %d failed\033[0m\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
