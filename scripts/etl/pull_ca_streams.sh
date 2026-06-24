#!/usr/bin/env bash
# Ingest the CA Streams dataset (CDFW "California Streams") into staging for the
# REFERENCE-ONLY waterways overlay (PROJECT_PLAN §6.13 `reference` role;
# DATA_SOURCE_INVESTIGATION.md waterways section). Display-only: it serves tiles and
# NEVER feeds the verdict engine (streams are not a legality input).
#
# Source: CDFW hosted FeatureServer (services2.arcgis.com/Uq9r85Potqm3MfRV). 740,662
# polylines. License: CC-BY (CDFW) — ingestable, attribute in UI.
# We capture geometry + the NETWORK attributes (not just shape), per the "data first,
# intelligence later" decision: Down_Name/Down_ID (downstream connectivity → trace
# upstream/downstream), Hydrologic_Subregion/Subbasin (USGS WBD watershed locators),
# GNIS_ID + NHD_Permanent_Identifier (joins back to NHD for perennial/stream-order).
#
# Usage:  ./scripts/etl/pull_ca_streams.sh [outdir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-data/ca}"
BASE="https://services2.arcgis.com/Uq9r85Potqm3MfRV/arcgis/rest/services/CA_Streams_wm/FeatureServer/0/query"
FIELDS="Name,Down_Name,Down_ID,GNIS_ID,NHD_Permanent_Identifier,Hydrologic_Subregion,Hydrologic_Subbasin"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
UA="OreScout-ETL/0.1"
PAGE=2000

mkdir -p "$OUT"; rm -f "$OUT"/ca_streams_*.geojson
offset=0; i=0
while :; do
  f="$OUT/ca_streams_${i}.geojson"
  # orderByFields=OBJECTID keeps offset paging stable across requests.
  curl -s -A "$UA" "${BASE}?where=1%3D1&outFields=${FIELDS}&orderByFields=OBJECTID&outSR=4326&f=geojson&resultOffset=${offset}&resultRecordCount=${PAGE}" -o "$f"
  cnt=$(python3 -c "import json;print(len(json.load(open('$f')).get('features',[])))" 2>/dev/null || echo 0)
  if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
  offset=$((offset + PAGE)); i=$((i + 1))
  [ $((i % 25)) -eq 0 ] && echo "  …pulled $i pages ($((i * PAGE)) features)"
  [ "$cnt" -lt "$PAGE" ] && break
done
echo "pulled $i page(s)"

first=1
for f in "$OUT"/ca_streams_*.geojson; do
  if [ "$first" -eq 1 ]; then
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln staging.ca_streams -nlt PROMOTE_TO_MULTI \
      -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite && first=0
  else
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln staging.ca_streams -nlt PROMOTE_TO_MULTI -append 2>/dev/null
  fi
done
echo "loaded: $(docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c 'SELECT count(*) FROM staging.ca_streams;') rows into staging.ca_streams"
echo "next: psql -f scripts/etl/build_waterways.sql  (builds tiles.waterways)"
