#!/usr/bin/env bash
# The dev-side "run whatever's past due" entry point (docs/DATA_REFRESH_PLAN.md §2.4).
# Reads the freshness registry, runs the Class-1/2 job for each stale source, and PRINTS the
# human runbook pointer for stale Class-3 sources (never auto-runs a versioned-release bump).
# In prod the scheduler runs the individual jobs directly; this wrapper is the laptop cadence.
#
# Usage:  ./scripts/etl/refresh_due.sh [--dry-run]
#
# JOB MAPPING IS REGISTRY-DERIVED (review finding PP-12). This used to be a hardcoded case block
# listing only ugrc_ut and calfire_ca, so the six SMA confirm-open sources fell through to
# "no job mapping" even though refresh_confirm_open.sh handles all eight states identically. That
# contradicted the §6.13 one-entry-per-state invariant: adding a state to the registry was supposed
# to be sufficient, and here it silently was not. The confirm-open state list now comes from
# reg_states_for_role, so a newly added state is scheduled the moment its registry entry exists.
#
# DERIVED-CHAIN BATCHING (review finding PP-33). tiles.legality_lowzoom and both display tables are
# global — derived from the whole legality layer, not per state — so a per-state refresh must
# rebuild all of them. Letting each state do that means N rebuilds with the first N-1 discarded
# (~25 min each; all 8 states would be ~3.3 h, ~2.9 h of it wasted). This wrapper therefore runs
# every confirm-open job with ORESCOUT_DEFER_DERIVED=1 and rebuilds the chain ONCE at the end.
# Between those points the generation stamps disagree on purpose and display_sync_check.sh check A
# fails — that is the PP-6 guard doing its job, not a bug. If this script dies before the trailing
# rebuild, that check is what tells you.
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/refresh_lib.sh
source scripts/etl/registry_lib.sh
DRY="${1:-}"

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
stale_keys=$("${PSQL[@]}" -tAq -c "
SELECT source_key FROM public.data_sources
WHERE max_age_days IS NOT NULL
  AND (refreshed_at IS NULL OR refreshed_at < now() - make_interval(days => max_age_days))
ORDER BY source_key;")

if [ -z "$stale_keys" ]; then
  echo "✓ nothing due — all refreshable sources within their max age"
  ./scripts/test/freshness_check.sh >/dev/null && exit 0
fi

# source_key -> state, for every confirm-open source the registry knows about.
confirm_state_for_key() {
  local want="$1" st k
  for st in $(reg_states_for_role confirm_open); do
    k=$(reg_key_for_state_role "$st" confirm_open 2>/dev/null) || continue
    [ "$k" = "$want" ] && { echo "$st"; return 0; }
  done
  return 1
}

rc=0
confirm_ran=0
for key in $stale_keys; do
  cmd=""
  if [ "$key" = "mlrs_claims" ]; then
    cmd="./scripts/etl/refresh_claims.sh"
  elif st=$(confirm_state_for_key "$key"); then
    # Deferred: the derived chain is rebuilt once after the loop (PP-33).
    cmd="ORESCOUT_DEFER_DERIVED=1 ./scripts/etl/refresh_confirm_open.sh $(echo "$st" | tr '[:upper:]' '[:lower:]')"
  else
    case "$key" in
      padus)  echo "⚠ $key is due — Class-3, human-approved: see docs/DATA_REFRESH_PLAN.md §3 (PAD-US runbook)"; continue ;;
      ngdb_prospectivity|wbd)
              echo "⚠ $key is due — Class-3, human-approved: NGDB+WBD move together; see docs/DATA_REFRESH_PLAN.md §3"; continue ;;
      *)      echo "⚠ $key is due but has no job mapping — add it here"; rc=1; continue ;;
    esac
  fi

  if [ "$DRY" = "--dry-run" ]; then
    echo "would run: $cmd   (source: $key)"
    case "$cmd" in *refresh_confirm_open*) confirm_ran=1 ;; esac
  else
    echo "=== running: $cmd (source: $key) ==="
    if eval "$cmd"; then
      case "$cmd" in *refresh_confirm_open*) confirm_ran=1 ;; esac
    else
      echo "✗ $key refresh FAILED (previous data still live)" >&2; rc=1
    fi
  fi
done

# ---- trailing derived rebuild, ONCE (PP-33) ---------------------------------
# Only when a confirm-open job actually swapped new rows in; the claims refresh has its own table
# and does not invalidate the legality display chain.
if [ "$confirm_ran" = "1" ]; then
  if [ "$DRY" = "--dry-run" ]; then
    echo "would run: derived display rebuild ONCE (lowzoom + display + display_lowzoom, then stamp)"
  else
    echo
    echo "=== rebuilding the derived display chain once for all refreshed states (PP-33) ==="
    derived_ok=1
    "${PSQL[@]}" -v lowzoom_tbl=tiles.legality_lowzoom_new < scripts/etl/build_lowzoom.sql >/dev/null \
      && count_gate tiles.legality_lowzoom 40 && atomic_swap tiles.legality_lowzoom || derived_ok=0
    if [ "$derived_ok" = "1" ]; then
      "${PSQL[@]}" -v src=tiles.legality_polygons -v tgt=tiles.legality_display_new \
        < scripts/etl/build_legality_display.sql >/dev/null \
        && count_gate tiles.legality_display 40 && atomic_swap tiles.legality_display || derived_ok=0
    fi
    if [ "$derived_ok" = "1" ]; then
      "${PSQL[@]}" -v src=tiles.legality_lowzoom -v tgt=tiles.legality_display_lowzoom_new -v cellsize=1.0 \
        < scripts/etl/build_legality_display.sql >/dev/null \
        && count_gate tiles.legality_display_lowzoom 40 && atomic_swap tiles.legality_display_lowzoom || derived_ok=0
    fi
    if [ "$derived_ok" = "1" ]; then
      stamp_display_generation
    else
      echo "✗ derived display rebuild FAILED — legality_polygons is current but the MAP IS STALE." >&2
      echo "  The generation stamps now disagree; ./scripts/test/display_sync_check.sh will say so." >&2
      echo "  Recover with: ./scripts/etl/rebuild_legality.sh (or re-run this script)." >&2
      rc=1
    fi
  fi
fi

echo
./scripts/test/freshness_check.sh || rc=1
exit $rc
