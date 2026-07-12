#!/usr/bin/env bash
# Ingest a state's surface-management/ownership layer into staging for the confirm-open
# cross-check (PROJECT_PLAN §6.4.1/§6.13; TODO Track 2 — expansion beyond CA/UT).
# Sources verified live 2026-07-11 (research report in DATA_SOURCE_INVESTIGATION.md):
# every layer is detailed (14k–270k polys) and carries AFFIRMATIVE Private — the Utah-style
# buffer-carve works in all six states.
#
#   ./scripts/etl/pull_sma.sh <nv|az|co|nm|or|id>   ->  staging.sma_<st>
#
# Five states ride BLM's identical {st}arcgis platform; OR uses the ODF framework layer and
# ID the IDL portal — same query API. All public domain / public state data (credit lines in
# the registry stamp). SR normalized to 4326 by ogr2ogr.
set -euo pipefail
cd "$(dirname "$0")/../.."
ST="${1:-}"
OUT="data/sma/${ST}"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
UA="OreScout-ETL/0.1"

die() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }
PSQL() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d miningapp "$@"; }

case "$ST" in
  # BLM NV hosted detailed snapshot (14,637 rows; Apr-2023 vintage — ownership churn is slow and
  # the live dissolved twin is impractical to page; re-check cadence via check_upstream).
  nv) URL="https://services1.arcgis.com/KbxwQRRfWyEYLgp4/arcgis/rest/services/Surface_Management_Agency_SMA/FeatureServer/0/query"
      FIELDS="ABBR,NAME"; PAGE=2000 ;;
  az) URL="https://gis.blm.gov/azarcgis/rest/services/lands/BLM_AZ_SMA/FeatureServer/0/query"
      FIELDS="CATEGORY"; PAGE=2000 ;;
  co) URL="https://gis.blm.gov/coarcgis/rest/services/lands/BLM_Colorado_Surface_Management_Agency/FeatureServer/1/query"
      FIELDS="adm_code,adm_manage"; PAGE=2000 ;;
  nm) URL="https://gis.blm.gov/nmarcgis/rest/services/Lands/BLM_NM_Lands_Surface_Management_Agency/FeatureServer/0/query"
      FIELDS="own"; PAGE=2000 ;;
  or) URL="https://services.arcgis.com/uUvqNMGPm7axC2dD/arcgis/rest/services/Ownership_Land_Management/FeatureServer/0/query"
      FIELDS="LandManager"; PAGE=2000 ;;
  id) URL="https://gis1.idl.idaho.gov/arcgis/rest/services/Portal/Idaho_Surface_Management_Agency/FeatureServer/0/query"
      FIELDS="MGMT_AGNCY,AGNCY_NAME"; PAGE=2000 ;;
  *) echo "usage: $0 <nv|az|co|nm|or|id>" >&2; exit 2 ;;
esac

OID=$(curl -sq -A "$UA" --max-time 30 "${URL%/query}?f=json" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("objectIdField") or "OBJECTID")')
echo "[sma ${ST}] paging by ${OID}…"

mkdir -p "$OUT"; rm -f "$OUT"/sma_*.geojson
offset=0; i=0
while :; do
  f="$OUT/sma_${i}.geojson"
  curl -sq -A "$UA" --max-time 180 -G "$URL" \
    --data-urlencode "where=1=1" \
    --data-urlencode "outFields=${FIELDS}" \
    --data-urlencode "orderByFields=${OID}" \
    --data-urlencode "outSR=4326" \
    --data-urlencode "f=geojson" \
    --data-urlencode "resultOffset=${offset}" \
    --data-urlencode "resultRecordCount=${PAGE}" -o "$f" || die "page $i: fetch failed"
  cnt=$(python3 -c "
import json,sys
try:
  d=json.load(open('$f'))
  assert 'error' not in d, d.get('error')
  print(len(d.get('features',[])))
except AssertionError as e: print('ERR', e); sys.exit(1)
except Exception: print('ERR bad json'); sys.exit(1)") || die "page $i: bad response (see $f)"
  if [ "$cnt" = "0" ]; then rm -f "$f"; break; fi
  offset=$((offset + cnt)); i=$((i + 1))
  [ $((i % 10)) -eq 0 ] && echo "  …${offset} features"
  [ "$cnt" -lt "$PAGE" ] && break
done
echo "[sma ${ST}] pulled ${offset} features (${i} pages)"
[ "$offset" -gt 1000 ] || die "suspiciously few features (${offset}) — expected a detailed layer (14k+); check the endpoint"

first=1
for f in "$OUT"/sma_*.geojson; do
  if [ "$first" -eq 1 ]; then
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln "staging.sma_${ST}" -nlt PROMOTE_TO_MULTI \
      -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite && first=0 || die "ogr2ogr overwrite failed"
  else
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln "staging.sma_${ST}" -nlt PROMOTE_TO_MULTI -append || die "ogr2ogr append failed"
  fi
done
PSQL -q -c "CREATE INDEX IF NOT EXISTS sma_${ST}_geom_idx ON staging.sma_${ST} USING GIST (geom);"
echo "[sma ${ST}] loaded: $(PSQL -tAq -c "SELECT count(*) FROM staging.sma_${ST};") rows into staging.sma_${ST}"
echo "next: ./scripts/etl/gen_confirm_open.sh ${ST}  (writes confirm_open_${ST}.sql), then run it via rebuild or refresh_confirm_open.sh"
