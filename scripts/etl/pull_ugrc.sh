#!/usr/bin/env bash
# Ingest the Utah SGID/UGRC statewide Land Ownership layer (SITLA-hosted) into staging for
# the UT Confirm-Open cross-check (PROJECT_PLAN §6.4.1/§6.13, decision #30; IMP-01).
#
# Source: SITLA "Land Ownership" (the layer UGRC's SGID cadastre product page points at),
# 1:24k statewide ownership, revised weekly (SITLA maintains state/private, BLM federal).
# Fields: owner (Federal/State/Tribal/Private/null), agency, admin, desig.
# License: CC BY 4.0 (UGRC SGID) — ingestable; attribute "Utah SGID / SITLA" in UI.
# ~16k polygons -> ~9 pages at the server's 2000 maxRecordCount.
#
# Usage:  ./scripts/etl/pull_ugrc.sh [outdir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-data/ut}"
UG="https://gis.trustlands.utah.gov/server/rest/services/Ownership/UT_SITLA_Ownership_LandOwnership_WM/FeatureServer/0/query"
FIELDS="owner,agency,admin,desig"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
UA="OreScout-ETL/0.1"

mkdir -p "$OUT"; rm -f "$OUT"/ugrc_*.geojson
offset=0; i=0
while :; do
  f="$OUT/ugrc_${i}.geojson"
  curl -s -A "$UA" "${UG}?where=1%3D1&outFields=${FIELDS}&orderByFields=objectid&outSR=4326&f=geojson&resultOffset=${offset}&resultRecordCount=2000" -o "$f"
  cnt=$(python3 -c "import json;print(len(json.load(open('$f')).get('features',[])))" 2>/dev/null || echo 0)
  if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
  offset=$((offset + 2000)); i=$((i + 1))
  [ "$cnt" -lt 2000 ] && break
done
echo "pulled $i page(s)"

first=1
for f in "$OUT"/ugrc_*.geojson; do
  if [ "$first" -eq 1 ]; then
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln staging.ugrc_ownership -nlt PROMOTE_TO_MULTI \
      -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite && first=0
  else
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln staging.ugrc_ownership -nlt PROMOTE_TO_MULTI -append
  fi
done
echo "loaded: $(docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c 'SELECT count(*) FROM staging.ugrc_ownership;') rows"
