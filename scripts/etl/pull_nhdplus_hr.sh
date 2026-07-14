#!/usr/bin/env bash
# Ingest USGS NHDPlus HR flowlines (per-HU4, STREAMED) into staging for the reference-only
# waterways overlay (PROJECT_PLAN §6.13 `reference` role; docs/WATERWAYS_NHDPLUS_HR_PLAN.md).
# Replaces the California-only CDFW `ca_streams` source with all-8-state NHDPlus HR.
#
# Dev strategy (machine-friendly): per-HU4 VPU/Current File GDBs, streamed —
#   resolve S3 key -> download -> unzip -> ogr2ogr extract (FType=460 streams + FCode=55800 artificial
#   paths = the centerline through wide double-banked rivers / lakes) -> append to staging
#   -> DELETE the unzipped GDB (keep the small zip for re-runs). Peak disk ~1-2 GB.
# Vertex order (= downstream flow direction) is preserved; Z/M dropped (-dim XY) — chevrons need
# order, not measures. Resolved S3 keys are recorded for reproducibility.
# PRODUCTION upgrades to the National NR2 wide ingest — see the plan doc's "Production upgrade".
#
# Usage:  ./scripts/etl/pull_nhdplus_hr.sh <HU4> [HU4 ...]
#   e.g.  ./scripts/etl/pull_nhdplus_hr.sh 1806            # single-HU4 trial
set -euo pipefail
cd "$(dirname "$0")/../.."

OUT="data/nhdplus"; mkdir -p "$OUT"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
S3="https://prd-tnm.s3.amazonaws.com"
PREFIX="StagedProducts/Hydrography/NHDPlusHR/VPU/Current/GDB"
UA="OreScout-ETL/0.1"
STAGING="staging.nhdplus_hr_flowlines"
MANIFEST="$OUT/resolved_keys.txt"

# HU4s: explicit args, or (when run with none — e.g. run.sh's reference dispatch) the registry's
# access.hu4_list for this source, so extending coverage = editing the registry, not this script (§6.13).
if [ "$#" -eq 0 ]; then
  source "$(cd "$(dirname "$0")" && pwd)/registry_lib.sh"
  set -- $(reg_raw '.sources[] | select(.key=="nhdplus_hr_waterways") | .access.hu4_list[]')
fi
[ "$#" -ge 1 ] || { echo "usage: $0 <HU4> [HU4 ...]  (or define access.hu4_list for nhdplus_hr_waterways)"; exit 1; }
: > "$MANIFEST"   # fresh manifest per full run

psqlc() { docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c "$1"; }

i=0
for hu4 in "$@"; do
  # VPU/Current names are a dated/undated mix -> resolve the actual .zip key by prefix list.
  key=$(curl -s "${S3}/?list-type=2&prefix=${PREFIX}/NHDPLUS_H_${hu4}_HU4" \
    | python3 -c "import sys,re; ks=[k for k in re.findall(r'<Key>([^<]+)</Key>', sys.stdin.read()) if k.endswith('.zip')]; print(ks[0] if ks else '')")
  if [ -z "$key" ]; then echo "  !! HU4 $hu4: no GDB zip found — skipping"; continue; fi
  echo "$key" >> "$MANIFEST"

  zip="$OUT/$(basename "$key")"
  if [ ! -f "$zip" ] || ! unzip -tqq "$zip" >/dev/null 2>&1; then   # (re)download if missing/partial
    curl -sf --retry 3 --retry-delay 2 -A "$UA" "${S3}/${key}" -o "$zip" \
      || { echo "  !! HU4 $hu4: download failed — skipping"; rm -f "$zip"; continue; }
  fi
  # Read the full listing (no early pipe close -> no SIGPIPE under pipefail); take the .gdb dir.
  gdbdir=$(unzip -Z1 "$zip" | awk -F/ '$1 ~ /\.gdb$/ {g=$1} END{print g}')
  unzip -qo "$zip" -d "$OUT"

  mode="-append"; [ "$i" -eq 0 ] && mode="-overwrite"            # first HU4 of the run rebuilds staging
  # Use -sql (not -where/-select): ogr2ogr rejects -select under -append; -sql works for both modes.
  ogr2ogr -f PostgreSQL "$PG" "$OUT/$gdbdir" \
    -sql "SELECT Permanent_Identifier, GNIS_Name, FCode, FType, FlowDir, ReachCode FROM NHDFlowline WHERE FType = 460 OR FCode = 55800" \
    -nln "$STAGING" $mode -nlt PROMOTE_TO_MULTI -dim XY -t_srs EPSG:4326 \
    -lco GEOMETRY_NAME=geom -lco FID=ogc_fid

  rm -rf "$OUT/$gdbdir"                                          # stream: drop the big unzipped GDB
  i=$((i + 1))
  echo "  [$hu4] $(basename "$key") -> staging total: $(psqlc "SELECT count(*) FROM $STAGING")"
done

echo "done: $i HU4(s) loaded into $STAGING. Next: psql -f scripts/etl/build_waterways.sql"
