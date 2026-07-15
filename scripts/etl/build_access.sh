#!/usr/bin/env bash
# Build the access & trails overlay (§5.4; §6.13 `reference` role): staging.access_* →
# tiles.access via build_access.sql (drop-and-rebuild, waterways idiom), then stamp the
# freshness registry. REFERENCE-ONLY: never touches the verdict engine / legality tiles.
#
# Prereqs: the four staging tables from pull_access.sh.
# Usage:   ./scripts/etl/build_access.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh
source scripts/etl/refresh_lib.sh

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
q()    { "${PSQL[@]}" -tAq -c "$1"; }
fail() { echo "✗ $*" >&2; exit 1; }

refresh_lock "access"

for t in staging.access_mvum_roads staging.access_mvum_trails staging.access_nfs_trails staging.access_gtlf; do
  [ "$(q "SELECT to_regclass('$t') IS NOT NULL")" = "t" ] || fail "$t missing — run pull_access.sh first"
done

echo "[access] build_access.sql (4 staged sources -> tiles.access)…"
"${PSQL[@]}" < scripts/etl/build_access.sql

assert_schema tiles.access geom name travel_mode is_road surface seasonal mode_detail route_id \
  src agency state_nm data_vintage source_key
"${PSQL[@]}" -q -c "ANALYZE tiles.access;"

# Sanity: the 3-way enum must not be a one-bucket smear (acceptance criterion). Warn loudly if
# any bucket holds >90% of segments.
"${PSQL[@]}" -c "
SELECT CASE WHEN max(n) > 0.9 * sum(n)
  THEN '!! WARNING: one travel_mode bucket holds >90% of segments — mapping suspect'
  ELSE 'travel_mode mix OK (no bucket >90%)' END
FROM (SELECT count(*) AS n FROM tiles.access GROUP BY travel_mode) b;"

stamp_source access reference "$(reg_vintage access)" "$(reg_maxage access)" "$(reg_upstream access)" ok
echo "[access] ✓ built + stamped ($(q "SELECT count(*) FROM tiles.access") segments)"
