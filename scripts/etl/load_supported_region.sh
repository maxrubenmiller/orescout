#!/usr/bin/env bash
# Populate public.supported_region — the 8-state boundary for the Stage-0 in-region
# gate (PROJECT_PLAN.md §6.4). While this table is empty the gate is disabled
# (orescout_in_region returns true); once populated it enforces OUT_OF_REGION.
#
# Source: Census TIGERweb States (token-free), server-generalized. The same all-states
# fetch produces web/public/assets/us-states.geojson for the frontend out-of-scope mask.
#
# Usage:  ./scripts/etl/load_supported_region.sh
set -euo pipefail

TIG="https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/State_County/MapServer/0/query"
UA="Mozilla/5.0 OreScout-ETL"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
W8="STUSAB IN ('NV','CA','AZ','CO','UT','NM','OR','ID')"
mkdir -p data web/public/assets

# All states (generalized) -> committed frontend asset for the out-of-scope mask.
curl -s -A "$UA" "${TIG}?where=1%3D1&outFields=STUSAB,NAME&outSR=4326&maxAllowableOffset=0.01&f=geojson&resultRecordCount=60" \
  -o web/public/assets/us-states.geojson

# 8 supported states -> supported_region.
curl -s -A "$UA" "${TIG}?where=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(\"$W8\"))")&outFields=STUSAB,NAME&outSR=4326&maxAllowableOffset=0.01&f=geojson" \
  -o data/states8.geojson

ogr2ogr -f PostgreSQL "$PG" data/states8.geojson \
  -nln staging.us_states8 -nlt MULTIPOLYGON -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite

docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d miningapp -c "
INSERT INTO public.supported_region (state_code, geom)
SELECT stusab, ST_Multi(ST_CollectionExtract(ST_MakeValid(geom),3))
FROM staging.us_states8
ON CONFLICT (state_code) DO UPDATE SET geom = EXCLUDED.geom;
SELECT count(*) AS supported_states FROM public.supported_region;"
