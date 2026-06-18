#!/usr/bin/env bash
# Pull PAD-US for the supported states from the live, Phase-0-verified FeatureServer,
# per-state and paginated, into GeoJSON (PROJECT_PLAN.md §6.6.1).
#
# Source here is the live PAD-US v3.0 layer (fast, all required fields incl. Own_Type).
# Data-currency upgrade to PAD-US 4.2 (ScienceBase item 65294599d34e44db0e2ed7cf, "PAD-US
# 4.2 State Downloads") is a documented follow-up — see TODO.md.
#
# Usage:  ./scripts/etl/pull_states_padus.sh [outdir] [STATE ...]
set -euo pipefail

OUT="${1:-data/8state}"; shift || true
STATES=("$@"); [ ${#STATES[@]} -eq 0 ] && STATES=(NV CA AZ CO UT NM OR ID)
LAYER="https://services.arcgis.com/v01gqwM5QqNysAAi/arcgis/rest/services/Manager_Name/FeatureServer/0/query"
FIELDS="Own_Type,Own_Name,Mang_Name,Mang_Type,Des_Tp,Unit_Nm,State_Nm,GAP_Sts,Pub_Access"
PAGE=1000

mkdir -p "$OUT"; rm -f "$OUT"/padus_*.geojson
total=0
for ST in "${STATES[@]}"; do
  where=$(python3 -c "import urllib.parse;print(urllib.parse.quote(\"State_Nm='${ST}'\"))")
  offset=0; i=0; st_total=0
  while :; do
    f="$OUT/padus_${ST}_${i}.geojson"
    curl -s "${LAYER}?where=${where}&outFields=${FIELDS}&outSR=4326&f=geojson&resultOffset=${offset}&resultRecordCount=${PAGE}" -o "$f"
    cnt=$(python3 -c "import json;print(len(json.load(open('$f')).get('features',[])))")
    if [ "$cnt" -eq 0 ]; then rm -f "$f"; break; fi
    st_total=$((st_total + cnt)); offset=$((offset + PAGE)); i=$((i + 1))
    [ "$cnt" -lt "$PAGE" ] && break
  done
  echo "  ${ST}: ${st_total} features (${i} page file(s))"
  total=$((total + st_total))
done
echo "TOTAL: ${total} features across ${#STATES[@]} states in $OUT"
