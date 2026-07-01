#!/usr/bin/env bash
# Load PAD-US 4.1 into staging from the per-state GDB downloads (PROJECT_PLAN.md §6.6.1).
# REPLACES the live-REST pull (pull_states_padus.sh): the AGOL query API rate-limits bulk
# extraction, so we ingest from the authoritative ScienceBase "State Downloads" bulk files.
#
# PREREQUISITE (manual, ~yearly — ScienceBase Next is browser-gated, no scriptable URL):
#   download the 8 state zips from
#     https://www.sciencebase.gov/catalog/item/6759abcfd34edfeb8710a004
#   into data/padus_gdb/ (keep filenames as-is: PADUS4_1_State_XX_GDB_KMZ.zip).
#
# The "Combined" layer (PADUS4_1Comb_..._State_XX) is the flattened manager/designation/
# ownership view — the exact equivalent of the old REST "Manager_Name" layer (verified
# feature-for-feature). Its Esri MultiSurface (curved) geometry is linearized; State_Nm is
# 2-letter (matches v3.0). Loads to the canonical staging.padus_staging (overwrite) — unify.sql
# then rebuilds tiles.legality_polygons and the Tier-B fixtures (scripts/run-tier-b.sh) gate it.
#
# Usage:  ./scripts/etl/load_padus_gdb.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
DIR=data/padus_gdb
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
FIELDS="Own_Type,Own_Name,Mang_Name,Mang_Type,Des_Tp,Unit_Nm,State_Nm,GAP_Sts,Pub_Access"
STATES=(NV CA AZ CO UT NM OR ID)

docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c "DROP TABLE IF EXISTS staging.padus_staging;" >/dev/null

first=1
for ST in "${STATES[@]}"; do
  zip="$DIR/PADUS4_1_State_${ST}_GDB_KMZ.zip"
  [ -f "$zip" ] || { echo "MISSING $zip"; exit 1; }
  outdir="$DIR/$ST"
  unzip -o -q "$zip" -d "$outdir"
  gdb=$(find "$outdir" -maxdepth 2 -name "*.gdb" -type d | head -1)
  [ -n "$gdb" ] || { echo "no .gdb in $zip"; exit 1; }
  lyr=$(ogrinfo -q "$gdb" 2>/dev/null | grep -oE "PADUS4_1Comb[A-Za-z0-9_]*" | head -1)
  [ -n "$lyr" ] || { echo "no Combined layer in $gdb"; exit 1; }
  if [ "$first" -eq 1 ]; then mode="-overwrite"; first=0; else mode="-append"; fi
  # -sql (not -select): -select is rejected with -append; an explicit SELECT works for both and
  # carries the geometry through the CONVERT_TO_LINEAR/reproject.
  out=$(ogr2ogr -f PostgreSQL "$PG" "$gdb" \
        -nln staging.padus_staging -nlt CONVERT_TO_LINEAR -nlt PROMOTE_TO_MULTI \
        -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -ct_opt WARN_ABOUT_DIFFERENT_COORD_OP=NO \
        -sql "SELECT $FIELDS FROM $lyr" $mode 2>&1) || true
  if echo "$out" | grep -iqE "ERROR"; then echo "$out" | head -6; echo "FAILED $ST"; exit 1; fi
  echo "  ${ST}: loaded ($lyr)"
done

# OBJECTID rides along from the GDB; drop it so the schema is identical to the v3.0 staging.
docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c \
  "ALTER TABLE staging.padus_staging DROP COLUMN IF EXISTS objectid;" >/dev/null

echo "total: $(docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c 'SELECT count(*) FROM staging.padus_staging;') rows in staging.padus_staging"
