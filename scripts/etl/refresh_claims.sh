#!/usr/bin/env bash
# Nightly claims refresh (PROJECT_PLAN.md §6.6.2): pull all not-closed BLM MLRS mining
# claims for the 8 states into tiles.claims_polygons (full replace), served as vector
# tiles by pg_tileserv for the "Active mining claims" overlay.
#
# The MLRS layer is national with no state field, but CSE_NR is prefixed with the state
# code, so we filter per-state via CSE_NR LIKE 'XX%'. Native SR is 4269; we request
# outSR=4326. Only the lightweight fields are pulled (QLTY/CSE_META are verbose, skipped).
#
# Hardened per README "Future: schedule the nightly claims refresh" (IMP-13):
#   - any fetch/parse/load failure aborts the whole run with a non-zero exit;
#     an ArcGIS {"error":...} body (returned with HTTP 200) is treated as a failure,
#     and a short page only ends a state's paging when exceededTransferLimit is not set
#     (the offset advances by the actual feature count, so nothing is skipped).
#   - the load goes into tiles.claims_polygons_new; the live table is only replaced by
#     an atomic rename swap after a row-count sanity gate (new within ±25% of old), so
#     the overlay never goes empty mid-refresh and a bad pull can't destroy good data.
#   - meta.claims_as_of is updated only after a successful swap.
#   - a mkdir-based lock (flock is not available on macOS) prevents overlapping runs.
#
# Usage:  ./scripts/etl/refresh_claims.sh [outdir] [STATE ...]
# Env overrides (testing): LAYER (ArcGIS query URL), CLAIMS_TABLE (table under tiles.,
# default claims_polygons; a non-default name also redirects the meta key so test runs
# never touch claims_as_of).
set -euo pipefail

OUT="${1:-data/claims}"; shift || true
STATES=("$@"); [ ${#STATES[@]} -eq 0 ] && STATES=(NV CA AZ CO UT NM OR ID)
LAYER="${LAYER:-https://gis.blm.gov/nlsdb/rest/services/HUB/BLM_Natl_MLRS_Mining_Claims_Not_Closed/MapServer/0/query}"
FIELDS="CSE_NR,CSE_NAME,BLM_PROD,CSE_DISP,RCRD_ACRS,Modified"
PAGE=2000
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
TABLE="${CLAIMS_TABLE:-claims_polygons}"
CANON="tiles.${TABLE}"; NEW="tiles.${TABLE}_new"
if [ "$TABLE" = "claims_polygons" ]; then META_KEY="claims_as_of"; else META_KEY="${TABLE}_as_of"; fi

die() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }
PSQL() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d miningapp "$@"; }

# Concurrency guard: mkdir is atomic and portable (no flock on macOS).
LOCK="${TMPDIR:-/tmp}/refresh_claims.lock"
mkdir "$LOCK" 2>/dev/null || die "another refresh appears to be running (lock: $LOCK); remove it if stale"
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT
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

# Indexes + grant on the staging table (renamed to their final names in the swap).
PSQL -q <<SQL || die "index/grant on ${NEW} failed"
CREATE INDEX ${TABLE}_new_geom_idx ON ${NEW} USING GIST (geom);
CREATE INDEX ${TABLE}_new_disp_idx ON ${NEW} (cse_disp);
GRANT SELECT ON ${NEW} TO tileserv_ro;
SQL

# Sanity gate: refuse to swap if the new count is outside ±25% of the live one —
# guards against an upstream outage returning a near-empty set and blanking the overlay.
new_cnt=$(PSQL -tAq -c "SELECT count(*) FROM ${NEW};") || die "count of ${NEW} failed"
[ "$new_cnt" -gt 0 ] || die "0 rows loaded into ${NEW}; keeping ${CANON}"
old_exists=$(PSQL -tAq -c "SELECT to_regclass('${CANON}') IS NOT NULL;") || die "existence check of ${CANON} failed"
old_cnt=0
[ "$old_exists" = "t" ] && { old_cnt=$(PSQL -tAq -c "SELECT count(*) FROM ${CANON};") || die "count of ${CANON} failed"; }
if [ "$old_cnt" -eq 0 ]; then
  echo "[$(date +%H:%M:%S)] sanity gate skipped: ${CANON} missing or empty (new=${new_cnt})"
else
  lo=$((old_cnt * 75 / 100)); hi=$((old_cnt * 125 / 100))
  if [ "$new_cnt" -lt "$lo" ] || [ "$new_cnt" -gt "$hi" ]; then
    die "sanity gate: new count ${new_cnt} outside ±25% of live ${old_cnt} (allowed ${lo}..${hi}); keeping ${CANON}, leaving ${NEW} for inspection"
  fi
  echo "[$(date +%H:%M:%S)] sanity gate OK: new=${new_cnt} vs live=${old_cnt}"
fi

# Atomic swap (README pattern): the overlay never sees an empty/partial table, and the
# as-of stamp is only written after the swap has committed.
PSQL -q <<SQL || die "swap failed; ${CANON} needs inspection (staging: ${NEW})"
BEGIN;
DROP TABLE IF EXISTS tiles.${TABLE}_old;
ALTER TABLE IF EXISTS ${CANON} RENAME TO ${TABLE}_old;
ALTER INDEX IF EXISTS tiles.${TABLE}_geom_idx RENAME TO ${TABLE}_old_geom_idx;
ALTER INDEX IF EXISTS tiles.${TABLE}_disp_idx RENAME TO ${TABLE}_old_disp_idx;
ALTER TABLE ${NEW} RENAME TO ${TABLE};
ALTER INDEX tiles.${TABLE}_new_geom_idx RENAME TO ${TABLE}_geom_idx;
ALTER INDEX tiles.${TABLE}_new_disp_idx RENAME TO ${TABLE}_disp_idx;
COMMIT;
DROP TABLE IF EXISTS tiles.${TABLE}_old;
INSERT INTO public.meta (key, value) VALUES ('${META_KEY}', now()::text)
  ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();
SQL
echo "[$(date +%H:%M:%S)] done: $(PSQL -tAq -c "SELECT count(*) FROM ${CANON};") rows live in ${CANON}"
