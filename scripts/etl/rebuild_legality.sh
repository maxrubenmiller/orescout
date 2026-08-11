#!/usr/bin/env bash
# Rebuild the unified legality layer SAFELY (IMP-03; PROJECT_PLAN.md §6.6.1 + §6.4.1).
#
# unify.sql rebuilds the legality table with PAD-US rows only; the confirm-open rows (e.g. CA
# CAL FIRE, source_key='calfire_ca') come from separate scripts/etl/confirm_open_*.sql scripts.
# Running unify.sql alone silently reverts every confirm-open polygon to GREEN — a latent
# false-GREEN (review finding F-4).
#
# ATOMICITY (review finding PP-8) — why this script looks the way it does:
#   Making the rebuild one atomic *operator* step was not enough. Previously unify.sql and the
#   eight confirm_open_*.sql files each ran as a separate autocommit psql session against the
#   LIVE serving table, so between unify's DROP/CREATE and each state's confirm-open commit the
#   API served Stage-1 GREEN over every acre of confirm-open YELLOW land — ~15k km2, minutes
#   wide (CA alone has run >12 min). Worse, a mid-run failure (OOM has happened on this box)
#   left the live table GREEN-reverted indefinitely: the gate was loud but not fail-safe.
#   Now the whole sequence builds into tiles.legality_polygons_new and reaches the live table
#   only through refresh_lib.sh's atomic_swap, AFTER the gates pass. Any failure before the swap
#   exits non-zero with the live table untouched — the refresh_lib.sh contract that
#   refresh_claims.sh already honored and this script did not.
#
# Sequence:
#   1. preflight: staging tables present
#   2. classifier functions (CREATE OR REPLACE — idempotent)
#   3. unify.sql                      -> _new (PAD-US base verdicts)
#   4. every confirm_open_*.sql       -> _new (asserts each source_key actually landed rows)
#   5. PRE-SWAP GATES on _new         (row-count band + Tier-B golden tileBase via ST_Covers)
#   6. atomic_swap                    -> _new becomes live in one transaction
#   7. derived display tables         (low-zoom + display partition; read the now-live table)
#   8. POST-SWAP gates                (Tier-A fixtures + Tier-B against the live API)
#
# Usage:  ./scripts/etl/rebuild_legality.sh [api_base_url]
#   LEGALITY_COUNT_BAND=<pct>  widen/narrow the pre-swap row-count band (default 25). A genuine
#   upstream release bump (PAD-US 4.1 -> 4.2) can legitimately exceed it; set it deliberately.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/refresh_lib.sh    # count_gate / atomic_swap / rfail — the safety contract
source scripts/etl/registry_lib.sh   # reg_key_for_state_role (§6.13): expected source_key per state

API="${1:-http://localhost:5167/api/v1}"
BAND="${LEGALITY_COUNT_BAND:-25}"

LIVE=tiles.legality_polygons
NEW="${LIVE}_new"

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

# A leftover _new from a previously failed run is deliberately NOT auto-dropped by the gates
# (they leave it for inspection); clear it here, at the start of a fresh run.
"${PSQL[@]}" -q -c "DROP TABLE IF EXISTS ${NEW};" >/dev/null

# ---- 2. classifier functions (CREATE OR REPLACE — idempotent) ---------------
# The baked verdicts are whatever the installed functions say: re-apply them so a classifier
# edit (e.g. #36) cannot be silently skipped on a rebuild (IMP-08).
echo "[rebuild] db/02_classifier.sql (classifier functions)..."
"${PSQL[@]}" < db/02_classifier.sql >/dev/null

# ---- 3. unify -> _new -------------------------------------------------------
echo "[rebuild] unify.sql (PAD-US base verdicts) -> ${NEW}…"
"${PSQL[@]}" -v legality_tbl="$NEW" < scripts/etl/unify.sql >/dev/null

base=$(q "SELECT count(*) FROM ${NEW}")
[ "$base" -gt 0 ] || fail "unify produced 0 rows"
echo "[rebuild]   ${NEW}: $base base rows"

# ---- 4. confirm-open steps -> _new (each must land rows for ITS source_key) --
# The old check was a bare before/after total, which a step could satisfy by inserting rows for
# the wrong source_key. Assert per-source_key against the registry instead, so a state silently
# producing nothing is caught by name (§6.13).
for f in scripts/etl/confirm_open_*.sql; do
  [ -e "$f" ] || { echo "[rebuild] no confirm_open_*.sql scripts found"; break; }
  st=$(basename "$f" .sql); st="${st#confirm_open_}"
  stu=$(echo "$st" | tr '[:lower:]' '[:upper:]')
  key=$(reg_key_for_state_role "$stu" confirm_open) \
    || fail "$f has no confirm_open entry for $stu in etl/sources.json (§6.13)"
  echo "[rebuild] ${f} -> ${NEW} (source_key=${key})…"
  "${PSQL[@]}" -v legality_tbl="$NEW" < "$f" >/dev/null
  n=$(q "SELECT count(*) FROM ${NEW} WHERE source_key = '${key}'")
  [ "$n" -gt 0 ] \
    || fail "$f inserted no ${key} rows — the confirm-open layer would be missing for ${stu}"
  echo "[rebuild]   +$n ${key} rows"
done

# ---- 5. PRE-SWAP GATES (live table still untouched) -------------------------
# Everything below this line that fails leaves the live table exactly as it was, with ${NEW}
# on disk for inspection. This is the PP-8 fix: gates BEFORE the rows can be served.
echo "[rebuild] pre-swap gates on ${NEW}…"
count_gate "$LIVE" "$BAND"
./scripts/etl/gate_legality_tilebase.sh "$NEW" \
  || fail "pre-swap tileBase gate failed — ${NEW} left for inspection, live table untouched"

# ---- 6. atomic swap ---------------------------------------------------------
atomic_swap "$LIVE"
stamp_legality_generation

# ---- 7. derived display tables (read the now-live table) --------------------
# NOTE (review findings PP-6/PP-7): these derived tables have their own non-atomic rebuild and
# their own correctness defects; both are out of scope for the PP-8 fix and tracked separately.
# What matters here is that they are rebuilt from the swapped-in data on every full rebuild.
echo "[rebuild] build_lowzoom.sql (generalized z<9 layer)..."
"${PSQL[@]}" < scripts/etl/build_lowzoom.sql >/dev/null
lz=$(q "SELECT count(*) FROM tiles.legality_lowzoom")
[ "$lz" -gt 0 ] || fail "build_lowzoom produced 0 rows"
echo "[rebuild]   legality_lowzoom: $lz rows"

# Dissolved most-restrictive DISPLAY partition (UI_CHANGES.md Changes 1+2): uniform per-verdict
# fills (no overlap darkening) + green clipped from under yellow. Reference/DISPLAY ONLY — the
# verdict engine keeps querying tiles.legality_polygons, so this never changes a verdict. Built
# from BOTH source tiers; low-zoom uses a coarser grid for lighter z0-8 tiles.
echo "[rebuild] build_legality_display.sql (display partition — normal + low-zoom)..."
"${PSQL[@]}" -v src=tiles.legality_polygons -v tgt=tiles.legality_display < scripts/etl/build_legality_display.sql >/dev/null
"${PSQL[@]}" -v src=tiles.legality_lowzoom -v tgt=tiles.legality_display_lowzoom -v cellsize=1.0 < scripts/etl/build_legality_display.sql >/dev/null
disp=$(q "SELECT count(*) FROM tiles.legality_display")
[ "$disp" -gt 0 ] || fail "build_legality_display produced 0 rows"
echo "[rebuild]   legality_display: $disp pieces (+ low-zoom variant)"
# Derived tables now match the swapped-in source; record that (review finding PP-6).
stamp_display_generation

# ---- 8. POST-SWAP gates -----------------------------------------------------
# The baked data already passed the golden check pre-swap; these confirm the engine and API
# agree with it. A failure here means an engine/API problem rather than bad data — the previous
# table is gone, so recovery is a re-run, not a rollback.
echo "[rebuild] Tier-A classifier fixtures…"
./scripts/run-fixtures.sh

echo "[rebuild] Tier-B golden coordinates (API: $API)…"
curl -sf -o /dev/null --max-time 5 "$API/health" \
  || fail "API not reachable at $API — start it (dotnet run --project src/OreScout.Api) and re-run: ./scripts/run-tier-b.sh"
./scripts/run-tier-b.sh "$API"

echo "[rebuild] ✓ legality layer rebuilt, gated pre-swap, swapped atomically ($base base + confirm-open rows, Tier-A+B green)"
