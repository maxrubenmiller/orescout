#!/usr/bin/env bash
# OUTPUT-PROPERTY GATE: no engine-GREEN point may sit on ground an authoritative source maps
# as not-public. (PROJECT_PLAN §6.4.1 "GREEN must be earned"; review findings PP-1/2/3/5/18.)
#
# WHY THIS EXISTS
# Every committed harness tests INPUTS (registry transcription, schema, row-count bands) or a
# fixed set of golden POINTS. None tests the property the app actually promises. That is how
# Round 1 of the pre-production audit constructed live false-GREENs in 7 of 8 states while every
# gate stayed green. This gate asserts the property directly, so it catches a false-GREEN
# regardless of which mechanism produced it — sliver filter, NULL predicate, buffer width, a
# wrong public code, or something nobody has thought of yet.
#
# METHOD
#   not-public ground := rows of the state's authoritative ownership layer where the registry's
#                        public_predicate IS NOT TRUE  (note: NOT TRUE, so NULL/unknown counts
#                        as not-public — a NULL attribute must never confirm open)
#                        plus, when GATE_PARCELS=1, assessor parcels with owner_class='private'
#   sample           := ST_PointOnSurface of every such polygon (guaranteed interior), plus,
#                        when GATE_DENSITY=1, seeded area-scaled interior points for big ones
#   score            := the engine's own Stage-1 query — ST_Covers + ORDER BY orescout_rank DESC
#                        against tiles.legality_polygons
#   FAIL             := any sampled point on a source polygon >= 400 m² scores GREEN
#
# Both counts are printed. Only the >=400 m² one gates, because the carve deliberately does not
# rescue sub-400 m² fragments — that is its documented design (PROJECT_PLAN.md:2374, "validation
# frame floor 400 m², recorded not hidden"), not a leak. Failing on them would hold the gate to a
# standard the pipeline never claimed. The distinction is not cosmetic: measured in CO, 337 raw
# residuals collapse to exactly 1 real parcel once the floor is applied (median sliver: 6 m²).
#
# HONEST LIMITS — read before treating a pass as proof:
#   * Default sampling is ONE interior point per not-public polygon. It bounds nothing about
#     the interior of a large polygon; it is a detector, not a proof of absence. GATE_DENSITY=1
#     samples harder and is much slower.
#   * CA became coverable once PP-2 narrowed its public predicate to own_level='Federal' — before
#     that the predicate was `own_level IS NOT NULL`, so CAL FIRE had no not-public rows at all and
#     this gate reported CA NOT-COVERABLE. It is still the weakest state: CAL FIRE maps public
#     ownership only, so genuinely private land is absent rather than labelled, and no sampling of
#     this layer can find it. See PP-3.
#   * A false-GREEN on a sub-400 m² source polygon is still recorded and printed — it is just not
#     a gate failure. If those counts climb sharply, something changed.
#   * A polygon absent from every legality layer scores '(none)' -> the engine returns
#     YELLOW/UNKNOWN there. Safe, and counted separately, but it means the not-public signal is
#     "no data" rather than positive mapping.
#   * Assessor parcels are OFF by default (GATE_PARCELS=1 to include). CO/NM/UT hold 1.44M
#     private parcels between them and sweeping all of them takes hours, which is the wrong
#     shape for a gate. That surface already has dedicated harnesses — run_tier1_validation.sh
#     (stratified sample + Clopper-Pearson bound) and check_validation_fixtures.sh (213
#     goldens). What has NO harness, and what this gate is for, is the SMA/state-ownership
#     layer that the confirm-open carve is built from.
#
# Usage:  ./scripts/validation/gate_notpublic_green.sh [state ...]     (default: all)
#         GATE_DENSITY=1 ./scripts/validation/gate_notpublic_green.sh nv
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

PSQL="docker compose exec -T postgres psql -U postgres -d miningapp"
DENSITY="${GATE_DENSITY:-0}"
SEED=42   # fixed: the gate must give the same answer twice
# Parcels off by default — see HONEST LIMITS above. 'false' short-circuits the UNION branch.
if [ "${GATE_PARCELS:-0}" = "1" ]; then PARCELS_ON="true"; else PARCELS_ON="false"; fi

if [ "$#" -gt 0 ]; then STATES="$*"; else STATES=$(reg_states_for_role confirm_open | tr '\n' ' '); fi

total_green=0; total_real=0; total_pts=0; failed_states=""; uncoverable=""

for st in $STATES; do
  STU=$(echo "$st" | tr '[:lower:]' '[:upper:]')
  STL=$(echo "$st" | tr '[:upper:]' '[:lower:]')
  KEY=$(reg_key_for_state_role "$STU" confirm_open) || { echo "  ?? $STU: no confirm_open source"; continue; }
  STAGING=$(reg_confirm "$KEY" staging)
  PUB=$(reg_confirm "$KEY" public_predicate)
  # carve_private is null for the SMA-template sources and for CA; absence is information, not an error.
  CARVE=$(reg_confirm "$KEY" carve_private 2>/dev/null || echo "(none)")

  # A source with no affirmative not-public geometry cannot be swept. Say so; never pass silently.
  notpub_n=$(eval "$PSQL -tAq -c \"SELECT count(*) FROM $STAGING WHERE ($PUB) IS NOT TRUE\"" 2>/dev/null | tr -d '[:space:]')
  if [ -z "$notpub_n" ]; then echo "  ?? $STU: could not read $STAGING"; continue; fi
  if [ "$notpub_n" -eq 0 ]; then
    echo "  -- $STU  NOT-COVERABLE: $STAGING has no rows where the public predicate is not true"
    echo "        (public-only source; carve_private=$CARVE) — see review finding PP-3"
    uncoverable="$uncoverable $STU"
    continue
  fi

  extra="0"
  [ "$DENSITY" = "1" ] && extra="LEAST(GREATEST((ST_Area(g.geom::geography)/500000)::int,0),8)"

  # ONE sweep per state: score into a scratch table, then read both the summary and the worst
  # offenders out of it. Scoring is the expensive part (a correlated ST_Covers per point over a
  # 171k-row table) — doing it twice, once for counts and once for the listing, doubled runtime.
  SCRATCH="tiles.__gate_${STL}"
  GATESQL="
SET client_min_messages TO WARNING;
DROP TABLE IF EXISTS ${SCRATCH};
CREATE TABLE ${SCRATCH} AS
WITH notpub AS (
  SELECT ST_MakeValid(geom) AS geom FROM $STAGING WHERE ($PUB) IS NOT TRUE
  UNION ALL
  SELECT ST_MakeValid(geom) FROM staging.parcels
   WHERE ${PARCELS_ON} AND to_regclass('staging.parcels') IS NOT NULL
     AND state='$STU' AND owner_class='private'
), g AS (
  SELECT geom FROM notpub WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom) AND ST_Dimension(geom)=2
), sampled AS (
  SELECT ST_PointOnSurface(g.geom) AS pt, ST_Area(g.geom::geography) AS src_m2 FROM g
  UNION ALL
  SELECT (ST_Dump(ST_GeneratePoints(g.geom, ${extra}, ${SEED}))).geom, ST_Area(g.geom::geography)
    FROM g WHERE ${extra} > 0
)
SELECT s.pt, s.src_m2,
       (SELECT l.verdict FROM tiles.legality_polygons l
        WHERE ST_Covers(l.geom, s.pt) ORDER BY orescout_rank(l.verdict) DESC LIMIT 1) AS v
FROM sampled s;
-- Last field decides pass/fail: false-GREENs on source polygons at or above the documented
-- 400 m2 meaningful-parcel floor (PROJECT_PLAN.md:2374). Sub-floor fragments are counted and
-- printed but never gate: the carve documents that it does not rescue them. NOTE: no double
-- quotes in this string - it lives inside a double-quoted bash assignment and they terminate it.
SELECT 'SUMMARY|' || count(*) || '|' || count(*) FILTER (WHERE v='GREEN') || '|' ||
       count(*) FILTER (WHERE v='RED') || '|' || count(*) FILTER (WHERE v='YELLOW') || '|' ||
       count(*) FILTER (WHERE v IS NULL) || '|' ||
       count(*) FILTER (WHERE v='GREEN' AND src_m2 >= 400) FROM ${SCRATCH};
SELECT 'OFFENDER|        lat=' || round(ST_Y(pt)::numeric,7) || ' lng=' || round(ST_X(pt)::numeric,7)
       || '  (not-public polygon ' || round(src_m2)::text || ' m2)'
FROM ${SCRATCH} WHERE v='GREEN' ORDER BY src_m2 DESC LIMIT 5;
DROP TABLE IF EXISTS ${SCRATCH};
"
  OUT=$(printf '%s' "$GATESQL" | eval "$PSQL -tAq -F'|'")

  summary=$(printf '%s\n' "$OUT" | grep '^SUMMARY|' | head -1)
  pts=$(echo "$summary"  | cut -d'|' -f2); green=$(echo "$summary" | cut -d'|' -f3)
  red=$(echo "$summary"  | cut -d'|' -f4); yellow=$(echo "$summary" | cut -d'|' -f5)
  none=$(echo "$summary" | cut -d'|' -f6); real=$(echo "$summary" | cut -d'|' -f7)
  pts=${pts:-0}; green=${green:-0}; real=${real:-0}
  total_pts=$((total_pts + pts)); total_green=$((total_green + green)); total_real=$((total_real + real))

  # A gate that measured NOTHING must never report clean. This is not hypothetical: a stray pair of
  # double quotes in the SQL comment above once terminated the GATESQL bash string early, so every
  # state returned no SUMMARY row and the gate cheerfully printed "0 of 0 sampled - clean" for all
  # eight. Silence and success have to be distinguishable, especially in a safety gate.
  if [ "$pts" -eq 0 ]; then
    echo "  ✗ $STU  BROKEN: the sweep returned no rows (expected ~${notpub_n} not-public polygons)."
    echo "        This is a gate failure, NOT a pass — something went wrong before any point was scored."
    failed_states="$failed_states $STU(broken)"
    continue
  fi

  if [ "$real" -gt 0 ]; then
    echo "  ✗ $STU  FALSE-GREEN: $real on parcels >=400 m2 ($green raw) of $pts sampled  (RED $red / YELLOW $yellow / no-polygon $none)"
    failed_states="$failed_states $STU"
    printf '%s\n' "$OUT" | grep '^OFFENDER|' | cut -d'|' -f2-
  else
    echo "  ✓ $STU  clean: 0 above the 400 m2 floor ($green raw sub-floor slivers) of $pts sampled  (RED $red / YELLOW $yellow / no-polygon $none)"
  fi
done

echo
echo "not-public/GREEN gate: $total_real false-GREEN on parcels >=400 m2 ($total_green raw, incl. sub-floor slivers) of $total_pts sampled (density=$DENSITY, seed=$SEED)"
[ -n "$uncoverable" ] && echo "  NOT-COVERABLE (no authoritative not-public layer):$uncoverable"
[ -n "$failed_states" ] && { echo "  FAILING STATES:$failed_states"; exit 1; }
[ -z "$uncoverable" ] || echo "  (a clean run does NOT cover the states listed above)"
exit 0
