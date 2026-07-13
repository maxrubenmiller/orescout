#!/usr/bin/env bash
# Ingest the USGS NGDB 2026 consolidated geochemistry release into staging for the Tier-B
# prospecting-potential composite (TIER_B_FABLE_BRIEF.md; PROJECT_PLAN §5.3, decision #42).
# REFERENCE-ONLY pipeline: feeds tiles.prospectivity, never the verdict engine (§6.13).
#
# Source: "Geochemical data for rock, sediment, soil, and mineral samples, US & territories,
# 1962–2023" (Granitto et al.), DOI 10.5066/P1FXE9GK, ScienceBase 63a107a0d34e0de3a1f2795f.
# License CC0. Download-and-host (the legacy live host mrdata.usgs.gov is flaky by design
# choice we avoid it). Parquet flavor (~297 MB zip); GDAL >= 3.5 reads Parquet natively
# (verified GDAL 3.13.1 on this machine).
#
# STATED BOUNDS (no-silent-caps invariant — these filters are the deliberate scope):
#   tbl_geol -> staging.ngdb_sites : only the 8 supported states (state IN NV/CA/AZ/CO/UT/NM/OR/ID).
#   tbl_chem -> staging.ngdb_chem  : only the configured indicator species (config/prospectivity.json,
#                                    all commodities' indicator_elements — currently As,Sb,Ag,Au),
#                                    later joined to in-region sites in build_prospectivity.sql.
# Kept/dropped counts are printed at the end (per the brief's ETL-transparency acceptance).
#
# Verified-at-load facts recorded here (2026-07-10, superseding older spike caveats):
#   * Coordinates in this release are ALREADY WGS84 decimal degrees (per the release's own data
#     dictionary: "reported in decimal degrees, WGS84 projection; non-WGS84 coordinates
#     transformed by [USGS]") -> NO per-record datum handling is needed.
#   * Censoring encoding (dictionary-confirmed): qualifier '<','N','L' => qualified_value stored
#     NEGATIVE (left-censored / below detection); '>' or 'G' => right-censored, value ends in 111.
#   * species strings are exact element symbols ('As','Sb','Ag','Au'); state is the 2-letter code;
#     primary_class domain: sediment / rock / soil / mineral / geologic material.
#
# Usage:  ./scripts/etl/pull_ngdb.sh [datadir]
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh   # state list from etl/sources.json (§6.13)
OUT="${1:-data/ngdb}"
ZIP="Geochem_DataRelease_2025_11_18.parquet.zip"
URL="https://www.sciencebase.gov/catalog/file/get/63a107a0d34e0de3a1f2795f?name=${ZIP}"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
STATES="$(reg_states_sqlcsv)"

# Indicator species = union over every commodity entry in the config (data, not code).
SPECIES=$(python3 - <<'EOF'
import json
cfg = json.load(open('config/prospectivity.json'))
els = sorted({e for c in cfg['commodities'] for e in c['indicator_elements']})
print(",".join(f"'{e}'" for e in els))
EOF
)
echo "indicator species from config: ${SPECIES}"

mkdir -p "$OUT"
if [ ! -f "$OUT/tbl_geol.parquet" ]; then
  echo "downloading NGDB parquet release (~297 MB; DOI-pinned)…"
  # NOTE: the ScienceBase 'manager' URLs shown in the item JSON need auth — use catalog file/get.
  curl -sq -L --max-time 2400 -o "$OUT/$ZIP" "$URL"
  ( cd "$OUT" && unzip -o -q "$ZIP" )
fi
[ -f "$OUT/tbl_geol.parquet" ] || { echo "✗ tbl_geol.parquet missing after download/unzip" >&2; exit 1; }

echo "loading tbl_geol (8-state sites) -> staging.ngdb_sites…"
# -where/-select (NOT -dialect SQLITE -sql: a dialect SELECT drops the parquet geometry column
# and silently loads 0 rows — hit during the first ingest run).
ogr2ogr -f PostgreSQL "$PG" "$OUT/tbl_geol.parquet" \
  -nln staging.ngdb_sites -overwrite \
  -where "state IN (${STATES})" \
  -select "lab_id,state,primary_class,latitude,longitude,date_collect" \
  -lco GEOMETRY_NAME=geom -nlt POINT -a_srs EPSG:4326

echo "loading tbl_chem (indicator species only) -> staging.ngdb_chem…"
ogr2ogr -f PostgreSQL "$PG" "$OUT/tbl_chem.parquet" \
  -nln staging.ngdb_chem -overwrite \
  -dialect SQLITE \
  -sql "SELECT lab_id, species, qualified_value, units, analytic_method, qualifier
        FROM tbl_chem WHERE species IN (${SPECIES})"

echo "indexing…"
docker compose exec -T postgres psql -q -v ON_ERROR_STOP=1 -U postgres -d miningapp <<'SQL'
CREATE INDEX IF NOT EXISTS ngdb_sites_labid_idx ON staging.ngdb_sites (lab_id);
CREATE INDEX IF NOT EXISTS ngdb_sites_geom_idx  ON staging.ngdb_sites USING GIST (geom);
CREATE INDEX IF NOT EXISTS ngdb_chem_labid_idx  ON staging.ngdb_chem (lab_id);
CREATE INDEX IF NOT EXISTS ngdb_chem_species_idx ON staging.ngdb_chem (species);
SQL

echo "=== ETL transparency (stated bounds; brief acceptance) ==="
docker compose exec -T postgres psql -U postgres -d miningapp -At <<'SQL'
SELECT 'staging.ngdb_sites (8-state sites kept): ' || count(*) FROM staging.ngdb_sites;
SELECT '  of which sediment (the scored medium): ' || count(*) FROM staging.ngdb_sites WHERE primary_class = 'sediment';
SELECT 'staging.ngdb_chem (indicator-species rows kept, national): ' || count(*) FROM staging.ngdb_chem;
SQL
echo "dropped by design: all non-8-state sites (of 1,524,014 national) and all non-indicator species rows (of 59,832,162 national determinations)."
echo "next: ./scripts/etl/pull_wbd.sh  then  docker compose exec -T postgres psql -U postgres -d miningapp < scripts/etl/build_prospectivity.sql"
