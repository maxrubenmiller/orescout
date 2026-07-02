#!/usr/bin/env bash
# Rebuild the unified legality layer SAFELY (IMP-03; PROJECT_PLAN.md §6.6.1 + §6.4.1).
#
# unify.sql DROPs and rebuilds tiles.legality_polygons with PAD-US rows only; the
# confirm-open rows (e.g. CA CAL FIRE, source_key='calfire_ca') come from separate
# scripts/etl/confirm_open_*.sql scripts. Running unify.sql alone silently reverts
# every confirm-open polygon to GREEN — a latent false-GREEN (review finding F-4).
#
# This orchestrator makes the full rebuild one atomic *operator step*:
#   1. preflight: staging tables present
#   2. unify.sql                      (PAD-US base verdicts)
#   3. every confirm_open_*.sql       (sorted; asserts each actually inserted rows)
#   4. Tier-A classifier fixtures     (scripts/run-fixtures.sh)
#   5. Tier-B golden coordinates      (scripts/run-tier-b.sh — needs the API up)
# Any failure exits non-zero. Never run unify.sql by hand anymore — run this.
#
# Usage:  ./scripts/etl/rebuild_legality.sh [api_base_url]
set -euo pipefail
cd "$(dirname "$0")/../.."
API="${1:-http://localhost:5167/api/v1}"

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)

fail() { echo "✗ $*" >&2; exit 1; }
q()    { "${PSQL[@]}" -tAq -c "$1"; }

# ---- 1. preflight -----------------------------------------------------------
[ "$(q "SELECT to_regclass('staging.padus_staging') IS NOT NULL")" = "t" ] \
  || fail "staging.padus_staging missing — run scripts/etl/load_padus_gdb.sh first"
for f in scripts/etl/confirm_open_*.sql; do
  [ -e "$f" ] || continue
  # each confirm-open script names its staging dependency in a '-- Prereq:' line; we
  # only hard-check the known ones to fail early with a useful message.
  case "$f" in
    *confirm_open_ca.sql)
      [ "$(q "SELECT to_regclass('staging.calfire_ownership') IS NOT NULL")" = "t" ] \
        || fail "staging.calfire_ownership missing — run scripts/etl/pull_calfire.sh first" ;;
    *confirm_open_ut.sql)
      [ "$(q "SELECT to_regclass('staging.ugrc_ownership') IS NOT NULL")" = "t" ] \
        || fail "staging.ugrc_ownership missing — run scripts/etl/pull_ugrc.sh first" ;;
  esac
done

# ---- 1b. classifier functions (CREATE OR REPLACE — idempotent) ---------------
# The baked verdicts are whatever the installed functions say: re-apply them so a classifier
# edit (e.g. #36) cannot be silently skipped on a rebuild (IMP-08).
echo "[rebuild] db/02_classifier.sql (classifier functions)..."
"${PSQL[@]}" < db/02_classifier.sql >/dev/null

# ---- 2. unify ---------------------------------------------------------------
echo "[rebuild] unify.sql (PAD-US base verdicts)…"
"${PSQL[@]}" < scripts/etl/unify.sql >/dev/null

base=$(q "SELECT count(*) FROM tiles.legality_polygons")
[ "$base" -gt 0 ] || fail "unify produced 0 rows"
echo "[rebuild]   legality_polygons: $base base rows"

# ---- 3. confirm-open steps (each must insert rows) --------------------------
for f in scripts/etl/confirm_open_*.sql; do
  [ -e "$f" ] || { echo "[rebuild] no confirm_open_*.sql scripts found"; break; }
  before=$(q "SELECT count(*) FROM tiles.legality_polygons WHERE source_key <> 'padus'")
  echo "[rebuild] ${f} ..."
  "${PSQL[@]}" < "$f" >/dev/null
  after=$(q "SELECT count(*) FROM tiles.legality_polygons WHERE source_key <> 'padus'")
  [ "$after" -gt "$before" ] \
    || fail "$f inserted no rows (before=$before after=$after) — confirm-open layer would be missing"
  echo "[rebuild]   +$((after - before)) confirm-open rows"
done

# ---- 4./5. fixture gates ----------------------------------------------------
echo "[rebuild] Tier-A classifier fixtures…"
./scripts/run-fixtures.sh

echo "[rebuild] Tier-B golden coordinates (API: $API)…"
curl -sf -o /dev/null --max-time 5 "$API/health" \
  || fail "API not reachable at $API — start it (dotnet run --project src/OreScout.Api) and re-run: ./scripts/run-tier-b.sh"
./scripts/run-tier-b.sh "$API"

echo "[rebuild] ✓ legality layer rebuilt and gated ($base base + confirm-open rows, Tier-A+B green)"
