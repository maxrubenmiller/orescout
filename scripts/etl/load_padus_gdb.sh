#!/usr/bin/env bash
# Load PAD-US 4.1 into staging from the per-state GDB downloads (PROJECT_PLAN.md §6.6.1).
# REPLACES the live-REST pull (pull_states_padus.sh): the AGOL query API rate-limits bulk
# extraction, so we ingest from the authoritative ScienceBase "State Downloads" bulk files.
#
# DOWNLOAD IS AUTOMATED (2026-07-11, decision #43; supersedes the #35 "browser-gated manual
# download" — the plain ScienceBase catalog API serves these files without auth; verified):
#   missing state zips are fetched from catalog/file/get/<item>?name=PADUS4_1_State_XX_GDB_KMZ.zip
#   (~1.5 GB total for the 8 states, retried for ScienceBase flakiness, size-sanity-checked).
#   Zips already in data/padus_gdb/ are reused as-is, so re-runs don't re-download.
#   NOTE: a PAD-US RELEASE BUMP is still a human-approved Class-3 refresh — run
#   scripts/etl/padus_reconcile_gate.sh after loading, then rebuild_legality.sh + the full gate
#   suite (docs/DATA_REFRESH_PLAN.md §3).
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

SB_ITEM="6759abcfd34edfeb8710a004"
download_state_zip() {  # <two-letter state> — fetch into $DIR with retry + size sanity
  local st="$1" name="PADUS4_1_State_$1_GDB_KMZ.zip" try
  local url="https://www.sciencebase.gov/catalog/file/get/${SB_ITEM}?name=PADUS4_1_State_${st}_GDB_KMZ.zip"
  for try in 1 2 3; do
    echo "  ${st}: downloading (attempt $try)…"
    if curl -sq -L --max-time 1800 -A "OreScout-ETL/0.1" -o "$DIR/$name" "$url"; then
      # ScienceBase sometimes serves an HTML error page with HTTP 200 — a real state GDB zip
      # is tens of MB; require >10 MB AND a zip magic.
      if [ "$(stat -f%z "$DIR/$name" 2>/dev/null || stat -c%s "$DIR/$name")" -gt 10000000 ] \
         && head -c2 "$DIR/$name" | grep -q "PK"; then return 0; fi
    fi
    sleep $(( try * 10 ))
  done
  echo "MISSING $DIR/$name (download failed after 3 attempts)"; return 1
}

mkdir -p "$DIR"
first=1
for ST in "${STATES[@]}"; do
  zip="$DIR/PADUS4_1_State_${ST}_GDB_KMZ.zip"
  [ -f "$zip" ] || download_state_zip "$ST" || exit 1
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
