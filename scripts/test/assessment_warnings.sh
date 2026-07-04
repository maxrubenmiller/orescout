#!/usr/bin/env bash
# Regression check for IMP-02 (PROJECT_PLAN.md §6.4): boundary-inclusive verdict lookup +
# the two standing warnings.
#   1. A point exactly ON a RED polygon boundary resolves most-restrictive (RED), not to the
#      surrounding open polygon (ST_Covers, not ST_Contains).
#   2. A point within 500 m of (but outside) a RED unit carries a "Near boundary of …" warning.
#   3. With land data >= 2 years old (PAD-US 2024), every result carries the stale-vintage warning.
#
# Points are real, verified against tiles.legality_polygons (N. Fork Little Humboldt WSA, NV):
#   ON_BOUNDARY  = an exterior-ring vertex of the WSA that lies inside the surrounding BLM GREEN.
#   NEAR_RED     = a GREEN-verdict point 157 m outside the WSA.
#
# Approach: throwaway API instance from THIS checkout on :5096 against the real dev DB
# (read-only), torn down on exit. Non-disruptive.
# Usage:  ./scripts/test/assessment_warnings.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
PORT=5096
BASE="http://localhost:${PORT}/api/v1"
KEY="${ORESCOUT_API_KEY:-dev-local-key-change-me}"
DLL="src/OreScout.Api/bin/Debug/net10.0/OreScout.Api.dll"

ON_BOUNDARY="lat=41.679792290568244&lng=-117.20665606088149"
NEAR_RED="lat=41.519313612934056&lng=-117.15052711891556"

echo "building API…"
dotnet build src/OreScout.Api -v q --nologo >/dev/null || exit 2

echo "starting throwaway instance on :${PORT}…"
ASPNETCORE_ENVIRONMENT=Development \
  dotnet "$DLL" --urls "http://localhost:${PORT}" --contentRoot "$PWD/src/OreScout.Api" \
  >/tmp/api_warnings_test.log 2>&1 &
API_PID=$!
cleanup() { kill "$API_PID" 2>/dev/null; }
trap cleanup EXIT

for _ in $(seq 1 30); do
  c=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/health" 2>/dev/null)
  [ "$c" = "200" ] && break
  sleep 1
done

pass=0; fail=0
check() { # name, ok(0/1), detail
  if [ "$2" = "1" ]; then pass=$((pass+1)); echo "  ✓ $1"; else fail=$((fail+1)); echo "  ✗ $1  [$3]"; fi
}
get() { curl -s --max-time 20 -H "X-Api-Key: $KEY" "$BASE/assessment?$1"; }

echo "asserting §6.4 boundary + warning behavior:"

r=$(get "$ON_BOUNDARY")
status=$(printf '%s' "$r" | python3 -c 'import sys,json; print(json.load(sys.stdin)["collectingStatus"])' 2>/dev/null)
check "point ON WSA boundary -> RED (ST_Covers)" "$([ "$status" = "RED" ] && echo 1 || echo 0)" "status=$status"

r=$(get "$NEAR_RED")
status=$(printf '%s' "$r" | python3 -c 'import sys,json; print(json.load(sys.stdin)["collectingStatus"])' 2>/dev/null)
check "point 157m outside WSA -> still GREEN" "$([ "$status" = "GREEN" ] && echo 1 || echo 0)" "status=$status"
nearw=$(printf '%s' "$r" | python3 -c 'import sys,json; ws=json.load(sys.stdin)["warnings"]; print(any(w.startswith("Near boundary of") for w in ws))' 2>/dev/null)
check "…and carries 'Near boundary of …' warning" "$([ "$nearw" = "True" ] && echo 1 || echo 0)" "warnings=$(printf '%s' "$r" | python3 -c 'import sys,json; print(json.load(sys.stdin)["warnings"])' 2>/dev/null)"
stale=$(printf '%s' "$r" | python3 -c 'import sys,json; ws=json.load(sys.stdin)["warnings"]; print(any("outdated" in w for w in ws))' 2>/dev/null)
check "…and carries stale-vintage warning (PAD-US 2024, now >= 2y)" "$([ "$stale" = "True" ] && echo 1 || echo 0)" ""

r=$(get "$ON_BOUNDARY")
nearw=$(printf '%s' "$r" | python3 -c 'import sys,json; ws=json.load(sys.stdin)["warnings"]; print(any(w.startswith("Near boundary of") for w in ws))' 2>/dev/null)
check "point INSIDE RED gets no near-boundary warning for its own unit" "$([ "$nearw" = "False" ] && echo 1 || echo 0)" "warnings=$(printf '%s' "$r" | python3 -c 'import sys,json; print(json.load(sys.stdin)["warnings"])' 2>/dev/null)"

echo
echo "$pass passed, $fail failed"
[ $fail -eq 0 ]
