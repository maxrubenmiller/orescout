#!/usr/bin/env bash
# The dev-side "run whatever's past due" entry point (docs/DATA_REFRESH_PLAN.md §2.4).
# Reads the freshness registry, runs the Class-1/2 job for each stale source, and PRINTS the
# human runbook pointer for stale Class-3 sources (never auto-runs a versioned-release bump).
# In prod the scheduler runs the individual jobs directly; this wrapper is the laptop cadence.
#
# Usage:  ./scripts/etl/refresh_due.sh [--dry-run]
set -uo pipefail
cd "$(dirname "$0")/../.."
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

rc=0
for key in $stale_keys; do
  case "$key" in
    mlrs_claims)        cmd="./scripts/etl/refresh_claims.sh" ;;
    ugrc_ut)            cmd="./scripts/etl/refresh_confirm_open.sh ut" ;;
    calfire_ca)         cmd="./scripts/etl/refresh_confirm_open.sh ca" ;;
    padus)              echo "⚠ $key is due — Class-3, human-approved: see docs/DATA_REFRESH_PLAN.md §3 (PAD-US runbook)"; continue ;;
    ngdb_prospectivity|wbd)
                        echo "⚠ $key is due — Class-3, human-approved: NGDB+WBD move together; see docs/DATA_REFRESH_PLAN.md §3"; continue ;;
    *)                  echo "⚠ $key is due but has no job mapping — add it here"; rc=1; continue ;;
  esac
  if [ "$DRY" = "--dry-run" ]; then
    echo "would run: $cmd   (source: $key)"
  else
    echo "=== running: $cmd (source: $key) ==="
    $cmd || { echo "✗ $key refresh FAILED (previous data still live)" >&2; rc=1; }
  fi
done

echo
./scripts/test/freshness_check.sh || rc=1
exit $rc
