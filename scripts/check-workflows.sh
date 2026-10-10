#!/usr/bin/env bash
# scripts/check-workflows.sh: parse every workflow file with a YAML loader that REFUSES duplicate
# keys, and fail if any file has one.
#
# Why this exists: a duplicated mapping key stopped a Forgejo workflow from dispatching at all, and
# the ordinary way of looking at the file said it was fine. PyYAML accepts a repeated key silently
# and keeps the last one, so a script that printed the parsed env showed exactly the right values
# while Forgejo refused to create a single job. The run then reads as a plain failure with nothing to
# act on: the jobs endpoint answers "job has not been executed yet" and the run carries the commit
# title as a placeholder job name.
#
# The lesson is not "YAML is dangerous", it is that the checker has to be the one thing that is
# stricter than the consumer. This script is that checker, and it deliberately rejects something
# `python3 -c "import yaml; yaml.safe_load(...)"` accepts.
#
# FAIL CLOSED:
#   * no python3, or no PyYAML                    -> refuse, naming the Debian package
#   * a workflow file that does not parse         -> refuse
#   * a workflow file with a duplicate key        -> refuse
#   * no workflow files found at all              -> refuse
# The last one matters: a glob that matches nothing reports success, so a moved or renamed directory
# would turn this into a check that checks nothing.
#
# Usage: scripts/check-workflows.sh
#
# Requires PyYAML. Where it is missing this refuses rather than skipping, because a lint that
# silently stops linting is the exact failure this script exists to prevent. On Debian:
#   apt-get install python3-yaml
set -euo pipefail

die() { printf 'check-workflows: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 \
  || die "python3 is not installed, so the workflow files cannot be parsed. Refusing."

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$repo_root"

files=$(ls -1 .forgejo/workflows/*.yml .forgejo/workflows/*.yaml \
                  .github/workflows/*.yml  .github/workflows/*.yaml 2>/dev/null || true)
[ -n "$files" ] || die "no workflow files found under .forgejo/workflows or .github/workflows. Refusing."

# One argument per file, newline separated, so a filename with a space cannot split into two.
CHECK_FILES=$(printf '%s\n' "$files") python3 - <<'PY'
import os, sys

try:
    import yaml
except ImportError:
    sys.stderr.write(
        "check-workflows: PyYAML is not installed, so duplicate keys cannot be detected and a "
        "plain parse would accept the very thing this script exists to catch. Refusing.\n"
        "  Debian/Ubuntu:  apt-get install python3-yaml\n")
    sys.exit(1)


class Strict(yaml.SafeLoader):
    """SafeLoader that raises on a repeated key in the same mapping.

    SafeLoader is still the base, so nothing unsafe is enabled: no arbitrary object construction, no
    unknown tags. Only the duplicate-key rule is added.
    """


def _no_duplicate_keys(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.YAMLError(
                "duplicate key %r at line %d (first seen at line %d)"
                % (key, key_node.start_mark.line + 1, mapping[key]))
        mapping[key] = key_node.start_mark.line + 1
    return yaml.SafeLoader.construct_mapping(loader, node, deep)


Strict.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_duplicate_keys)

failed = False
for path in os.environ["CHECK_FILES"].splitlines():
    if not path:
        continue
    try:
        with open(path) as fh:
            doc = yaml.load(fh, Loader=Strict)
    except yaml.YAMLError as e:
        # Both a duplicate key and an ordinary syntax error arrive here. Either way the file is
        # unusable, and the message says which, because the two need different fixes.
        print("  FAIL  %s" % path)
        for line in str(e).splitlines():
            print("        %s" % line)
        failed = True
        continue
    if doc is None:
        print("  FAIL  %s is empty" % path)
        failed = True
        continue
    if not isinstance(doc, dict) or "jobs" not in doc:
        print("  FAIL  %s has no jobs: it would dispatch nothing" % path)
        failed = True
        continue
    print("  ok    %s  (%d jobs)" % (path, len(doc["jobs"])))

sys.exit(1 if failed else 0)
PY