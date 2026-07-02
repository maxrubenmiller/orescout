#!/usr/bin/env bash
# Regression check for IMP-07 (review finding F-3): low-zoom legality tiles must survive a
# normal concurrent viewport fetch — no 5xx, sane sizes, sane latency.
#
# Before: 6 concurrent z6 fetches of tiles.legality_polygons -> pg_tileserv "context deadline
# exceeded" -> HTTP 500 (RED/YELLOW land silently blank at state zooms); single z5 tile 3.3 MB.
# After: the same viewport served from generalized tiles.legality_lowzoom must return 6x 200,
# each tile < 500 KB. Also asserts one detail (z9) tile still serves.
#
# Usage:  ./scripts/test/tiles_lowzoom.sh [tile_base_url]   (default http://localhost:7800)
set -uo pipefail
BASE="${1:-http://localhost:7800}"
TILES=(6/10/23 6/11/23 6/10/24 6/11/24 6/10/25 6/11/25)   # NV/CA/UT band — the diag.mjs viewport
MAX_BYTES=512000

pass=0; fail=0
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

echo "fetching ${#TILES[@]} z6 lowzoom tiles concurrently…"
for t in "${TILES[@]}"; do
  ( curl -sq -o "$tmp/${t//\//_}.pbf" -w "%{http_code} %{size_download} %{time_total}" \
      "$BASE/tiles.legality_lowzoom/$t.pbf" > "$tmp/${t//\//_}.meta" ) &
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

# detail layer still serves at/above the split
code=$(curl -sq -o /dev/null -w "%{http_code}" "$BASE/tiles.legality_polygons/9/86/196.pbf")
if [ "$code" = "200" ]; then pass=$((pass+1)); echo "  ✓ detail z9 tile 200";
else fail=$((fail+1)); echo "  ✗ detail z9 tile http=$code"; fi

echo; echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
