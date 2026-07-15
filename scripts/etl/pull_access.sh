#!/usr/bin/env bash
# Ingest the ACCESS & TRAILS federal backbone (4 sources) into staging for the reference-only
# access overlay (PROJECT_PLAN §5.4 / §6.13 `reference` role; FABLE_MVUM_BRIEF.md;
# DATA_SOURCE_INVESTIGATION_MVUM_TRAILS.md). Display-only: serves tiles.access and NEVER feeds
# the verdict engine (a road/trail is not a legality input) — upholds the §6.13 invariant.
#
# Sources (all read from etl/sources.json `access.sources` — no hardcoded URLs here):
#   - USFS MVUM Roads / MVUM Trails / NFS Trails: FSGeodata Clearinghouse File-GDB `download`s.
#     Zip filenames are resolved from the landing page at ETL time (they have been versioned per
#     refresh in the past); the resolved URLs are recorded in data/access/resolved_urls.txt.
#     Loaded with an 8-state envelope filter (-spat); build_access.sql clips precisely.
#     If a zip fails integrity (the NFS Trails GDB zip served on 2026-07-14 was reproducibly
#     corrupt upstream), the per-source `rest_fallback` endpoint is harvested instead (paged,
#     envelope-filtered, the registry `fields` list).
#   - BLM GTLF: paged `arcgis_rest` harvest of the Natl GTLF *Public Display* MapServer, all 8
#     pre-classified layers, filtered server-side to the 8 states via ADMIN_ST. (The raw
#     BLM_Natl_GTLF/MapServer/0 the research doc pointed at now exposes only ~10k features
#     national — the Public Display service carries the real ~170k network. No public bulk-GDB
#     item exists on the BLM GBP hub as of 2026-07-14, so REST is the harvest path, pagination
#     mandatory at maxRecordCount=2000.) Each feature is tagged with its display-layer id
#     (`gtlf_layer`) — the layer IS part of the classification signal.
#
# License: US-government work, public domain. USFS metadata use-constraint verified 2026-07-14:
# no access constraint ("accconst: None"); no-warranty + "not legal documents" disclaimer only.
#
# Usage:  ./scripts/etl/pull_access.sh [source_id ...]     # default: all four
#         next: ./scripts/etl/build_access.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

OUT="data/access"; mkdir -p "$OUT"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
UA="OreScout-ETL/0.1"
# 8-state envelope (same as pull_mrds.sh); build_access.sql clips precisely to supported_region.
SPAT=(-124.85 31.3 -102.0 49.05)
BBOX="-124.85,31.3,-102.0,49.05"
MANIFEST="$OUT/resolved_urls.txt"
ONLY=("$@")

psqlc() { docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c "$1"; }
want() { [ ${#ONLY[@]} -eq 0 ] || printf '%s\n' "${ONLY[@]}" | grep -qx "$1"; }

# page_rest <staging> <base-layer-url> <fields> <page> <tag_layer (-1 = none)>
# The caller sets FILTER_ARGS to the query's filter params (a where clause or an envelope).
# Paged GeoJSON harvest -> $OUT/rest_<staging-basename>_l<tag>_p<N>.geojson (caller loads them).
page_rest() {
  local staging="$1" base="$2" fields="$3" page="$4" tag="$5"
  local name; name=$(basename "${staging/./_}")_l${tag}
  local offset=0 p=0 f cnt attempt
  while :; do
    f="$OUT/rest_${name}_p${p}.geojson"
    # Per-page retry loop on top of curl's own --retry: the EDW/BLM ArcGIS servers 5xx/504
    # sporadically under deep resultOffset paging — one flaky page must not kill a 30-min harvest.
    attempt=0
    until curl -qsf --retry 3 --retry-delay 2 -A "$UA" --max-time 180 -G "$base/query" \
      --data-urlencode "outFields=$fields" \
      --data-urlencode "orderByFields=OBJECTID" \
      --data-urlencode "outSR=4326" \
      --data-urlencode "f=geojson" \
      --data-urlencode "resultOffset=$offset" \
      --data-urlencode "resultRecordCount=$page" \
      "${FILTER_ARGS[@]}" -o "$f"; do
      attempt=$((attempt + 1))
      [ "$attempt" -ge 5 ] && { echo "  !! page offset=$offset failed 5x — aborting" >&2; return 1; }
      echo "  .. page offset=$offset failed (attempt $attempt), backing off"; sleep $((attempt * 10))
    done
    cnt=$(python3 - "$f" "$tag" <<'PY'
import json, sys
path, tag = sys.argv[1], int(sys.argv[2])
d = json.load(open(path))
if "error" in d:  # ArcGIS reports query errors as HTTP-200 JSON — must not read as "0 features"
    print(f"ARCGIS ERROR: {d['error']}", file=sys.stderr)
    sys.exit(3)
feats = d.get("features", [])
if tag >= 0:
    for ft in feats:
        ft.setdefault("properties", {})["gtlf_layer"] = tag
    json.dump(d, open(path, "w"))
print(len(feats))
PY
) || { echo "  !! page offset=$offset returned an ArcGIS error body — aborting" >&2; return 1; }
    if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
    offset=$((offset + page)); p=$((p + 1))
    [ "$cnt" -lt "$page" ] && break
  done
  echo "  paged $p page(s) from $base"
}

# load_geojson_pages <staging> <glob>
load_geojson_pages() {
  local staging="$1" first=1 f
  for f in $2; do
    if [ "$first" -eq 1 ]; then
      ogr2ogr -f PostgreSQL "$PG" "$f" -nln "$staging" -overwrite -nlt PROMOTE_TO_MULTI \
        -dim XY -t_srs EPSG:4326 -lco GEOMETRY_NAME=geom -lco FID=ogc_fid && first=0
    else
      ogr2ogr -f PostgreSQL "$PG" "$f" -nln "$staging" -append -nlt PROMOTE_TO_MULTI -dim XY
    fi
  done
}

zip_ok() { python3 - "$1" <<'PY'
import sys, zipfile
try:
    bad = zipfile.ZipFile(sys.argv[1]).testzip()
except Exception:
    sys.exit(1)
sys.exit(1 if bad else 0)
PY
}

LANDING=$(reg_access access url)
LANDING_HTML="$OUT/landing.html"
curl -qsf --retry 3 --retry-delay 2 -A "$UA" --max-time 120 "$LANDING" -o "$LANDING_HTML"

n_sources=$(reg_raw '.sources[] | select(.key=="access") | .access.sources | length')
for i in $(seq 0 $((n_sources - 1))); do
  src() { reg_raw ".sources[] | select(.key==\"access\") | .access.sources[$i].$1"; }
  id=$(src id); kind=$(src kind); staging=$(src staging)
  want "$id" || continue
  echo "=== [$id] ($kind) -> $staging ==="

  if [ "$kind" = "download" ]; then
    zip_match=$(src zip_match); layer_match=$(src layer_match)
    # Resolve the actual zip href from the landing page at ETL time (filenames are versioned
    # per refresh on FSGeodata; do not hardcode).
    href=$(grep -oE "href=\"edw_resources/fc/${zip_match}\"" "$LANDING_HTML" | head -1 | sed 's/^href="//; s/"$//')
    [ -n "$href" ] || { echo "  !! $id: no zip matching '$zip_match' on $LANDING — aborting" >&2; exit 1; }
    url="https://data.fs.usda.gov/geodata/edw/${href}"

    zip="$OUT/$(basename "$url")"
    if [ ! -f "$zip" ] || ! zip_ok "$zip"; then                   # (re)download if missing/bad
      echo "  downloading $(basename "$url") …"
      curl -qsf --retry 3 --retry-delay 2 -A "$UA" "$url" -o "$zip"
    fi

    if zip_ok "$zip"; then
      echo "$id $url" >> "$MANIFEST"
      gdbdir=$(unzip -Z1 "$zip" | awk -F/ '$1 ~ /\.gdb$/ {g=$1} END{print g}')
      unzip -qo "$zip" -d "$OUT"
      # ogrinfo -q lines look like "Layer: Trans_MVUM_Road (Multi Line String)"
      layer=$(ogrinfo -q "$OUT/$gdbdir" | grep -i "$layer_match" | head -1 | sed 's/^Layer: //; s/ .*//')
      [ -n "$layer" ] || { echo "  !! $id: no layer matching '$layer_match' in $gdbdir" >&2; exit 1; }
      # All attribute columns are kept (the per-vehicle-class flags ARE the classification
      # signal); -spat trims the national extent to the 8-state envelope at read time. The EDW
      # GDBs contain true-curve geometries (MultiCurve) — CONVERT_TO_LINEAR densifies them.
      ogr2ogr -f PostgreSQL "$PG" "$OUT/$gdbdir" "$layer" \
        -nln "$staging" -overwrite -nlt CONVERT_TO_LINEAR -nlt PROMOTE_TO_MULTI -dim XY \
        -t_srs EPSG:4326 -spat "${SPAT[@]}" -lco GEOMETRY_NAME=geom -lco FID=ogc_fid
      rm -rf "${OUT:?}/${gdbdir:?}"                               # stream: keep the zip, drop the unzip
      echo "  [$id] layer=$layer -> staged (8-state envelope): $(psqlc "SELECT count(*) FROM $staging")"
    else
      rest=$(src rest_fallback // empty)
      [ -n "$rest" ] && [ "$rest" != "null" ] || { echo "  !! $id: zip integrity failed and no rest_fallback" >&2; exit 1; }
      echo "  !! $id: zip failed integrity twice (upstream corruption) — falling back to paged REST"
      echo "$id $rest (REST fallback; zip corrupt upstream)" >> "$MANIFEST"
      fields=$(reg_raw ".sources[] | select(.key==\"access\") | .access.sources[$i].fields | join(\",\")")
      page=$(src page)
      rm -f "$OUT"/rest_$(basename "${staging/./_}")_l-1_p*.geojson
      FILTER_ARGS=(--data-urlencode "geometry=$BBOX" --data-urlencode "geometryType=esriGeometryEnvelope"
                   --data-urlencode "inSR=4326" --data-urlencode "spatialRel=esriSpatialRelIntersects")
      page_rest "$staging" "$rest" "$fields" "$page" -1
      load_geojson_pages "$staging" "$OUT/rest_$(basename "${staging/./_}")_l-1_p*.geojson"
      echo "  [$id] staged via REST: $(psqlc "SELECT count(*) FROM $staging")"
    fi

  elif [ "$kind" = "arcgis_rest" ]; then
    base=$(src url); page=$(src page)
    fields=$(reg_raw ".sources[] | select(.key==\"access\") | .access.sources[$i].fields | join(\",\")")
    where="ADMIN_ST IN ($(reg_states_sqlcsv))"
    echo "$id $base (where: $where)" >> "$MANIFEST"
    rm -f "$OUT"/rest_$(basename "${staging/./_}")_l*_p*.geojson

    FILTER_ARGS=(--data-urlencode "where=$where")
    for lyr in $(reg_raw ".sources[] | select(.key==\"access\") | .access.sources[$i].layers[]"); do
      # Not every display layer carries every field (layers 6/7 have no GlobalID) and ArcGIS
      # answers an unknown outField with an HTTP-200 error body — intersect the requested list
      # with the layer's actual schema first.
      lyr_fields=$(curl -qsf --retry 3 -A "$UA" --max-time 60 "$base/$lyr?f=json" \
        | python3 -c "
import sys, json
have = {f['name'].lower() for f in json.load(sys.stdin).get('fields', [])}
want = sys.argv[1].split(',')
print(','.join(f for f in want if f.lower() in have))
" "$fields")
      [ -n "$lyr_fields" ] || { echo "  !! layer $lyr: no requested fields exist — aborting" >&2; exit 1; }
      [ "$lyr_fields" != "$fields" ] && echo "  [gtlf layer $lyr] fields trimmed to: $lyr_fields"
      page_rest "$staging" "$base/$lyr" "$lyr_fields" "$page" "$lyr"
    done
    load_geojson_pages "$staging" "$OUT/rest_$(basename "${staging/./_}")_l*_p*.geojson"
    echo "  [$id] staged: $(psqlc "SELECT count(*) FROM $staging")"
  fi
done

echo "done. resolved URLs -> $MANIFEST"
echo "next: ./scripts/etl/build_access.sh   (build + gate + stamp tiles.access)"
