#!/usr/bin/env bash
# scripts/check-ci.sh: refuse to treat a commit as releasable unless Forgejo CI has actually run on
# it and actually passed.
#
# Why this exists: this repository had no Forgejo workflow and no gate, so its only CI was
# .github/workflows/ci.yml, which Forgejo also runs. On Forgejo that workflow failed on every single
# push, four runs out of four, because it asks for `runs-on: ubuntu-latest` and this instance's
# act_runner gives the job container no /var/run/docker.sock, while ci/job.sh builds its image and
# starts a primary and a standby with `docker build`, `docker run` and `docker network create`. Every
# job needing a server died on "failed to connect to the docker API"; `lint`, needing no server,
# passed. Nothing read the result, because nothing in this repository read it. A gate that reports
# success because nobody looked is worse than no gate, so this reads it.
# See .forgejo/workflows/ci.yml for the workflow itself.
#
# FAIL CLOSED, in every direction:
#   * no token, no network, no API, malformed JSON            -> refuse
#   * the commit is not on the remote yet                     -> refuse
#   * CI has not started, or is running, or waiting           -> refuse
#   * any workflow's latest run is not `success`              -> refuse
#   * a workflow reported success but a gating job is missing -> refuse
# That last one matters more than it looks. A workflow whose gating job is renamed, or dropped by a
# bad merge, reports success forever, and a gate that can silently stop gating is not a gate. Here
# there are TWO gating jobs, both scenario jobs, because a green lint proves nothing about a suite
# that never ran.
#
# Usage:  scripts/check-ci.sh [commit-ish]        (default: HEAD)
#
# Configuration, read from git config so it survives a fresh clone:
#   git config pg-bloat-cause.ci-api    http://host:3000        (default http://<remote host>:3000)
#   git config pg-bloat-cause.ci-token  /path/to/token          (default $XDG_CONFIG_HOME/forgejo/token)
#   git config pg-bloat-cause.ci-gates  'ci.yml=scenarios (14)|scenarios (18)'
#
# ci-gates maps a workflow to the jobs inside it that must exist for the run to mean anything. The
# job list is separated by `|` because there is more than one. Every workflow on the commit must be
# green regardless; the gates are an extra check, and only on the workflows named.
#
# Exit 0 = every workflow green. Exit 1 = not releasable, with the reason.
set -euo pipefail

die() { printf 'check-ci: %s\n' "$*" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 || die "python3 is not installed, so CI status cannot be read. Refusing."

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$repo_root"

cfg() { git config "pg-bloat-cause.$1" 2>/dev/null || true; }

sha=$(git rev-parse --verify "${1:-HEAD}^{commit}" 2>/dev/null) \
  || die "'${1:-HEAD}' is not a commit in this repository"

remote_url=$(git remote get-url origin 2>/dev/null) || die "no origin remote, so there is no CI to ask"

# owner/repo out of either an ssh or an https remote.
#
# There are two shapes and they have to be handled differently, because a one-size-fits-all strip gets
# one of them wrong:
#
#   scheme://authority/owner/repo.git   strip the scheme, then the authority
#   [user@]host:owner/repo.git          strip up to the colon
#
# ${x#*:} alone is wrong for the first shape: it stops at the colon in "https:", leaving the host and a
# doubled slash, so owner comes out empty and the request 404s in a way that reads like a permissions
# problem. Stripping "everything up to the first /" is wrong for the second: it eats the owner and
# leaves the repo name. Both mistakes only appear once an https remote exists, which is why this went
# unnoticed until the GitHub variant of the script met one. The two shapes are told apart here too,
# so that adding a github remote to this repository cannot silently break this gate.
case "$remote_url" in
    *://*) path=${remote_url#*://}; path=${path#*/} ;;   # https://host/owner/repo.git
    *:*)   path=${remote_url#*:} ;;                      # [user@]host:owner/repo.git
    *)     path=$remote_url ;;
esac
path=${path%.git}
path=${path#/}
case "$path" in
    */*) : ;;
    *)   die "cannot read owner/repo out of remote '$remote_url' (got '$path'). Refusing." ;;
esac
owner=${path%%/*}
repo=${path##*/}

host=$(printf '%s' "$remote_url" | sed -E 's#^(ssh://)?git@##; s#^(https?://)##; s#[:/].*$##')

api=$(cfg ci-api); [ -n "$api" ] || api="http://${host}:3000"; api=${api%/}

token_file=$(cfg ci-token)
[ -n "$token_file" ] || token_file="${XDG_CONFIG_HOME:-$HOME/.config}/forgejo/token"
[ -r "$token_file" ] || die "no readable token at '$token_file'. Set: git config pg-bloat-cause.ci-token <path>. Refusing."

subject=$(git log -1 --format=%s "$sha" | cut -c1-60)

# Is the commit even on the remote? A commit nobody pushed has no runs, and "no runs" must never be
# mistaken for "no problems".
# "On the remote" means reachable from a remote ref, not equal to one. Every commit except the tip
# has already been superseded by a later push, and ls-remote only lists tips, so a plain grep would
# report the entire history as unpushed.
tips=$(git ls-remote origin 2>/dev/null | awk '{print $1}') \
  || die "cannot reach origin to confirm $sha was pushed. Refusing rather than assume it was."
[ -n "$tips" ] || die "origin has no refs. Refusing rather than assume the push landed."

pushed=0
for tip in $tips; do
    if [ "$tip" = "$sha" ] || git merge-base --is-ancestor "$sha" "$tip" 2>/dev/null; then
        pushed=1
        break
    fi
done
[ "$pushed" -eq 1 ] \
  || die "$sha ($subject) is not on origin yet. Push it and let CI run first."

gates=$(cfg ci-gates); [ -n "$gates" ] || gates="ci.yml=scenarios (14)|scenarios (18)"

# The token is read inside python and never appears in argv, so it cannot show up in ps output.
CI_GATE_SHA="$sha" CI_GATE_API="$api" CI_GATE_OWNER="$owner" CI_GATE_REPO="$repo" \
CI_GATE_TOKEN_FILE="$token_file" CI_GATE_JOBS="$gates" CI_GATE_SUBJECT="$subject" \
python3 - <<'PY'
import json, os, sys, urllib.error, urllib.request

sha     = os.environ["CI_GATE_SHA"]
api     = os.environ["CI_GATE_API"]
owner   = os.environ["CI_GATE_OWNER"]
repo    = os.environ["CI_GATE_REPO"]
subject = os.environ["CI_GATE_SUBJECT"]
# "workflow=job|job2;workflow2=job3" -> {workflow: [job, job2]}. A workflow listed here must still
# contain every one of its jobs; a workflow not listed here is only required to be green.
gates = {}
for pair in os.environ["CI_GATE_JOBS"].split(";"):
    if "=" in pair:
        wf, jobs = pair.split("=", 1)
        gates[wf.strip()] = [j.strip() for j in jobs.split("|") if j.strip()]

def fail(msg):
    sys.stderr.write("check-ci: %s\n" % msg)
    sys.exit(1)

try:
    with open(os.environ["CI_GATE_TOKEN_FILE"]) as fh:
        token = fh.read().strip()
except OSError as e:
    fail("cannot read the token file (%s). Refusing." % e)
if not token:
    fail("token file is empty. Refusing.")

def get(path):
    req = urllib.request.Request(
        api + path,
        headers={"Authorization": "token " + token, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as fh:
            return json.load(fh)
    except urllib.error.HTTPError as e:
        fail("CI API returned HTTP %s for %s. Refusing." % (e.code, path))
    except json.JSONDecodeError as e:
        fail("CI API at %s returned something that is not JSON (%s). Refusing." % (api, e))
    except Exception as e:
        fail("could not reach the CI API at %s (%s). Refusing." % (api, e))

runs = get("/api/v1/repos/%s/%s/actions/runs?limit=50&page=1" % (owner, repo)).get("workflow_runs")
if runs is None:
    fail("CI API returned no workflow_runs list. Refusing.")

# Latest run per workflow for this commit. A stale 'cancelled' run left behind by a superseded
# push must not veto a release forever, and the latest run is what a human reads in the Actions
# tab, so that is what counts.
latest = {}
for r in runs:
    if str(r.get("commit_sha", "")).startswith(sha):
        wf = r.get("workflow_id") or r.get("prettyref") or "?"
        if wf not in latest or r["id"] > latest[wf]["id"]:
            latest[wf] = r

print("  CI for %s  %s" % (sha[:7], subject))
print("")

if not latest:
    fail("%s has no CI run at all. A commit nobody tested is not releasable." % sha[:7])

bad = []
for wf in sorted(latest):
    r = latest[wf]
    status = r.get("status")
    print("  %-12s run %-5s %s" % (wf, r["id"], status))
    if status != "success":
        if r.get("html_url"):
            print("      %s" % r["html_url"])
        bad.append("%s run %s is '%s', not 'success'" % (wf, r["id"], status))
        continue

    if wf not in gates:
        continue

    jobs = get("/api/v1/repos/%s/%s/actions/runs/%s/jobs" % (owner, repo, r["id"]))
    if not isinstance(jobs, list):
        fail("CI API returned no job list for run %s. Refusing." % r["id"])
    names = [j.get("name", "") for j in jobs]
    missing = [j for j in gates[wf] if j not in names]
    if missing:
        bad.append("%s run %s says success but has no job named %s: "
                   "the gate has stopped gating" % (wf, r["id"], ", ".join(repr(m) for m in missing)))
    else:
        print("      gating jobs present: %s" % ", ".join(gates[wf]))

print("")
for b in bad:
    sys.stderr.write("  FAIL  %s\n" % b)
if bad:
    sys.exit(1)
print("  every workflow green on %s" % sha[:7])
PY