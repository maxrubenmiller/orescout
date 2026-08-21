#!/usr/bin/env bash
# PP-35 diagnostic: for each remaining above-floor false-GREEN, how much ground is ACTUALLY served
# as GREEN, and why did the carve not demote it?
#
# READ THIS BEFORE ADDING A METRIC. Two plausible measures were used here first and both produced
# confident, badly wrong answers:
#
#   1. distance to the nearest mapped PUBLIC parcel — intended to show "inside the 100 m forgiveness
#      band, therefore correct by design". It shows no such thing. The ID residual is 0 m from public
#      land and provably NOT in conf_buf_id. Proximity does not imply forgiveness.
#
#   2. parcel MINUS union(YELLOW,RED), calling the remainder GREEN. False. Ground covered by NO
#      legality polygon at all is also not YELLOW/RED, and it is not GREEN either — the engine has no
#      baked verdict there. This reported 666,877 m2 for a residual whose true exposure is 367 m2, a
#      1,800x overstatement, because only 947 m2 of that 667,003 m2 parcel is covered by any GREEN
#      polygon at all.
#
# The honest metric, and the one below:
#      true_green = (parcel INTERSECT union(GREEN)) MINUS union(YELLOW, RED)
# i.e. the area where the most-restrictive covering verdict really is GREEN.
#
# Columns:
#   parcel_m2    area of the not-public source polygon, region-clipped (all >= the 400 m2 floor).
#   green_m2     how much of it any GREEN polygon covers. Far below parcel_m2 means the parcel is
#                mostly UNCOVERED, not mostly open — a coverage gap, not a false-GREEN.
#   TRUE_GREEN   the actual exposure. This is the number to act on.
#   covering     state_nm of the GREEN polygon at the sample point. Not this state => cross-border
#                residue the PP-30 sweep did not reach.
#
# Measured 2026-08-20: 34,643 m2 total across 11 residuals — 90.5% California (the documented
# CAL-FIRE-has-no-private-layer hole), the rest the PP-36 fragment-vs-parcel threshold basis.
#
# Read-only. Usage:  ./scripts/validation/diagnose_residual_green.sh [state ...]
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

PSQL="docker compose exec -T postgres psql -U postgres -d miningapp"
TARGET="${GATE_TARGET:-tiles.legality_polygons}"
if [ "$#" -gt 0 ]; then STATES="$*"; else STATES=$(reg_states_for_role confirm_open | tr '\n' ' '); fi

printf '%-4s %-11s %-12s %12s %10s %11s %-8s %s\n' \
  ST LAT LNG PARCEL_M2 GREEN_M2 TRUE_GREEN COVERING SOURCE
echo "-------------------------------------------------------------------------------------------------"

TOTAL=0
for st in $STATES; do
  STU=$(echo "$st" | tr '[:lower:]' '[:upper:]')
  KEY=$(reg_key_for_state_role "$STU" confirm_open) || continue
  STAGING=$(reg_confirm "$KEY" staging)
  PUB=$(reg_confirm "$KEY" public_predicate)

  eval "$PSQL -tAq -F'|' <<SQL
SET client_min_messages TO WARNING;
SET statement_timeout = 0;
WITH notpub AS (
  SELECT ST_MakeValid(geom) AS geom FROM ${STAGING} WHERE (${PUB}) IS NOT TRUE
), region AS (
  SELECT ST_Union(geom) AS geom FROM public.supported_region WHERE state_code = '${STU}'
), g AS (
  SELECT ST_CollectionExtract(ST_MakeValid(ST_Intersection(n.geom, r.geom)), 3) AS geom
  FROM notpub n CROSS JOIN region r
  WHERE n.geom IS NOT NULL AND NOT ST_IsEmpty(n.geom) AND ST_Dimension(n.geom) = 2
    AND ST_Intersects(n.geom, r.geom)
), gv AS (
  SELECT geom, ST_PointOnSurface(geom) AS pt, ST_Area(geom::geography) AS src_m2
  FROM g WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom) AND ST_Dimension(geom) = 2
), bad AS (
  SELECT gv.*, (SELECT l.verdict FROM ${TARGET} l WHERE ST_Covers(l.geom, gv.pt)
                ORDER BY orescout_rank(l.verdict) DESC LIMIT 1) AS v
  FROM gv WHERE src_m2 >= 400
), m AS (
  SELECT bad.*,
    (SELECT ST_Union(ST_Intersection(l.geom, bad.geom)) FROM ${TARGET} l
      WHERE l.verdict = 'GREEN' AND ST_Intersects(l.geom, bad.geom)) AS grn,
    (SELECT ST_Union(ST_Intersection(l.geom, bad.geom)) FROM ${TARGET} l
      WHERE l.verdict IN ('YELLOW','RED') AND ST_Intersects(l.geom, bad.geom)) AS yel
  FROM bad WHERE v = 'GREEN'
)
SELECT '${STU}'
     || '|' || round(ST_Y(pt)::numeric, 6)
     || '|' || round(ST_X(pt)::numeric, 6)
     || '|' || round(src_m2)::text
     || '|' || round(COALESCE(ST_Area(grn::geography), 0))::text
     || '|' || round(COALESCE(ST_Area(ST_Difference(grn,
                 COALESCE(yel, ST_GeomFromText('POLYGON EMPTY',4326)))::geography), 0))::text
     || '|' || COALESCE((SELECT l.state_nm FROM ${TARGET} l
                         WHERE l.source_key='padus' AND l.verdict='GREEN' AND ST_Covers(l.geom, m.pt)
                         ORDER BY ST_Area(l.geom) LIMIT 1), '?')
     || '|' || '${KEY}'
FROM m ORDER BY 1;
SQL" | while IFS='|' read -r s lat lng src grn true cov note; do
    [ -n "${s:-}" ] || continue
    printf '%-4s %-11s %-12s %12s %10s %11s %-8s %s\n' "$s" "$lat" "$lng" "$src" "$grn" "$true" "$cov" "$note"
    echo "$true" >> "${TMPDIR:-/tmp}/orescout_pp35_$$"
  done
done

# Subshell in the pipe cannot update TOTAL, so sum the spill file.
SPILL="${TMPDIR:-/tmp}/orescout_pp35_$$"
if [ -f "$SPILL" ]; then
  TOTAL=$(awk '{s+=$1} END{print s+0}' "$SPILL"); rm -f "$SPILL"
fi
echo "-------------------------------------------------------------------------------------------------"
echo "TRUE false-GREEN total across the states scanned: ${TOTAL} m2"
