#!/usr/bin/env bash
# Tile-budget check for the Tier-B prospecting overlay (docs/briefs/TIER_B_FABLE_BRIEF.md "Risks": a dense
# point layer must not recreate the legality layer's low-zoom tile timeouts, F-3).
# Fetches a concurrent viewport of tiles at the layer's minzoom band (z7 = where High appears)
# plus a z10 tile (Moderate band): all must be HTTP 200 and <= 500 KB.
#
# Usage:  ./scripts/test/tiles_prospectivity.sh [tile_base_url]
set -uo pipefail
BASE="${1:-http://localhost:7800}"
TILES=(7/21/48 7/22/48 7/21/49 7/22/49 7/20/48 7/23/49)   # Sierra/NV gold country band
MAX_BYTES=512000

pass=0; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "fetching ${#TILES[@]} z7 prospectivity tiles concurrently…"
for t in "${TILES[@]}"; do
  ( curl -sq -o /dev/null -w "%{http_code} %{size_download} %{time_total}" \
      "$BASE/tiles.prospectivity/$t.pbf" > "$tmp/${t//\//_}.meta" ) &
done
wait

for t in "${TILES[@]}"; do
  read -r code bytes secs < "$tmp/${t//\//_}.meta"
  ok=1; why=""
  [ "$code" = "200" ] || { ok=0; why+="http=$code "; }
  [ "${bytes:-0}" -le "$MAX_BYTES" ] || { ok=0; why+="size=${bytes}B>${MAX_BYTES} "; }
  if [ $ok -eq 1 ]; then pass=$((pass+1)); echo "  ✓ z$t  ${bytes}B  ${secs}s";
  else fail=$((fail+1)); echo "  ✗ z$t  $why"; fi
done

read -r code bytes secs < <(curl -sq -o /dev/null -w "%{http_code} %{size_download} %{time_total}" \
  "$BASE/tiles.prospectivity/10/172/391.pbf")
if [ "$code" = "200" ] && [ "${bytes:-0}" -le "$MAX_BYTES" ]; then
  pass=$((pass+1)); echo "  ✓ z10 (Moderate band)  ${bytes}B  ${secs}s"
else
  fail=$((fail+1)); echo "  ✗ z10 (Moderate band)  http=$code size=${bytes}B"
fi

echo; echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
