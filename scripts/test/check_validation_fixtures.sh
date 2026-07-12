#!/usr/bin/env bash
# Frozen private-parcel regression gate (Tier-1 validation, decision #44). Asserts the cardinal
# property over db/fixtures/validation-parcels.json: NO frozen private-parcel point may resolve
# GREEN — incl. the 6 Colorado sentinels that WERE false-GREEN before the parcel-grade carve.
# Run after any legality ETL rebuild / confirm-open refresh (alongside Tier-A/B).
#
# Usage:  ./scripts/test/check_validation_fixtures.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
FIX="db/fixtures/validation-parcels.json"
[ -f "$FIX" ] || { echo "missing $FIX"; exit 2; }

VALUES=$(python3 -c "
import json
fx=json.load(open('$FIX'))['fixtures']
print(','.join(\"('%s',%s,%s)\" % (f['parcel_id'], f['lat'], f['lng']) for f in fx))")

out=$(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1 -tAq -c "
SELECT v.pid FROM (VALUES ${VALUES}) AS v(pid, lat, lng)
WHERE (SELECT verdict FROM tiles.legality_polygons l
       WHERE ST_Covers(l.geom, ST_SetSRID(ST_MakePoint(v.lng, v.lat), 4326))
       ORDER BY orescout_rank(l.verdict) DESC LIMIT 1) = 'GREEN';") || exit 2

n=$(python3 -c "import json; print(len(json.load(open('$FIX'))['fixtures']))")
if [ -n "$out" ]; then
  echo "$out" | sed 's/^/  ✗ FALSE-GREEN regression: /'
  echo "Validation goldens: FAILED ($(echo "$out" | wc -l | tr -d ' ') of $n private parcels resolve GREEN)"
  exit 1
fi
echo "Validation goldens: $n/$n private parcels non-GREEN ✓"
