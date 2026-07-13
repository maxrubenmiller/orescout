#!/usr/bin/env bash
# Build the enriched MRDS gold overlay (Tier A; §6.13 `reference` role) with the atomic-swap
# safety pattern (refresh_lib.sh) so the live tiles.mrds is never dropped mid-read.
#
#   build_mrds.sql builds tiles.mrds_new (existing columns + the additive popup-enrichment
#   columns from the related tables) → assert_schema → count_gate ±10 → atomic_swap → stamp_source.
#
# REFERENCE-ONLY: never touches the verdict engine / legality tiles. Prospectivity is NOT rebuilt
# here (build_prospectivity.sql owns tiles.prospectivity); it only reads tiles.mrds.geom/is_producer,
# both preserved. Registry (etl/sources.json) is the single source of truth for vintage/ref.
#
# Prereqs: staging.mrds_gold (pull_mrds.sh) and the related tables staging.mrds_commodity/
#          mrds_materials/mrds_names (pull_mrds_details.sh).
# Usage:   ./scripts/etl/build_mrds.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh
source scripts/etl/refresh_lib.sh

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
q()    { "${PSQL[@]}" -tAq -c "$1"; }
fail() { echo "✗ $*" >&2; exit 1; }

refresh_lock "mrds"

# preflight
for t in staging.mrds_gold staging.us_states8 staging.mrds_commodity staging.mrds_materials staging.mrds_names; do
  [ "$(q "SELECT to_regclass('$t') IS NOT NULL")" = "t" ] \
    || fail "$t missing — run pull_mrds.sh + pull_mrds_details.sh first"
done

echo "[mrds] build_mrds.sql (staging.mrds_gold + related tables -> tiles.mrds_new)…"
"${PSQL[@]}" < scripts/etl/build_mrds.sql

# gates + swap (refresh_lib): schema must include the additive columns; count within ±10% of live.
assert_schema tiles.mrds_new geom site_name dev_stat commodities grade url dep_id is_producer \
  state_nm data_vintage source_key commodities_major commodities_minor ore_minerals gangue_minerals alt_names
count_gate  tiles.mrds 10
atomic_swap tiles.mrds
"${PSQL[@]}" -q -c "ANALYZE tiles.mrds;"

# enrichment coverage report (no silent gaps)
tot=$(q "SELECT count(*) FROM tiles.mrds")
enr=$(q "SELECT count(*) FROM tiles.mrds WHERE commodities_major IS NOT NULL OR commodities_minor IS NOT NULL OR ore_minerals IS NOT NULL OR gangue_minerals IS NOT NULL OR alt_names IS NOT NULL")
echo "[mrds] enrichment coverage: $enr / $tot sites carry ≥1 related-table field"

# freshness registry stamp (reference role; MRDS is static -> max_age_days '-'/NULL)
stamp_source mrds reference "$(reg_vintage mrds)" - "$(reg_upstream mrds)" ok
echo "[mrds] ✓ built, gated, swapped, stamped ($tot sites)"
