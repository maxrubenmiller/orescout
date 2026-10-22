#!/usr/bin/env bash
# Cross-border confirm-open sweep (review finding PP-30).
#
# THE GAP. Every confirm_open_<st>.sql selects its input by the PAD-US state_nm ATTRIBUTE:
#     FROM :legality_tbl WHERE state_nm='NV' AND verdict='GREEN' AND source_key='padus'
# A GREEN polygon labelled 'CA' that physically covers Nevada ground is therefore never processed
# by Nevada's carve. California's carve does process it, but subtracts CAL FIRE's buffer — and CAL
# FIRE has no coverage in Nevada, so the demotion decision for Nevada ground gets made using
# California's ownership layer. Either way, that ground is judged by the wrong authority, or none.
# Measured: 730 km2 of GREEN across the 8 states carries a state_nm other than the ground it covers.
#
# THE SWEEP. For each state, take PAD-US GREEN that is NOT labelled that state, intersect it with
# the ground that state's own layer maps as not-public, and demote the overlap to YELLOW.
#
# Scoping note: this joins straight to the state's conf_notpub table, which IS the scoping — the
# only ground that can match is ground that state's authority actually maps. That deliberately
# avoids public.supported_region, which has a documented fail-open (PP-15): if it were ever empty,
# an extent-based scope would silently select nothing and this sweep would become a no-op that
# still reported success.
#
# Rows are written under source_key='crossborder_sweep' so the whole pass is auditable and
# revertible with a single DELETE, without touching any state's carve output.
#
# Run AFTER all confirm_open_*.sql (it reads their conf_notpub_* staging tables).
#
# Usage:  ./scripts/etl/sweep_crossborder.sh <legality_table> [state ...]
#   e.g.  ./scripts/etl/sweep_crossborder.sh tiles.legality_polygons_new
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

TBL="${1:?usage: sweep_crossborder.sh <legality_table> [state ...]}"; shift
PSQL="${REFRESH_PSQL:-docker compose exec -T postgres psql -U postgres -d miningapp}"
FLOOR=400   # the documented meaningful-parcel floor (docs/planning/PROJECT_PLAN.md:2374)

if [ "$#" -gt 0 ]; then STATES="$*"; else STATES=$(reg_states_for_role confirm_open | tr '\n' ' '); fi

exists=$(eval "$PSQL -tAq -c \"SELECT to_regclass('$TBL') IS NOT NULL\"" | tr -d '[:space:]')
[ "$exists" = "t" ] || { echo "✗ sweep: $TBL does not exist" >&2; exit 2; }
echo "[sweep] cross-border confirm-open sweep on $TBL"

total_rows=0; total_km2=0; swept=0
for st in $STATES; do
  STU=$(echo "$st" | tr '[:lower:]' '[:upper:]')
  STL=$(echo "$st" | tr '[:upper:]' '[:lower:]')
  KEY=$(reg_key_for_state_role "$STU" confirm_open) || { echo "  ?? $STU: no confirm_open source"; continue; }
  ATTR=$(reg_attribution "$KEY")
  VINTAGE=$(reg_vintage "$KEY")
  # Bespoke states name their not-public table differently; the template states all follow the
  # conf_notpub_<st> convention. Optional registry override, so adding a state needs no new field.
  NOTPUB=$(reg_confirm "$KEY" notpub_table 2>/dev/null) || NOTPUB="staging.conf_notpub_${STL}"

  if [ "$(eval "$PSQL -tAq -c \"SELECT to_regclass('$NOTPUB') IS NOT NULL\"" | tr -d '[:space:]')" != "t" ]; then
    echo "  ?? $STU: $NOTPUB missing — run confirm_open_${STL}.sql first; SKIPPED"
    continue
  fi

  out=$(eval "$PSQL -tAq -F'|' <<SQL
SET client_min_messages TO WARNING;
SET statement_timeout = 0;
DELETE FROM ${TBL} WHERE source_key = 'crossborder_sweep' AND state_nm = '${STU}';
INSERT INTO ${TBL}
  (geom, verdict, reason, land_manager, unit_nm, protection_status, state_nm, data_vintage, source_key)
SELECT ST_Multi(d.geom), 'YELLOW',
  'Open status not confirmed by ${STU} public-ownership data (${ATTR}) — possibly private; verify before collecting.',
  NULL, NULL, 'unconfirmed-open', '${STU}', '${VINTAGE} (cross-border sweep vs PAD-US)', 'crossborder_sweep'
FROM (
  SELECT (ST_Dump(ST_CollectionExtract(ST_MakeValid(ST_Intersection(g.geom, np.geom)), 3))).geom AS geom,
         -- PP-36: carry the SOURCE parcel's area through, so the floor below can be applied to the
         -- ground rather than to however much of it happens to overlap this GREEN chunk.
         ST_Area(np.geom::geography) AS src_m2
  FROM ${NOTPUB} np
  JOIN (SELECT ST_Subdivide(geom, 256) AS geom FROM ${TBL}
        WHERE verdict = 'GREEN' AND source_key = 'padus'
          AND state_nm IS DISTINCT FROM '${STU}') g
    ON ST_Intersects(np.geom, g.geom)
) d
WHERE d.geom IS NOT NULL AND NOT ST_IsEmpty(d.geom)
  -- PP-36. This used to test the INTERSECTION only, which is the same fragment-vs-parcel basis error
  -- the carve had. Measured: the AZ residual at (37.000016, -113.196138) is a 1,575 m² not-public
  -- parcel whose overlap with the mislabelled GREEN was 362 m² — under the floor, so the sweep saw
  -- it and dropped it, while gate_notpublic_green.sh flagged it because the gate judges the parcel.
  -- Keep the overlap when EITHER it or the ground it came from clears the floor.
  AND (ST_Area(d.geom::geography) > ${FLOOR} OR d.src_m2 > ${FLOOR});
SELECT count(*) || '|' || COALESCE(round((sum(ST_Area(geom::geography))/1e6)::numeric, 3), 0)
FROM ${TBL} WHERE source_key = 'crossborder_sweep' AND state_nm = '${STU}';
SQL")
  n=$(printf '%s' "$out" | tail -1 | cut -d'|' -f1)
  km=$(printf '%s' "$out" | tail -1 | cut -d'|' -f2)
  n=${n:-0}; km=${km:-0}
  printf '  %-3s %6s pieces  %8s km2   (from %s)\n' "$STU" "$n" "$km" "$NOTPUB"
  total_rows=$((total_rows + n)); swept=$((swept + 1))
done

# A sweep that swept nothing is a broken sweep, not a clean one — same 0-of-0 trap this project
# has hit repeatedly. Report it as a failure so it cannot be mistaken for "nothing to fix".
if [ "$swept" -eq 0 ]; then
  echo "✗ sweep: no states were processed — check that confirm_open_*.sql has run" >&2
  exit 1
fi
echo "[sweep] ✓ $total_rows crossborder_sweep rows across $swept states on $TBL"
