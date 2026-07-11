#!/usr/bin/env bash
# Build the Tier-B prospecting-potential composite (TIER_B_FABLE_BRIEF.md; §5.3, decision #42):
# config -> staging.prospectivity_config (jsonb), then build_prospectivity.sql computes the
# composite and rebuilds tiles.prospectivity. Fails loud on any assertion (completeness check,
# empty output). REFERENCE-ONLY: never touches the verdict engine or legality tiles.
#
# Prereqs: pull_ngdb.sh + pull_wbd.sh done (staging.ngdb_sites/ngdb_chem/wbd_huc12/wbd_huc10);
#          tiles.mrds present (Tier A) for the Signal-3 producer anchor.
# Usage:   ./scripts/etl/build_prospectivity.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
q() { "${PSQL[@]}" -tAq -c "$1"; }
fail() { echo "✗ $*" >&2; exit 1; }

# preflight
for t in staging.ngdb_sites staging.ngdb_chem staging.wbd_huc12 staging.wbd_huc10 tiles.mrds; do
  [ "$(q "SELECT to_regclass('$t') IS NOT NULL")" = "t" ] || fail "$t missing — run the pull scripts first (see header)"
done

echo "[prospectivity] loading config/prospectivity.json -> staging.prospectivity_config…"
"${PSQL[@]}" -q -c "DROP TABLE IF EXISTS staging.prospectivity_config; CREATE TABLE staging.prospectivity_config (cfg jsonb);"
python3 -c "import json,sys; json.load(open('config/prospectivity.json')); print('config JSON valid')"
# COPY text format interprets backslash escapes, and json.dumps ASCII-escapes non-ASCII
# (an en-dash became a literal 'u2013' in popups — caught by the frontend diag). Emit raw
# UTF-8 and double any backslashes so COPY passes the JSON through verbatim.
python3 -c "import json; print(json.dumps(json.load(open('config/prospectivity.json')), ensure_ascii=False).replace(chr(92), chr(92)*2))" \
  | "${PSQL[@]}" -q -c "COPY staging.prospectivity_config (cfg) FROM STDIN;"

echo "[prospectivity] build_prospectivity.sql (composite -> tiles.prospectivity)…"
"${PSQL[@]}" < scripts/etl/build_prospectivity.sql

rows=$(q "SELECT count(*) FROM tiles.prospectivity")
[ "$rows" -gt 0 ] || fail "tiles.prospectivity is empty"
echo "[prospectivity] tiles.prospectivity built: $rows markers"

echo "[prospectivity] golden-watershed fixtures gate…"
./scripts/test/check_prospectivity_fixtures.sh || fail "golden-watershed fixtures FAILED — do not ship this build"
echo "[prospectivity] ✓ built and gated ($rows markers)"
