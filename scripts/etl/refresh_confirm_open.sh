#!/usr/bin/env bash
# Class-2 refresh job: re-pull a confirm-open ownership source and rebuild its YELLOW rows
# (docs/DATA_REFRESH_PLAN.md §3; PROJECT_PLAN §6.4.1/§6.13). One wrapper, both sources:
#
#   ./scripts/etl/refresh_confirm_open.sh ut      # Utah SGID/SITLA (upstream revises weekly)
#   ./scripts/etl/refresh_confirm_open.sh ca      # CA CAL FIRE (upstream ~annual)
#
# Sequence + gates (any failure exits non-zero; the live layer keeps its previous rows):
#   lock -> pull to staging -> schema assertion -> confirm_open_<st>.sql in ONE TRANSACTION
#   (psql -1: readers keep the old YELLOW rows until commit — no window where the confirm-open
#   layer is missing, the F-4 failure mode) -> row-count band vs previous -> Tier-A fixtures ->
#   Tier-B goldens (needs the API up; includes the confirm-open golden points) -> registry stamp.
#
# NOT wired into refresh_due auto-runs for legality-adjacent safety? It IS Class-2 (auto): the
# same scripts, newer data, gated by the fixture suites — the design's normal operation. The
# zero-false-GREEN private validation is a PAD-US-class (Class-3) gate, run on base-layer bumps.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/refresh_lib.sh

ST="${1:-}"
API="${2:-http://localhost:5167/api/v1}"
case "$ST" in
  ut) SRC_KEY="ugrc_ut";    STAGING="staging.ugrc_ownership";    SCHEMA_COLS="owner geom";
      PULL="./scripts/etl/pull_ugrc.sh";    SQL="scripts/etl/confirm_open_ut.sql"
      VINTAGE="Utah SGID/SITLA land ownership (weekly upstream revisions; CC-BY 4.0)"
      REF="https://gis.trustlands.utah.gov/server/rest/services/Ownership/UT_SITLA_Ownership_LandOwnership_WM/FeatureServer/0"
      MAXAGE=180 ;;
  ca) SRC_KEY="calfire_ca"; STAGING="staging.calfire_ownership"; SCHEMA_COLS="own_level geom";
      PULL="./scripts/etl/pull_calfire.sh"; SQL="scripts/etl/confirm_open_ca.sql"
      VINTAGE="CAL FIRE land ownership (CC-BY)"
      REF="CAL FIRE Public_Land_Ownership_view FeatureServer"
      MAXAGE=420 ;;
  nv|az|co|nm|or|id)
      # Six SMA-based states (TODO Track 2): shared pull adapter + generated confirm-open SQL.
      case "$ST" in
        nv) SRC_KEY="blmsma_nv"; VINTAGE="BLM NV SMA";  REF="BLM-EGIS hosted Surface_Management_Agency_SMA"; MAXAGE=540 ;;
        az) SRC_KEY="blmsma_az"; VINTAGE="BLM AZ SMA (ALRIS lineage)"; REF="gis.blm.gov/azarcgis BLM_AZ_SMA"; MAXAGE=540 ;;
        co) SRC_KEY="blmsma_co"; VINTAGE="BLM CO SMA (daily upstream)"; REF="gis.blm.gov/coarcgis SMA layer 1"; MAXAGE=365 ;;
        nm) SRC_KEY="blmsma_nm"; VINTAGE="BLM NM SMA"; REF="gis.blm.gov/nmarcgis Lands SMA"; MAXAGE=365 ;;
        or) SRC_KEY="odf_or";    VINTAGE="Oregon Land Ownership (ODF)"; REF="ODF Ownership_Land_Management"; MAXAGE=365 ;;
        id) SRC_KEY="idl_id";    VINTAGE="Idaho SMA (IDL)"; REF="gis1.idl.idaho.gov Idaho_Surface_Management_Agency"; MAXAGE=365 ;;
      esac
      STAGING="staging.sma_${ST}"; SCHEMA_COLS="geom"
      PULL="./scripts/etl/pull_sma.sh ${ST}"; SQL="scripts/etl/confirm_open_${ST}.sql"
      [ -f "$SQL" ] || { echo "✗ $SQL missing — run ./scripts/etl/gen_confirm_open.sh ${ST} first" >&2; exit 2; } ;;
  *) echo "usage: $0 <ut|ca|nv|az|co|nm|or|id> [api_base_url]" >&2; exit 2 ;;
esac

refresh_lock "confirm_open_${ST}"

echo "[confirm-open ${ST}] previous row count…"
before=$(_rq "SELECT count(*) FROM tiles.legality_polygons WHERE source_key='${SRC_KEY}'")
echo "[confirm-open ${ST}] live ${SRC_KEY} rows before: $before"

echo "[confirm-open ${ST}] pulling upstream -> ${STAGING}…"
$PULL

# shellcheck disable=SC2086  # word-splitting SCHEMA_COLS is intended
assert_schema "$STAGING" $SCHEMA_COLS

echo "[confirm-open ${ST}] rebuilding rows (single transaction — old rows serve until commit)…"
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -1 -q" < "$SQL"

after=$(_rq "SELECT count(*) FROM tiles.legality_polygons WHERE source_key='${SRC_KEY}'")
[ "$after" -gt 0 ] || rfail "confirm-open ${ST}: rebuild produced 0 rows"
if [ "$before" -gt 0 ]; then
  lo=$(( before * 60 / 100 )); hi=$(( before * 140 / 100 ))
  if [ "$after" -lt "$lo" ] || [ "$after" -gt "$hi" ]; then
    rfail "confirm-open ${ST}: row count $after outside ±40% of previous $before — investigate before trusting (rows ARE live; rerun the previous data via git-pinned staging if needed)"
  fi
fi
echo "[confirm-open ${ST}] rows: $before -> $after"

echo "[confirm-open ${ST}] fixture gates…"
./scripts/run-fixtures.sh
curl -sqf -o /dev/null --max-time 5 "$API/health" \
  || rfail "API not reachable at $API — start it and run ./scripts/run-tier-b.sh to finish the gate"
./scripts/run-tier-b.sh "$API"

stamp_source "$SRC_KEY" confirm_open "$VINTAGE (refreshed $(date +%Y-%m-%d))" "$MAXAGE" "$REF" ok
echo "[confirm-open ${ST}] ✓ refreshed, gated, stamped"
