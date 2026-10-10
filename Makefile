# pg_bloat_cause Makefile
EXTENSION = pg_bloat_cause
DATA      = pg_bloat_cause--0.1.sql
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
	./scenarios/check-evidence.sh
	# Rejects a duplicated mapping key, which PyYAML accepts silently and Forgejo does not.
	# A workflow with one dispatches no jobs at all and its run reads as a plain failure.
	./scripts/check-workflows.sh

.PHONY: install prove lint
