#!/usr/bin/env bash
# Nightly claims refresh (docs/planning/PROJECT_PLAN.md §6.6.2): pull all not-closed BLM MLRS mining
# claims for the 8 states into tiles.claims_polygons (full replace), served as vector
# tiles by pg_tileserv for the "Active mining claims" overlay.
#
# The MLRS layer is national with no state field, but CSE_NR is prefixed with the state
# code, so we filter per-state via CSE_NR LIKE 'XX%'. Native SR is 4269; we request
# outSR=4326. Only the lightweight fields are pulled (QLTY/CSE_META are verbose, skipped).
#
# This script is the pull + load + gates orchestration. The hardening contract (lock,
# row-count sanity gate, atomic swap, freshness registry stamp — originally inlined here
# per IMP-13) lives in refresh_lib.sh; this script keeps only the claims-specific parts:
#   - fail-fast paginated pull: any fetch/parse failure aborts the run non-zero with the
#     live table untouched; an ArcGIS {"error":...} body (returned with HTTP 200) is a
#     failure, and a short page only ends a state's paging when exceededTransferLimit is
#     not set (the offset advances by the actual feature count, so nothing is skipped).
#   - the load goes into tiles.claims_polygons_new; count_gate (±25%) + atomic_swap
#     replace the live table, so the overlay never goes empty mid-refresh and a bad
#     pull can't destroy good data.
#   - meta.claims_as_of and the public.data_sources registry are stamped only after a
#     successful swap.
#
# Usage:  ./scripts/etl/refresh_claims.sh [outdir] [STATE ...]
# Env overrides (testing): LAYER (ArcGIS query URL), CLAIMS_TABLE (table under tiles.,
# default claims_polygons; a non-default name also redirects the meta key and the
# data_sources key so test runs never touch claims_as_of / mlrs_claims).
set -euo pipefail

# shellcheck source=scripts/etl/refresh_lib.sh
source "$(cd "$(dirname "$0")" && pwd)/refresh_lib.sh"
source "$(cd "$(dirname "$0")" && pwd)/registry_lib.sh"   # state list from etl/sources.json (§6.13)

OUT="${1:-data/claims}"; shift || true
STATES=("$@"); [ ${#STATES[@]} -eq 0 ] && STATES=($(reg_states_space))   # default: all registry states
LAYER="${LAYER:-https://gis.blm.gov/nlsdb/rest/services/HUB/BLM_Natl_MLRS_Mining_Claims_Not_Closed/MapServer/0/query}"
FIELDS="CSE_NR,CSE_NAME,BLM_PROD,CSE_DISP,RCRD_ACRS,Modified"
PAGE=2000
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
TABLE="${CLAIMS_TABLE:-claims_polygons}"
CANON="tiles.${TABLE}"; NEW="tiles.${TABLE}_new"
if [ "$TABLE" = "claims_polygons" ]; then META_KEY="claims_as_of"; else META_KEY="${TABLE}_as_of"; fi

die() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

refresh_lock claims          # mkdir-based; auto-released on exit (see refresh_lib.sh)
trap 'exit 1' INT TERM

mkdir -p "$OUT"; rm -f "$OUT"/claims_*.geojson
echo "[$(date +%H:%M:%S)] pulling claims for ${STATES[*]}"
total=0
for ST in "${STATES[@]}"; do
  where=$(python3 -c "import urllib.parse;print(urllib.parse.quote(\"CSE_NR LIKE '${ST}%'\"))")
  offset=0; i=0; st_total=0
  while :; do
    f="$OUT/claims_${ST}_${i}.geojson"
    curl -sS --fail "${LAYER}?where=${where}&outFields=${FIELDS}&orderByFields=OBJECTID&outSR=4326&f=geojson&resultOffset=${offset}&resultRecordCount=${PAGE}" -o "$f" \
      || die "${ST} page ${i} (offset ${offset}): fetch failed; aborting run, ${CANON} untouched"
    # Empty page = done; invalid JSON, missing 'features', or an ArcGIS {"error":...}
    # body (served with HTTP 200) = abort. Prints "<count> <exceededTransferLimit 0|1>".
    page=$(python3 - "$f" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    sys.exit(f"invalid JSON: {e}")
if not isinstance(d, dict):
    sys.exit("response is not a JSON object")
if "error" in d:
    sys.exit(f"ArcGIS error: {json.dumps(d['error'])[:300]}")
if "features" not in d:
    sys.exit("response has no 'features' key")
exceeded = d.get("exceededTransferLimit") or (d.get("properties") or {}).get("exceededTransferLimit")
print(len(d["features"]), 1 if exceeded else 0)
PY
    ) || die "${ST} page ${i} (offset ${offset}): bad response (see $f); aborting run, ${CANON} untouched"
    read -r cnt exceeded <<<"$page"
    if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
    st_total=$((st_total + cnt)); offset=$((offset + cnt)); i=$((i + 1))
    # Short page = done for this state, unless the server hit its transfer limit
    # (exceededTransferLimit): then keep paging; offset advanced by the actual count.
    if [ "$cnt" -lt "$PAGE" ] && [ "$exceeded" -eq 0 ]; then break; fi
  done
  echo "[$(date +%H:%M:%S)]   ${ST}: ${st_total} claims (${i} pages)"
  total=$((total + st_total))
done
[ "$total" -gt 0 ] || die "pulled 0 claims; aborting run, ${CANON} untouched"
echo "[$(date +%H:%M:%S)] pulled ${total} claims; loading into ${NEW}"

# Load into a staging table; the live one is only replaced by the atomic swap below.
shopt -s nullglob
files=("$OUT"/claims_*.geojson)
shopt -u nullglob
[ ${#files[@]} -gt 0 ] || die "no GeoJSON files in $OUT to load"
first=1
for f in "${files[@]}"; do
  if [ "$first" -eq 1 ]; then
    # SPATIAL_INDEX=NONE: we create our own GIST index below; ogr2ogr's auto index
    # (<table>_geom_geom_idx) would keep its _new-based name across the swap and
    # collide with the next run's load.
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln "$NEW" -nlt PROMOTE_TO_MULTI \
      -lco GEOMETRY_NAME=geom -lco SPATIAL_INDEX=NONE -t_srs EPSG:4326 -overwrite \
      || die "ogr2ogr failed on $f"
    first=0
  else
    ogr2ogr -f PostgreSQL "$PG" "$f" -nln "$NEW" -nlt PROMOTE_TO_MULTI -append \
      || die "ogr2ogr failed on $f"
  fi
done

# Indexes + grant on the staging table (atomic_swap strips the '_new' infix, so these
# end up as <table>_geom_idx / <table>_disp_idx on the live table).
_rx "CREATE INDEX ${TABLE}_new_geom_idx ON ${NEW} USING GIST (geom);
     CREATE INDEX ${TABLE}_new_disp_idx ON ${NEW} (cse_disp);
     GRANT SELECT ON ${NEW} TO tileserv_ro;" || die "index/grant on ${NEW} failed"

# Gates + swap (refresh_lib.sh): refuse to swap if the new count is outside ±25% of the
# live one (guards an upstream outage blanking the overlay; skipped when no live table),
# then replace the live table in one transaction. Any failure exits non-zero with the
# live table untouched and ${NEW} left for inspection.
count_gate "${CANON}" 25
atomic_swap "${CANON}"

# Stamps: only reached after a successful swap. Test runs (non-default table) get their
# own meta + registry keys.
_rx "INSERT INTO public.meta (key, value) VALUES ('${META_KEY}', now()::text)
     ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();" \
  || die "meta stamp (${META_KEY}) failed"
stamp_source "mlrs_${META_KEY%_as_of}" claims \
  "BLM MLRS not-closed claims (as of $(date +%Y-%m-%d))" 2 "$LAYER" ok

echo "[$(date +%H:%M:%S)] done: $(_rq "SELECT count(*) FROM ${CANON}") rows live in ${CANON}"
