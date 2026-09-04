#!/bin/sh
# Rebuild the security model from the staged EDGAR events. Phase 0 runs
# this directly; once the model is validated it moves into build-silver.
set -e
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
psql "$PG_DSN" -v ON_ERROR_STOP=1 -q -f sql/00_reference/040_security_model.sql 2>&1 | grep -v NOTICE || true
psql "$PG_DSN" -v ON_ERROR_STOP=1 -q -f sql/00_reference/041_security_derive.sql 2>&1 | grep -v NOTICE || true
psql "$PG_DSN" -q \
  -c "\copy sec_reference.security_event_raw FROM 'data/reference/security_events.csv' WITH (FORMAT csv, HEADER true)" \
  -c "\copy sec_reference.company_name_raw  FROM 'data/reference/company_names.csv'  WITH (FORMAT csv, HEADER true)"
psql "$PG_DSN" -v ON_ERROR_STOP=1 -q -f sql/00_reference/042_security_populate.sql
psql "$PG_DSN" -v ON_ERROR_STOP=1 -q -f sql/00_reference/043_eligibility.sql 2>&1 | grep -v NOTICE || true
echo "security model rebuilt"
