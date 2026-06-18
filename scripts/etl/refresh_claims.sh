#!/usr/bin/env bash
# Nightly claims refresh (PROJECT_PLAN.md §6.6.2): pull all not-closed BLM MLRS mining
# claims for the 8 states into tiles.claims_polygons (full replace), served as vector
# tiles by pg_tileserv for the "Active mining claims" overlay.
#
# The MLRS layer is national with no state field, but CSE_NR is prefixed with the state
# code, so we filter per-state via CSE_NR LIKE 'XX%'. Native SR is 4269; we request
# outSR=4326. Only the lightweight fields are pulled (QLTY/CSE_META are verbose, skipped).
#
# Usage:  ./scripts/etl/refresh_claims.sh [outdir] [STATE ...]
set -euo pipefail

OUT="${1:-data/claims}"; shift || true
STATES=("$@"); [ ${#STATES[@]} -eq 0 ] && STATES=(NV CA AZ CO UT NM OR ID)
LAYER="https://gis.blm.gov/nlsdb/rest/services/HUB/BLM_Natl_MLRS_Mining_Claims_Not_Closed/MapServer/0/query"
FIELDS="CSE_NR,CSE_NAME,BLM_PROD,CSE_DISP,RCRD_ACRS,Modified"
PAGE=2000
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"

mkdir -p "$OUT"; rm -f "$OUT"/claims_*.geojson
echo "[$(date +%H:%M:%S)] pulling claims for ${STATES[*]}"
total=0
for ST in "${STATES[@]}"; do
  where=$(python3 -c "import urllib.parse;print(urllib.parse.quote(\"CSE_NR LIKE '${ST}%'\"))")
  offset=0; i=0; st_total=0
  while :; do
    f="$OUT/claims_${ST}_${i}.geojson"
    curl -s "${LAYER}?where=${where}&outFields=${FIELDS}&orderByFields=OBJECTID&outSR=4326&f=geojson&resultOffset=${offset}&resultRecordCount=${PAGE}" -o "$f"
    cnt=$(python3 -c "import json;print(len(json.load(open('$f')).get('features',[])))" 2>/dev/null || echo 0)
    if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
    st_total=$((st_total + cnt)); offset=$((offset + PAGE)); i=$((i + 1))
    [ "$cnt" -lt "$PAGE" ] && break
  done
  echo "[$(date +%H:%M:%S)]   ${ST}: ${st_total} claims (${i} pages)"
  total=$((total + st_total))
done
echo "[$(date +%H:%M:%S)] pulled ${total} claims; loading to tiles.claims_polygons"

# Full replace.
docker compose exec -T postgres psql -q -U postgres -d miningapp -c "DROP TABLE IF EXISTS tiles.claims_polygons;"
first=1
for f in "$OUT"/claims_*.geojson; do
  if [ "$first" -eq 1 ]; then
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln tiles.claims_polygons -nlt PROMOTE_TO_MULTI \
      -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite && first=0
  else
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln tiles.claims_polygons -nlt PROMOTE_TO_MULTI -append 2>/dev/null
  fi
done

docker compose exec -T postgres psql -q -U postgres -d miningapp <<'SQL'
CREATE INDEX IF NOT EXISTS claims_geom_idx ON tiles.claims_polygons USING GIST (geom);
CREATE INDEX IF NOT EXISTS claims_disp_idx ON tiles.claims_polygons (cse_disp);
GRANT SELECT ON tiles.claims_polygons TO tileserv_ro;
INSERT INTO public.meta (key, value) VALUES ('claims_as_of', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
SQL
echo "[$(date +%H:%M:%S)] done: $(docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c 'SELECT count(*) FROM tiles.claims_polygons;') rows"
