#!/usr/bin/env bash
# Golden-watershed regression gate for the Tier-B prospecting composite (TIER_B_FABLE_BRIEF.md).
# Asserts tiles.prospectivity against db/fixtures/prospectivity.json: known districts stay High,
# the quiet control stays empty (the locked "hide below Moderate" as a testable data property).
# Run after every prospectivity ETL rebuild (build_prospectivity.sh points here).
#
# Usage:  ./scripts/test/check_prospectivity_fixtures.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
FIX="db/fixtures/prospectivity.json"
[ -f "$FIX" ] || { echo "missing $FIX"; exit 2; }

pass=0; fail=0
while IFS=$'\t' read -r name huc12 min_high max_markers; do
  read -r highs markers < <(docker compose exec -T postgres psql -U postgres -d miningapp -tAq -F' ' -c \
    "SELECT count(*) FILTER (WHERE tier='High'), count(*) FROM tiles.prospectivity WHERE huc12='${huc12}'" </dev/null)
  ok=1; why=""
  if [ "$min_high" != "-" ] && [ "${highs:-0}" -lt "$min_high" ]; then ok=0; why+="highs=$highs<$min_high "; fi
  if [ "$max_markers" != "-" ] && [ "${markers:-0}" -gt "$max_markers" ]; then ok=0; why+="markers=$markers>$max_markers "; fi
  if [ $ok -eq 1 ]; then pass=$((pass+1)); echo "  ✓ $name (highs=$highs, markers=$markers)";
  else fail=$((fail+1)); echo "  ✗ $name  $why"; fi
done < <(python3 -c '
import json
for f in json.load(open("db/fixtures/prospectivity.json"))["fixtures"]:
    e=f["expect"]
    print("\t".join([f["name"], f["huc12"], str(e.get("min_high","-")), str(e.get("max_markers","-"))]))')

echo; echo "Prospectivity goldens: $pass passed, $fail failed"
[ $fail -eq 0 ]
