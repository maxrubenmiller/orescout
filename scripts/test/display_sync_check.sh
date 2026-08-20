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
# Sample interior points of the z<=8 GREEN fill, ask the ENGINE's own query what it says there,
# and for any disagreement measure how much AREA the green piece actually shares with engine
# RED/YELLOW.
#
# Why area and not a point count: ST_PointOnSurface can land exactly on a shared boundary, where
# ST_Covers (boundary-inclusive, as the engine requires) reports the more restrictive verdict even
# though the green piece and the red/yellow polygon share essentially no area. Those are boundary
# ties, not green painted over closed land, and they err in the SAFE direction — the engine is more
# restrictive than the map. Fable's PP-23 is the same artifact class and was correctly refuted as
# an accepted residual.
#
# The threshold is the project's own 400 m² "meaningful parcel" floor (PROJECT_PLAN.md:2374). Any
# green piece sharing MORE than that with engine RED/YELLOW is a real affirmative false-open and
# fails. Measured before the PP-7 fix: green-over-RED clusters to 0.33 km² and green-over-YELLOW to
# 5.84 km². Measured after: worst single overlap 3 m², median 0.
OUT=$($PSQL -tAq -F'|' -c "
SET statement_timeout = 0;
WITH s AS (
  SELECT gid, geom, ST_PointOnSurface(geom) AS pt FROM tiles.legality_display_lowzoom
  WHERE verdict='GREEN' ORDER BY gid LIMIT ${N}
), scored AS (
  SELECT s.gid, s.geom,
         (SELECT l.verdict FROM tiles.legality_polygons l
          WHERE ST_Covers(l.geom, s.pt) ORDER BY orescout_rank(l.verdict) DESC LIMIT 1) AS v
  FROM s
), overlap AS (
  SELECT sc.gid,
         COALESCE((SELECT ST_Area(ST_Intersection(sc.geom, ST_Union(l.geom))::geography)
                   FROM tiles.legality_polygons l
                   WHERE l.verdict IN ('RED','YELLOW') AND ST_Intersects(l.geom, sc.geom)), 0) AS m2
  FROM scored sc WHERE sc.v IN ('RED','YELLOW')
)
SELECT (SELECT count(*) FROM s),
       (SELECT count(*) FROM scored WHERE v IN ('RED','YELLOW')),
       COALESCE((SELECT round(max(m2)) FROM overlap), 0),
       COALESCE((SELECT count(*) FROM overlap WHERE m2 > 400), 0);")
tot=$(echo "$OUT" | cut -d'|' -f1); dis=$(echo "$OUT" | cut -d'|' -f2)
maxm2=$(echo "$OUT" | cut -d'|' -f3); real=$(echo "$OUT" | cut -d'|' -f4)
echo "     sampled $tot low-zoom GREEN points; $dis disagree with the engine"
echo "     worst actual shared area: ${maxm2} m²; pieces over the 400 m² floor: ${real}"
[ "${real:-0}" -eq 0 ]
chk "no low-zoom GREEN piece shares >400 m² with engine RED/YELLOW" $?

echo
echo "display sync: $pass passed, $fail failed (of $((pass+fail)))"
[ "$fail" -eq 0 ]
