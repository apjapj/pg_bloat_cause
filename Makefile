# pg_bloat_cause Makefile
EXTENSION = pg_bloat_cause
DATA      = pg_bloat_cause--0.1.sql pg_bloat_cause--0.2.sql pg_bloat_cause--0.1--0.2.sql
PGFILEDESC = "pg_bloat_cause - why dead rows are not being cleaned up"

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# The pgTAP suite against an already-installed extension; libpq environment variables pick the server.
TESTDB ?= postgres
prove:
	pg_prove --dbname $(TESTDB) test/*.sql

# Every figure the documentation links to scenario evidence must be in that file. No database.
lint:
	# The doc-facts checks, ported from pg_lock_tree's scripts/lint-docs.sh: the version agrees
	# across control and the newest release and the README header, every SQL file is installed
	# with no DATA duplicate, local doc paths resolve, and no em-dashes.
	./scripts/lint-docs.sh
	./scenarios/check-evidence.sh
	# Rejects a duplicated mapping key, which PyYAML accepts silently and Forgejo does not.
	# A workflow with one dispatches no jobs at all and its run reads as a plain failure.
	./scripts/check-workflows.sh

.PHONY: install prove lint
