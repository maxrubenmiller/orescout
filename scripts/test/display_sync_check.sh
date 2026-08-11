#!/usr/bin/env bash
# Display-vs-engine sync gate (review findings PP-6 and PP-7).
#
# PP-6: tiles.legality_lowzoom and both display tables are DERIVED from tiles.legality_polygons,
# but nothing recorded which generation of the source they were built from — no vintage column, no
# public.meta entry, no public.data_sources row. refresh_confirm_open.sh rebuilt only the source,
# so the map drifted from the verdict silently, and refresh_due.sh re-created that drift on every
# cadence. Observed before the fix: tiles.legality_display_lowzoom said GREEN where /assessment and
# the z>=9 display both said YELLOW, over a 243 km2 blmsma_nm polygon.
#
# PP-7: separately from staleness, build_lowzoom.sql dropped every RED/YELLOW polygon <= 0.2 km2
# before the display partition was computed, so GREEN painted across the dropped ground. That is
# now fixed by clipping GREEN against the full-resolution red/yellow union; check B here is the
# regression that keeps it fixed, and it is a REAL sample of the served data, not a stamp.
#
# Usage:  ./scripts/test/display_sync_check.sh [sample_n]
set -uo pipefail
cd "$(dirname "$0")/.."

PSQL="docker compose exec -T postgres psql -U postgres -d miningapp"
N="${1:-2000}"
pass=0; fail=0
chk() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "  ✓ $1"; else fail=$((fail+1)); echo "  ✗ $1"; fi; }

echo "== A. generation stamps agree (PP-6) =="
STAMPS=$($PSQL -tAq -F'|' -c "
  SELECT COALESCE((SELECT value FROM public.meta WHERE key='legality_generation'), '(unset)'),
         COALESCE((SELECT value FROM public.meta WHERE key='legality_display_generation'), '(unset)');")
SRC="${STAMPS%%|*}"; DSP="${STAMPS##*|}"
echo "     source=$SRC  derived=$DSP"
if [ "$SRC" = "(unset)" ] && [ "$DSP" = "(unset)" ]; then
  echo "  ! both stamps unset — this DB predates the generation stamp. Run rebuild_legality.sh"
  echo "    (or refresh_confirm_open.sh) once to establish it; treating as NOT a failure."
else
  [ "$SRC" = "$DSP" ]
  chk "legality_generation == legality_display_generation" $?
fi

echo "== B. served low-zoom GREEN does not cover engine RED/YELLOW (PP-7) =="
# Sample interior points of the z<=8 GREEN fill and ask the ENGINE's own query what it says there.
# Any GREEN-over-RED/YELLOW is an affirmative false-open statement on the map.
OUT=$($PSQL -tAq -F'|' -c "
WITH s AS (
  SELECT ST_PointOnSurface(geom) AS pt FROM tiles.legality_display_lowzoom
  WHERE verdict='GREEN' ORDER BY gid LIMIT ${N}
), scored AS (
  SELECT (SELECT l.verdict FROM tiles.legality_polygons l
          WHERE ST_Covers(l.geom, s.pt) ORDER BY orescout_rank(l.verdict) DESC LIMIT 1) AS v
  FROM s
)
SELECT count(*), count(*) FILTER (WHERE v='RED'), count(*) FILTER (WHERE v='YELLOW') FROM scored;")
tot="${OUT%%|*}"; rest="${OUT#*|}"; red="${rest%%|*}"; yel="${rest##*|}"
echo "     sampled $tot low-zoom GREEN points -> engine RED=$red YELLOW=$yel"
[ "${red:-0}" -eq 0 ] && [ "${yel:-0}" -eq 0 ]
chk "no sampled low-zoom GREEN point resolves to engine RED/YELLOW" $?

echo
echo "display sync: $pass passed, $fail failed (of $((pass+fail)))"
[ "$fail" -eq 0 ]
