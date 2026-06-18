#!/usr/bin/env bash
# NV validation-slice pull (PROJECT_PLAN.md §6.6.1 / §6.6.1.1).
# Pages the live, Phase-0-verified PAD-US FeatureServer for Nevada into GeoJSON.
#
# This slice validates the unify pipeline + classifier literals against real data fast,
# without the multi-GB v4 .gdb download. The production / 8-state run uses the v4 download
# (which is also where Own_Type etc. get re-confirmed). Source here is PAD-US v3.0 (live layer).
#
# Usage:  ./scripts/etl/pull_nv_padus.sh [outdir]
set -euo pipefail

OUT="${1:-data/nv}"
LAYER="https://services.arcgis.com/v01gqwM5QqNysAAi/arcgis/rest/services/Manager_Name/FeatureServer/0/query"
FIELDS="Own_Type,Own_Name,Mang_Name,Mang_Type,Des_Tp,Unit_Nm,State_Nm,GAP_Sts,Pub_Access"
PAGE=1000
WHERE=$(python3 -c "import urllib.parse;print(urllib.parse.quote(\"State_Nm='NV'\"))")

mkdir -p "$OUT"
rm -f "$OUT"/padus_*.geojson

offset=0; i=0
while :; do
  f="$OUT/padus_${i}.geojson"
  curl -s "${LAYER}?where=${WHERE}&outFields=${FIELDS}&outSR=4326&f=geojson&resultOffset=${offset}&resultRecordCount=${PAGE}" -o "$f"
  cnt=$(python3 -c "import json;print(len(json.load(open('$f')).get('features',[])))")
  echo "page $i (offset $offset) -> $cnt features"
  if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
  offset=$((offset + PAGE)); i=$((i + 1))
  [ "$cnt" -lt "$PAGE" ] && break
done
echo "done: $i page file(s) in $OUT"
