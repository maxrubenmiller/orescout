#!/usr/bin/env bash
# Ingest CA CAL FIRE/FRAP public-ownership ("Land Ownership") into staging for the
# Confirm-Open cross-check (PROJECT_PLAN §6.4.1, decision #30; docs/research/DATA_SOURCE_INVESTIGATION.md).
#
# Source: the official CAL FIRE org (egis.CALFIRE) hosted view on ArcGIS Online
# (svcs1.arcgis.com — reachable; egis.fire.ca.gov itself is not). PUBLIC ownership only
# (excludes private). Fields: Own_Level (Federal/State/Local/...), Own_Agency, Own_Group.
# License: CC-BY (CAL FIRE/FRAP) — ingestable, attribute in UI.
#
# Usage:  ./scripts/etl/pull_calfire.sh [outdir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-data/ca}"
CF="https://jUJYIo9tSA7EHvfZ.svcs1.arcgis.com/jUJYIo9tSA7EHvfZ/arcgis/rest/services/Public_Land_Ownership_view/FeatureServer/0/query"
FIELDS="Own_Level,Own_Agency,Own_Group"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
UA="OreScout-ETL/0.1"

mkdir -p "$OUT"; rm -f "$OUT"/calfire_*.geojson
offset=0; i=0
while :; do
  f="$OUT/calfire_${i}.geojson"
  curl -s -A "$UA" "${CF}?where=1%3D1&outFields=${FIELDS}&outSR=4326&f=geojson&resultOffset=${offset}&resultRecordCount=2000" -o "$f"
  cnt=$(python3 -c "import json;print(len(json.load(open('$f')).get('features',[])))" 2>/dev/null || echo 0)
  if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
  offset=$((offset + 2000)); i=$((i + 1))
  [ "$cnt" -lt 2000 ] && break
done
echo "pulled $i page(s)"

first=1
for f in "$OUT"/calfire_*.geojson; do
  if [ "$first" -eq 1 ]; then
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln staging.calfire_ownership -nlt PROMOTE_TO_MULTI \
      -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite && first=0
  else
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln staging.calfire_ownership -nlt PROMOTE_TO_MULTI -append 2>/dev/null
  fi
done
echo "loaded: $(docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c 'SELECT count(*) FROM staging.calfire_ownership;') rows"
