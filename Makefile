# pg_bloat_cause Makefile
EXTENSION = pg_bloat_cause
DATA      = pg_bloat_cause--0.1.sql pg_bloat_cause--0.2.sql pg_bloat_cause--0.3.sql pg_bloat_cause--0.3.1.sql pg_bloat_cause--0.4.0.sql pg_bloat_cause--0.1--0.2.sql pg_bloat_cause--0.2--0.3.sql pg_bloat_cause--0.3--0.3.1.sql pg_bloat_cause--0.3.1--0.4.0.sql pg_bloat_cause--0.4.1.sql pg_bloat_cause--0.4.0--0.4.1.sql pg_bloat_cause--0.5.0.sql pg_bloat_cause--0.4.1--0.5.0.sql pg_bloat_cause--0.6.0.sql pg_bloat_cause--0.5.0--0.6.0.sql
PGFILEDESC = "pg_bloat_cause - why dead rows are not being cleaned up"

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# The pgTAP suite against an already-installed extension; libpq environment variables pick the server.
TESTDB ?= postgres
PG ?= 18
prove:
	pg_prove --dbname $(TESTDB) test/*.sql

# The read-side overhead benchmark: one call to bloat_cause_text() and bloat_cause_findings(), beside
# a hand-written pg_stat_user_tables query, median of N calls over a stated fixture. It creates and
# drops its own tables and needs superuser, so it passes --force itself.
bench-overhead:
	./scripts/bench-overhead.sh --force $(if $(TABLES),--tables=$(TABLES),) $(if $(N),--repeat=$(N),) $(if $(KEEP),--keep,)

# Generate PGXN metadata from the .control file and the tag; the package needs an explicit tag.
pgxn-check:
	./scripts/pgxn-meta.py --check

pgxn-package:
	./scripts/pgxn-meta.py --tag "$(TAG)" --package "$(OUT)"
defects:
	# Re-inject every recorded defect (defects/) and require the test that caught it to fail
	# again; a defect the suite no longer catches is a regression and exits non-zero.
	./scripts/check-defects.sh $(PG)

# Every figure the documentation links to scenario evidence must be in that file. No database.
lint:
	# Every database-free check, in one script. Not the recipe: the Makefile needs pgxs.mk to parse,
	# and scripts/lint.sh needs no PostgreSQL toolchain. Both CI copies call the script directly.
	./scripts/lint.sh

.PHONY: install prove defects lint bench-overhead pgxn-check pgxn-package
