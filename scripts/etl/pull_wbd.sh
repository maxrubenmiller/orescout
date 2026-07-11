#!/usr/bin/env bash
# Ingest USGS WBD watershed polygons (HUC12 + HUC10) for the Tier-B prospecting composite
# (TIER_B_FABLE_BRIEF.md; PROJECT_PLAN §5.3, decision #42). REFERENCE-ONLY pipeline (§6.13).
#
# Source: the NATIONAL WBD FileGDB snapshot (public domain, ~2.6 GB) from The National Map
# staged products. The national file deliberately sidesteps the HU2-region-list risk the brief
# flags (eastern CO/NM drain to region 11 — a regional download list could miss units); the
# 8-state filter happens at load on the `states` attribute, and build_prospectivity.sql ASSERTS
# every in-region sample joins a HUC12 (the completeness check).
#
# Snapshot discipline (brief): HUC codes are NOT stable across WBD snapshots — record the
# download date in public.meta ('wbd_snapshot') and never treat codes as cross-version keys.
#
# STATED BOUND: keeps HUC12/HUC10 rows whose `states` attribute mentions any of the 8 states
# (the attribute lists every state a HUC touches, so border units are kept).
#
# Usage:  ./scripts/etl/pull_wbd.sh [datadir]
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="${1:-data/wbd}"
ZIP="WBD_National_GDB.zip"
URL="https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/WBD/National/GDB/${ZIP}"
GDB="$OUT/WBD_National_GDB.gdb"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
LIKE="states LIKE '%NV%' OR states LIKE '%CA%' OR states LIKE '%AZ%' OR states LIKE '%CO%' OR states LIKE '%UT%' OR states LIKE '%NM%' OR states LIKE '%OR%' OR states LIKE '%ID%'"

mkdir -p "$OUT"
if [ ! -d "$GDB" ]; then
  echo "downloading national WBD GDB (~2.6 GB)…"
  curl -sq -L --max-time 3600 -o "$OUT/$ZIP" "$URL"
  ( cd "$OUT" && unzip -o -q "$ZIP" )
fi
[ -d "$GDB" ] || { echo "✗ $GDB missing after download/unzip" >&2; exit 1; }

for HU in 12 10; do
  echo "loading WBDHU${HU} (8-state) -> staging.wbd_huc${HU}…"
  ogr2ogr -f PostgreSQL "$PG" "$GDB" "WBDHU${HU}" \
    -nln "staging.wbd_huc${HU}" -overwrite \
    -where "$LIKE" \
    -t_srs EPSG:4326 -nlt PROMOTE_TO_MULTI -lco GEOMETRY_NAME=geom \
    -select "huc${HU},name,areasqkm,states"
done

echo "indexing + snapshot stamp…"
docker compose exec -T postgres psql -q -v ON_ERROR_STOP=1 -U postgres -d miningapp <<SQL
CREATE INDEX IF NOT EXISTS wbd_huc12_geom_idx ON staging.wbd_huc12 USING GIST (geom);
CREATE INDEX IF NOT EXISTS wbd_huc10_geom_idx ON staging.wbd_huc10 USING GIST (geom);
CREATE INDEX IF NOT EXISTS wbd_huc12_code_idx ON staging.wbd_huc12 (huc12);
CREATE INDEX IF NOT EXISTS wbd_huc10_code_idx ON staging.wbd_huc10 (huc10);
INSERT INTO public.meta (key, value) VALUES ('wbd_snapshot', 'WBD_National_GDB downloaded ' || now()::date)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
SQL

docker compose exec -T postgres psql -U postgres -d miningapp -At <<'SQL'
SELECT 'staging.wbd_huc12 (8-state): ' || count(*) FROM staging.wbd_huc12;
SELECT 'staging.wbd_huc10 (8-state): ' || count(*) FROM staging.wbd_huc10;
SQL
echo "next: docker compose exec -T postgres psql -U postgres -d miningapp < scripts/etl/build_prospectivity.sql"
