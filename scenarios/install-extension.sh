#!/usr/bin/env bash
# scenarios/install-extension.sh <container>...: copy pg_bloat_cause into scenario containers.
#
# Follows the rule in pg_lock_tree's CONTRIBUTING.md for hand copies into a container, because these
# containers have no source mount and no make: an explicit file list, never a glob; the destination
# file named, never a directory; the inner $(pg_config ...) quoted so it expands in the container; and
# an md5 of every destination compared with its source, a mismatch being a failed install.
set -euo pipefail
cd "$(dirname "$0")/.."
FILES="pg_bloat_cause.control pg_bloat_cause--0.1.sql pg_bloat_cause--0.2.sql pg_bloat_cause--0.3.sql pg_bloat_cause--0.1--0.2.sql pg_bloat_cause--0.2--0.3.sql"
for c in "$@"; do
    for f in $FILES; do
        want=$(md5sum "$f" | cut -d' ' -f1)
        docker cp "$f" "$c:/tmp/install-$f"
        docker exec -u root "$c" sh -c "cp /tmp/install-$f \"\$(pg_config --sharedir)/extension/$f\""
        got=$(docker exec "$c" sh -c "md5sum \"\$(pg_config --sharedir)/extension/$f\"" | cut -d' ' -f1)
        if [ "$got" != "$want" ]; then echo "  MISMATCH $c $f"; exit 1; fi
    done
    echo "  installed into $c, md5 verified: $FILES"
done
