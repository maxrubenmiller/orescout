#!/usr/bin/env bash
# Rebuild the derived display chain once: legality_lowzoom -> legality_display ->
# legality_display_lowzoom, then stamp the display generation.
#
# WHY THIS EXISTS. ORESCOUT_DEFER_DERIVED=1 (review finding PP-33) lets a batch of per-state
# confirm-open refreshes skip the derived rebuild so it is paid ONCE at the end instead of N times.
# The refresh script says "the CALLER must run it" — and refresh_due.sh does, inline. But a HUMAN
# caller running refreshes by hand had no command to run, which is exactly the state PP-36's data
# application left the database in: legality_polygons current, the map stale, display_sync_check
# failing, and no obvious way to finish other than a ~3.5 h full rebuild.
#
# Between the source swap and this script, tiles.legality_polygons is newer than the display tables:
# the map paints the previous rendering while /assessment answers from the new rows. That window is
# tolerated ONLY because PP-6's guard exists — the two generation stamps disagree, so
# display_sync_check.sh check A fails and says so out loud. Close the window promptly.
#
# Each table builds into _new, passes count_gate, and is atomically swapped (PP-31). Before that
# these were DROP-then-INSERT against the live serving tables, and when the GREEN clip hit a GEOS
# error on 2026-08-18 the DROP had committed and tiles.legality_lowzoom was left EMPTY.
#
# DUPLICATION, ACKNOWLEDGED: this same block also lives inline in rebuild_legality.sh,
# refresh_confirm_open.sh and refresh_due.sh — four copies of a gated swap sequence. They should be
# collapsed onto this script, but that touches three gated paths and rebuild_atomicity_test.sh
# asserts on their structure, so it is filed as follow-up work rather than done in passing.
#
# Usage:  ./scripts/etl/rebuild_derived_display.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/refresh_lib.sh

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
q() { docker compose exec -T postgres psql -U postgres -d miningapp -tAq -c "$1" | tr -d '[:space:]'; }

echo "=== derived display chain rebuild (PP-33 trailing batch) ==="
src=$(q "SELECT count(*) FROM tiles.legality_polygons")
echo "[derived] source tiles.legality_polygons: $src rows"
[ "${src:-0}" -gt 0 ] || { echo "✗ derived: source table is empty — refusing" >&2; exit 1; }

ok=1
echo "[derived] build_lowzoom.sql -> tiles.legality_lowzoom_new…"
"${PSQL[@]}" -v lowzoom_tbl=tiles.legality_lowzoom_new < scripts/etl/build_lowzoom.sql >/dev/null \
  && count_gate tiles.legality_lowzoom 40 && atomic_swap tiles.legality_lowzoom || ok=0

if [ "$ok" = "1" ]; then
  echo "[derived] build_legality_display.sql (normal) -> tiles.legality_display_new…"
  "${PSQL[@]}" -v src=tiles.legality_polygons -v tgt=tiles.legality_display_new \
    < scripts/etl/build_legality_display.sql >/dev/null \
    && count_gate tiles.legality_display 40 && atomic_swap tiles.legality_display || ok=0
fi

if [ "$ok" = "1" ]; then
  echo "[derived] build_legality_display.sql (low-zoom, cellsize 1.0) -> tiles.legality_display_lowzoom_new…"
  "${PSQL[@]}" -v src=tiles.legality_lowzoom -v tgt=tiles.legality_display_lowzoom_new -v cellsize=1.0 \
    < scripts/etl/build_legality_display.sql >/dev/null \
    && count_gate tiles.legality_display_lowzoom 40 && atomic_swap tiles.legality_display_lowzoom || ok=0
fi

if [ "$ok" != "1" ]; then
  echo "✗ derived display rebuild FAILED — legality_polygons is current but THE MAP IS STALE." >&2
  echo "  The generation stamps disagree; ./scripts/test/display_sync_check.sh will say so." >&2
  echo "  Live display tables were NOT modified by the failing step (build _new -> gate -> swap)." >&2
  exit 1
fi

# Derived tables now match the swapped-in source; record that (review finding PP-6).
stamp_display_generation

lz=$(q "SELECT count(*) FROM tiles.legality_lowzoom")
d=$(q  "SELECT count(*) FROM tiles.legality_display")
dlz=$(q "SELECT count(*) FROM tiles.legality_display_lowzoom")
echo "[derived] ✓ lowzoom=$lz · display=$d · display_lowzoom=$dlz — stamps now agree"
echo "[derived]   verify with: ./scripts/test/display_sync_check.sh"
