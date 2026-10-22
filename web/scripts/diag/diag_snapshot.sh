#!/usr/bin/env bash
# Sets up two saved pins (drift + stable), runs the headless snapshot-contract test,
# then cleans up. See diag_snapshot.mjs. Idempotent-ish: deletes its own test pins at the end.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/../../.."
KEY="${ORESCOUT_API_KEY:-dev-local-key-change-me}"
API="http://localhost:5167/api/v1"
H=(-H "X-Api-Key: $KEY" -H "Content-Type: application/json")
# Great Basin NP — known RED (national park) land.
LL='{"lat":38.94092,"lng":-114.28849,"status":"want_to_visit"}'

mkpin() { curl -s -X POST "$API/pins" "${H[@]}" -d "$(python3 -c "import json,sys;d=json.loads('$LL');d['title']=sys.argv[1];print(json.dumps(d))" "$1")"; }
field() { python3 -c "import sys,json;print(json.load(sys.stdin)$1)"; }

echo "creating drift pin…"
DRIFT=$(mkpin "__snap_drift__")
DRIFT_ID=$(echo "$DRIFT" | field "['id']")
DRIFT_V=$(echo "$DRIFT" | field "['assessmentSnapshot']['collectingStatus']")
echo "  drift pin $DRIFT_ID — server snapshot verdict = $DRIFT_V (expected RED)"

echo "creating stable pin…"
STABLE=$(mkpin "__snap_stable__")
STABLE_ID=$(echo "$STABLE" | field "['id']")

cleanup() {
  echo "cleaning up test pins…"
  curl -s -o /dev/null -X DELETE "$API/pins/$DRIFT_ID" "${H[@]}" || true
  curl -s -o /dev/null -X DELETE "$API/pins/$STABLE_ID" "${H[@]}" || true
}
trap cleanup EXIT

# Simulate "saved when it was Open, land later restricted": flip the STORED snapshot to GREEN.
echo "mutating drift pin snapshot RED→GREEN (simulating a land-status change since save)…"
docker compose exec -T postgres psql -tAq -U postgres -d miningapp -c \
  "UPDATE public.pins SET assessment_snapshot = jsonb_set(jsonb_set(assessment_snapshot, '{collectingStatus}', '\"GREEN\"'::jsonb), '{ambiguityType}', 'null'::jsonb) WHERE id='$DRIFT_ID';"

echo "running headless contract test…"
node "$SCRIPT_DIR/diag_snapshot.mjs"
