#!/usr/bin/env bash
# Tier-B golden-coordinate integration fixtures (PROJECT_PLAN.md §6.4.2). For each point asserts:
#   1) live /assessment collectingStatus (+ ambiguityType where pinned) == expected, AND
#   2) the direct tiles.legality_polygons most-restrictive lookup == expected tileBase
# i.e. the C# assessment engine and the baked tile data agree at real coordinates of known type.
# Doubles as the regression gate for ETL re-runs (e.g. PAD-US 4.2): a flip means a unit was recoded
# or a boundary moved — catch it before users do.
#
# Requires: the API up (default :5167) and `docker compose up -d` (postgres).
# Usage:  ./scripts/run-tier-b.sh [api_base_url]
set -uo pipefail
cd "$(dirname "$0")/.."
API="${1:-http://localhost:5167/api/v1}"
KEY="${ORESCOUT_API_KEY:-dev-local-key-change-me}"
FIX="db/fixtures/verdicts.json"

[ -f "$FIX" ] || { echo "missing $FIX"; exit 2; }

# 1) One psql call computes the tile most-restrictive verdict for every fixture point.
VALUES=$(python3 -c '
import json
fx=json.load(open("'"$FIX"'"))["fixtures"]
print(",".join("(%d,%s,%s)" % (i, f["lat"], f["lng"]) for i, f in enumerate(fx)))')
TILE=$(docker compose exec -T postgres psql -U postgres -d miningapp -At -F$'\t' -c "
SELECT v.idx, COALESCE((
  SELECT verdict FROM tiles.legality_polygons l
  -- ST_Covers, not ST_Contains (review finding PP-22): the engine uses ST_Covers deliberately so
  -- boundary points resolve most-restrictive (AssessmentService.cs:193-199). A gate that certifies
  -- the engine must use the engine's predicate, or a golden sitting exactly on a polygon edge is
  -- scored differently by the gate than by the code it is gating.
  WHERE ST_Covers(l.geom, ST_SetSRID(ST_MakePoint(v.lng, v.lat), 4326))
  ORDER BY orescout_rank(l.verdict) DESC LIMIT 1), '')
FROM (VALUES ${VALUES}) AS v(idx, lat, lng);")
# macOS ships bash 3.2 (no associative arrays); fixture indices are 0..n so a plain
# indexed array works as the idx -> tile-verdict map.
TILEMAP=()
while IFS=$'\t' read -r idx verd; do [ -n "$idx" ] && TILEMAP[$idx]="$verd"; done <<< "$TILE"

# 2) Hit /assessment for each point and assert.
pass=0; fail=0; i=0; fails=()
while IFS=$'\t' read -r name lat lng expect amb tilebase; do
  resp=$(curl -s --max-time 15 -H "X-Api-Key: $KEY" "$API/assessment?lat=$lat&lng=$lng")
  parsed=$(printf '%s' "$resp" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); print((d.get("collectingStatus") or "")+"|"+(d.get("ambiguityType") or ""))
except Exception: print("|")' 2>/dev/null)
  status="${parsed%%|*}"; ambt="${parsed##*|}"
  tile="${TILEMAP[$i]:-}"
  exptile="$tilebase"; [ "$exptile" = "-" ] && exptile=""

  ok=1; why=""
  [ "$status" = "$expect" ] || { ok=0; why+="status=$status≠$expect "; }
  if [ "$amb" != "-" ]; then [ "$ambt" = "$amb" ] || { ok=0; why+="amb=$ambt≠$amb "; }; fi
  [ "$tile" = "$exptile" ] || { ok=0; why+="tile=[$tile]≠[$exptile] "; }

  if [ $ok -eq 1 ]; then pass=$((pass+1)); else fail=$((fail+1)); fails+=("$name :: $why"); fi
  i=$((i+1))
done < <(python3 -c '
import json
for f in json.load(open("'"$FIX"'"))["fixtures"]:
  print("\t".join([f["name"], str(f["lat"]), str(f["lng"]), f["expect"],
                   f.get("ambiguity") or "-", f.get("tileBase") or "-"]))')

echo
echo "Tier-B: $pass passed, $fail failed (of $((pass+fail)))"
for x in "${fails[@]:-}"; do [ -n "$x" ] && echo "  ✗ $x"; done
[ $fail -eq 0 ]
