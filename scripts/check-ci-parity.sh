# vendored from pg-dev-infra harness/check-ci-parity.sh; do not edit here.
# Edit the source there and re-vendor (pg-dev-infra/scripts/vendor-harness.sh).
# vendored-sha256: 3d771828fa7177a129a2cb91f3504a375515e875d5d55fa6e43ef4b656cbd3fb
# check-ci-parity.sh: the two CI copies must agree, so that "one definition" is enforced and not a
# convention. It checks two things:
#
#   1. A job in one copy exists in the other, unless it is a documented platform difference. The
#      scenario job is one matrix job on GitHub and two named jobs on Forgejo, because the two need
#      different runner labels; that is the only difference allowed, and it is allowed by name.
#   2. The jobs the copies share run the same command. `lint` runs `./scripts/lint.sh` in both and
#      `defects` runs `make defects PG=18` in both; a change to one command in one file fails here.
#
# Without this, the two files drift the first time someone edits one, which is the failure the
# sibling check-pg-versions.sh exists to prevent for the version matrix. No shebang: this file is
# vendored and run with `bash`.
set -uo pipefail
cd "$(dirname "$0")/.."

gh=.github/workflows/ci.yml
fj=.forgejo/workflows/ci.yml
if [ ! -f "$gh" ] || [ ! -f "$fj" ]; then
    echo "  ok    no second CI copy to compare"
    exit 0
fi

python3 - "$gh" "$fj" <<'PY'
import sys, yaml

gh = yaml.safe_load(open(sys.argv[1])) or {}
fj = yaml.safe_load(open(sys.argv[2])) or {}
ghj = list((gh.get("jobs") or {}).keys())
fjj = list((fj.get("jobs") or {}).keys())
bad = []

# A job present in only one copy is a failed check, unless it is a documented platform difference.
# A repository names those in scripts/ci-parity-allow.txt (one job name per line, # comments); the
# scenario job is always one, whatever it is called, because the two copies expand it differently.
allow = set()
try:
    for line in open("scripts/ci-parity-allow.txt"):
        line = line.split("#", 1)[0].strip()
        if line:
            allow.add(line)
except FileNotFoundError:
    pass

def is_platform_difference(n):
    return n.startswith("scenarios") or n in allow

for n in ghj:
    if n not in fjj and not is_platform_difference(n):
        bad.append("only in %s: %s" % (sys.argv[1], n))
for n in fjj:
    if n not in ghj and not is_platform_difference(n):
        bad.append("only in %s: %s" % (sys.argv[2], n))

def command(wf, job, needle):
    for st in (wf["jobs"][job].get("steps") or []):
        for line in (st.get("run") or "").splitlines():
            s = line.strip()
            if s.startswith("#"):
                continue   # a comment naming the command is not the command
            if needle in s:
                return s
    return None

for job, needle in (("lint", "scripts/lint.sh"), ("defects", "make defects")):
    if job not in ghj:
        bad.append("the GitHub copy has no %s job" % job)
    if job not in fjj:
        bad.append("the Forgejo copy has no %s job" % job)
    if job in ghj and job in fjj:
        a = command(gh, job, needle)
        b = command(fj, job, needle)
        if a != b:
            bad.append("%s runs different commands: %r vs %r" % (job, a, b))
        elif a is None:
            bad.append("the %s job does not run %s" % (job, needle))

if bad:
    print("  FAIL  the two CI copies disagree:")
    for b in bad:
        print("        " + b)
    sys.exit(1)
print("  ok    both copies define the same jobs, and %s run the same command"
      % " and ".join(sorted(set(ghj) & set(fjj))))
PY
