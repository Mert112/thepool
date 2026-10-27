#!/usr/bin/env bash
# Rebuild a local Postgres from the migrations and run the rules tests.
#   bash tests/run.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${DB:-pool}
dropdb --if-exists "$DB"
createdb "$DB"
psql -q -v ON_ERROR_STOP=1 "$DB" -f tests/local_auth_stub.sql
for f in supabase/migrations/*.sql; do
  case "$f" in *0006_cron.sql) continue;; esac   # pg_cron/pg_net are hosted-only
  psql -q -v ON_ERROR_STOP=1 "$DB" -f "$f" >/dev/null
done
for t in tests/*_test.sql; do
  echo "--- $t"
  psql -q -v ON_ERROR_STOP=1 "$DB" -f "$t" | grep -E 'PASSED|ERROR' || { echo "FAILED: $t"; exit 1; }
done
# the rules that live in the browser rather than the database (§i18n: the default language)
for t in tests/*_test.mjs; do
  echo "--- $t"
  node --test "$t" > /dev/null || { echo "FAILED: $t"; exit 1; }
  echo " $(basename "$t" _test.mjs | tr 'a-z' 'A-Z') TESTS PASSED"
done
# the component tests: the app's own modules, bundled with fakes for the database (npm test)
echo "--- web/src/**/*.test.mjs"
(cd web && npm test --silent > /dev/null) || { echo "FAILED: web component tests (cd web && npm test)"; exit 1; }
echo " COMPONENT TESTS PASSED"
