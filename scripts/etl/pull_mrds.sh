#!/usr/bin/env bash
# Ingest MRDS GOLD occurrences (USGS Mineral Resources Data System) for the 8 states into
# staging for the REFERENCE-ONLY gold overlay (Tier A; PROJECT_PLAN §6.13 `reference` role;
# DATA_SOURCE_INVESTIGATION.md MRDS section). Display-only: it serves tiles and NEVER feeds the
# verdict engine (mineral occurrences aren't a legality input) — upholds the §6.13 invariant.
#
# Source: USGS MRDS "Compact" FeatureServer. Gold-filtered (CODE_LIST LIKE '%AU%'), clipped to
# an 8-state envelope (the build step clips precisely to the state polygons). License: public
# domain (USGS). Caveat: MRDS is STATIC — USGS stopped updating it in 2011; it is a historical
# "what's been found where" record and the UI must label it as such.
#
# Usage:  ./scripts/etl/pull_mrds.sh [outdir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-data/mrds}"
BASE="https://services.arcgis.com/v01gqwM5QqNysAAi/ArcGIS/rest/services/Mineral_Resources_Data_System_MRDS_Compact_Version/FeatureServer/0"
Q="$BASE/query"
FIELDS="SITE_NAME,DEV_STAT,CODE_LIST,URL,Grade,DEP_ID"
BBOX="-124.85,31.3,-102.0,49.05"   # 8-state envelope; build_mrds.sql clips to the state polygons
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
UA="OreScout-ETL/0.1"
PAGE=2000

# Stable offset-paging needs a deterministic order — use the layer's own OID field.
OID=$(curl -sq -A "$UA" --max-time 30 "$BASE?f=json" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("objectIdField") or "OBJECTID")')
echo "paging by OID field: $OID"

mkdir -p "$OUT"; rm -f "$OUT"/mrds_*.geojson
offset=0; i=0
while :; do
  f="$OUT/mrds_${i}.geojson"
  curl -sq -A "$UA" --max-time 60 -G "$Q" \
    --data-urlencode "where=CODE_LIST LIKE '%AU%'" \
    --data-urlencode "geometry=${BBOX}" \
    --data-urlencode "geometryType=esriGeometryEnvelope" \
    --data-urlencode "inSR=4326" \
    --data-urlencode "spatialRel=esriSpatialRelIntersects" \
    --data-urlencode "outFields=${FIELDS}" \
    --data-urlencode "orderByFields=${OID}" \
    --data-urlencode "outSR=4326" \
    --data-urlencode "f=geojson" \
    --data-urlencode "resultOffset=${offset}" \
    --data-urlencode "resultRecordCount=${PAGE}" -o "$f"
  cnt=$(python3 -c "import json;print(len(json.load(open('$f')).get('features',[])))" 2>/dev/null || echo 0)
  if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
  offset=$((offset + PAGE)); i=$((i + 1))
  [ $((i % 10)) -eq 0 ] && echo "  …pulled $i pages ($((i * PAGE)) features)"
  [ "$cnt" -lt "$PAGE" ] && break
done
echo "pulled $i page(s)"

first=1
for f in "$OUT"/mrds_*.geojson; do
  if [ "$first" -eq 1 ]; then
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln staging.mrds_gold -nlt POINT \
      -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite && first=0
  else
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln staging.mrds_gold -nlt POINT -append 2>/dev/null
  fi
done
echo "loaded: $(docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c 'SELECT count(*) FROM staging.mrds_gold;') rows into staging.mrds_gold"
echo "next: ./scripts/etl/pull_mrds_details.sh  then  ./scripts/etl/build_mrds.sh  (enrich + atomic-swap tiles.mrds)"
