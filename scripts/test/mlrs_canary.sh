#!/usr/bin/env bash
# Sentinel canary for the BLM MLRS "Not Closed" claims layer. MlrsClaimsService treats 0 features
# as a legitimate "no claims here" answer, so if BLM moves/renames the layer (or changes the field
# schema) the API silently returns 200-with-empty-claims forever and assessments never escalate.
# This script fires the SAME query shape the service sends (ClaimsService.cs) at a coordinate
# KNOWN to be claim-dense — Round Mountain, NV (38.7127, -117.0722; 23 active claims verified
# 2026-06) — and exits non-zero with a loud message if it gets 0 features, an ArcGIS error
# payload, or no response. Run manually or from cron; intentionally NOT an API endpoint.
#
# Usage:  ./scripts/test/mlrs_canary.sh [query_url]
#         query_url defaults to Mlrs:QueryUrl from src/OreScout.Api/appsettings.json.
set -uo pipefail
cd "$(dirname "$0")/../.."

LAT=38.7127
LNG=-117.0722
BUFFER=100
URL="${1:-$(python3 -c 'import json; print(json.load(open("src/OreScout.Api/appsettings.json"))["Mlrs"]["QueryUrl"])')}"

echo "MLRS canary → ${URL}"
echo "sentinel: Round Mountain NV (${LAT}, ${LNG}), ${BUFFER}m buffer"

# Mirror of the query MlrsClaimsService builds (same params, same outFields).
RESP=$(curl -s --max-time 20 -A "OreScout/0.1" -G "$URL" \
  --data-urlencode "geometry={\"x\":${LNG},\"y\":${LAT},\"spatialReference\":{\"wkid\":4326}}" \
  --data-urlencode "geometryType=esriGeometryPoint" \
  --data-urlencode "inSR=4326" \
  --data-urlencode "outSR=4326" \
  --data-urlencode "distance=${BUFFER}" \
  --data-urlencode "units=esriSRUnit_Meter" \
  --data-urlencode "spatialRel=esriSpatialRelIntersects" \
  --data-urlencode "outFields=CSE_NR,CSE_NAME,BLM_PROD,CSE_DISP,RCRD_ACRS,Modified" \
  --data-urlencode "returnGeometry=false" \
  --data-urlencode "f=json") || RESP=""

VERDICT=$(printf '%s' "$RESP" | python3 -c '
import json, sys
raw = sys.stdin.read()
try:
    d = json.loads(raw)
except Exception:
    print("unparseable"); sys.exit()
if "error" in d:
    err = d["error"]
    print("arcgis_error", err.get("code"), err.get("message"))
else:
    print("features", len(d.get("features", [])))
')

case "$VERDICT" in
  features\ 0)
    echo "✗ CANARY FAILED: 0 features at the claim-dense sentinel — the MLRS layer has likely"
    echo "  moved/renamed. The API is now silently reporting NO CLAIMS EVERYWHERE. Fix Mlrs:QueryUrl."
    exit 1 ;;
  features\ *)
    echo "✓ canary passed: ${VERDICT#features } active claims at sentinel (layer + query shape healthy)"
    exit 0 ;;
  arcgis_error*)
    echo "✗ CANARY FAILED: MLRS returned an error payload (${VERDICT#arcgis_error }) — query shape or"
    echo "  layer is broken. Note the service already surfaces this as a dataGap, but investigate."
    exit 1 ;;
  *)
    echo "✗ CANARY FAILED: no/unparseable response from MLRS (network down, endpoint gone, or HTML error page)."
    exit 1 ;;
esac
