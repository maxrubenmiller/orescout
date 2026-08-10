#!/usr/bin/env bash
# Pre-swap safety gate for a candidate legality table (review findings PP-8 / PP-9).
#
# Computes the baked most-restrictive verdict at every Tier-B golden coordinate against the
# table you name, and asserts it matches the fixture's `tileBase` expectation. This is the
# baked-data half of scripts/run-tier-b.sh, factored out so it can run against a table that is
# NOT yet live — which is the whole point: it lets a rebuild/refresh be gated BEFORE the rows
# reach the serving table, instead of after (the PP-8/PP-9 defect).
#
#   ./scripts/etl/gate_legality_tilebase.sh tiles.legality_polygons_new
#
# Predicate: ST_Covers, matching src/OreScout.Api/Services/AssessmentService.cs:199 exactly.
# run-tier-b.sh's own tile-side check still uses ST_Contains (review finding PP-22, LOW, not
# fixed here) — a gate that is supposed to certify the engine must use the engine's predicate,
# so this one does. On a boundary-exact golden the two would disagree; none currently is.
#
# Exits 0 with a one-line summary, or non-zero listing every mismatch. Read-only.
set -uo pipefail
cd "$(dirname "$0")/../.."

TBL="${1:?usage: gate_legality_tilebase.sh <schema.table>}"
FIX="db/fixtures/verdicts.json"
PSQL="${REFRESH_PSQL:-docker compose exec -T postgres psql -U postgres -d miningapp}"

[ -f "$FIX" ] || { echo "✗ tilebase gate: missing $FIX" >&2; exit 2; }

exists=$(eval "$PSQL -tAq -c \"SELECT to_regclass('$TBL') IS NOT NULL\"")
[ "$exists" = "t" ] || { echo "✗ tilebase gate: $TBL does not exist" >&2; exit 2; }

# Only coordinates cross into SQL (numeric, from the fixture file); expectations stay in bash so
# no fixture string is ever interpolated into a query.
VALUES=$(python3 -c '
import json
fx = json.load(open("'"$FIX"'"))["fixtures"]
print(",".join("(%d,%s,%s)" % (i, f["lat"], f["lng"]) for i, f in enumerate(fx)))')

OUT=$(eval "$PSQL -tAq -F$'\t' -c \"
SELECT v.idx, COALESCE((
  SELECT l.verdict FROM $TBL l
  WHERE ST_Covers(l.geom, ST_SetSRID(ST_MakePoint(v.lng, v.lat), 4326))
  ORDER BY orescout_rank(l.verdict) DESC LIMIT 1), '')
FROM (VALUES ${VALUES}) AS v(idx, lat, lng);\"") \
  || { echo "✗ tilebase gate: query against $TBL failed" >&2; exit 1; }

# idx -> "name<TAB>expected_tilebase" (bash 3.2: plain indexed array, fixture indices are 0..n).
EXPECT=()
while IFS= read -r line; do EXPECT+=("$line"); done < <(python3 -c '
import json
for f in json.load(open("'"$FIX"'"))["fixtures"]:
  print(f["name"] + "\t" + (f.get("tileBase") or ""))')

pass=0; fail=0; fails=()
while IFS=$'\t' read -r idx act; do
  [ -n "${idx:-}" ] || continue
  name="${EXPECT[$idx]%%$'\t'*}"
  exp="${EXPECT[$idx]#*$'\t'}"
  if [ "$exp" = "$act" ]; then
    pass=$((pass+1))
  else
    fail=$((fail+1))
    fails+=("$name :: tileBase=[$act] expected=[$exp]")
  fi
done <<< "$OUT"

if [ "$fail" -ne 0 ]; then
  echo "✗ tilebase gate on $TBL: $pass passed, $fail FAILED" >&2
  for x in "${fails[@]:-}"; do [ -n "$x" ] && echo "    $x" >&2; done
  exit 1
fi
echo "[gate] tilebase ok on $TBL: $pass/$pass golden points match (ST_Covers)"
