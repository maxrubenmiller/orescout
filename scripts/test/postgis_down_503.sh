#!/usr/bin/env bash
# Regression check for docs/planning/PROJECT_PLAN.md §6.3 / decision #33: when PostGIS is unreachable the API
# must return HTTP 503 (NOT a generic 500), with a Retry-After header, CORS headers intact, and the
# canonical { error: { code, message } } body. PostGIS-backed endpoints (/assessment, /meta, /pins,
# and /health by its own logic) all share the behavior.
#
# Approach: launch a THROWAWAY API instance pointed at a dead Postgres port, so every DB call fails
# to connect — deterministic and NON-DISRUPTIVE (the real postgres container is never touched, so no
# broken-connection-pool race and nothing else 503s). Tears the instance down on exit.
#
# Usage:  ./scripts/test/postgis_down_503.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
PORT=5099
DEAD_DB="Host=localhost;Port=5499;Database=miningapp;Username=postgres;Password=postgres"
BASE="http://localhost:${PORT}/api/v1"
KEY="${ORESCOUT_API_KEY:-dev-local-key-change-me}"
ORIGIN="http://localhost:5173"
DLL="src/OreScout.Api/bin/Debug/net10.0/OreScout.Api.dll"
NV="$BASE/assessment?lat=38.6&lng=-116.0"

echo "building API…"
dotnet build src/OreScout.Api -v q --nologo >/dev/null

echo "starting throwaway instance on :${PORT} (DB → dead port 5499)…"
# --contentRoot points at the project dir so appsettings.json (ApiKey, CORS, etc.) is loaded;
# only the connection string is overridden to the dead port.
ASPNETCORE_ENVIRONMENT=Development ConnectionStrings__Postgres="$DEAD_DB" \
  dotnet "$DLL" --urls "http://localhost:${PORT}" --contentRoot "$PWD/src/OreScout.Api" >/tmp/api_503test.log 2>&1 &
API_PID=$!
cleanup() { kill "$API_PID" 2>/dev/null; }
trap cleanup EXIT

for _ in $(seq 1 30); do
  c=$(curl -s -o /dev/null -w "%{http_code}" "$BASE/health" 2>/dev/null)
  [ "$c" = "503" ] || [ "$c" = "200" ] && break
  sleep 1
done

pass=0; fail=0
check() { if [ "$2" = "$3" ]; then echo "  ✓ $1 ($3)"; pass=$((pass+1)); else echo "  ✗ FAIL $1 — expected '$2', got '$3'"; fail=$((fail+1)); fi; }
code() { curl -s --max-time 10 -o /dev/null -w "%{http_code}" -H "X-Api-Key: $KEY" "$1"; }
headers() { curl -s --max-time 10 -D - -o /dev/null -H "X-Api-Key: $KEY" -H "Origin: $ORIGIN" "$1" | tr -d '\r'; }
bodycode() {
  local f; f="$(mktemp)"
  curl -s --max-time 10 -o "$f" -H "X-Api-Key: $KEY" "$1"
  python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["error"]["code"])' "$f" 2>/dev/null
  rm -f "$f"
}

echo "asserting DB-unreachable behavior:"
H="$(headers "$NV")"
check "/assessment → 503 (not 500)"        503 "$(printf '%s\n' "$H" | awk '/^HTTP/{c=$2} END{print c}')"
check "/assessment Retry-After present"     yes "$(printf '%s\n' "$H" | grep -qi '^Retry-After:' && echo yes || echo no)"
check "/assessment CORS header present"     yes "$(printf '%s\n' "$H" | grep -qi '^Access-Control-Allow-Origin:' && echo yes || echo no)"
check "/assessment body code"               service_unavailable "$(bodycode "$NV")"
check "/meta → 503"                         503 "$(code "$BASE/meta")"
check "/pins → 503"                         503 "$(code "$BASE/pins")"
check "/health → 503"                       503 "$(code "$BASE/health")"

# A bad-coordinate request is rejected at validation BEFORE any DB call → still 400, proving the
# handler only catches dependency failures (not a blanket 503 on every request).
check "/assessment bad coords → 400 (pre-DB validation)" 400 "$(code "$BASE/assessment?lat=999&lng=0")"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
