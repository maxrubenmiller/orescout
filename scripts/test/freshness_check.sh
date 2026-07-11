#!/usr/bin/env bash
# Freshness gate over the data-source registry (docs/DATA_REFRESH_PLAN.md §2.2).
# Prints the registry table; exits non-zero if any source is STALE (older than its max_age_days)
# or its last refresh gate FAILED. Diag-suite member on dev; the alert hook in prod.
#
# Usage:  ./scripts/test/freshness_check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)

"${PSQL[@]}" -c "
SELECT source_key, role, refreshed_at::date AS refreshed, max_age_days AS max_age,
       last_gate_status AS gate,
       CASE WHEN max_age_days IS NULL THEN 'static'
            WHEN refreshed_at IS NULL THEN 'UNKNOWN'
            WHEN refreshed_at < now() - make_interval(days => max_age_days) THEN 'STALE'
            ELSE 'fresh' END AS freshness
FROM public.data_sources ORDER BY source_key;" || exit 2

bad=$("${PSQL[@]}" -tAq -c "
SELECT count(*) FROM public.data_sources
WHERE (max_age_days IS NOT NULL AND (refreshed_at IS NULL OR refreshed_at < now() - make_interval(days => max_age_days)))
   OR coalesce(last_gate_status,'ok') NOT IN ('ok');")

if [ "$bad" -gt 0 ]; then
  echo "✗ freshness: $bad source(s) stale or gate-failed — run ./scripts/etl/refresh_due.sh" >&2
  exit 1
fi
echo "✓ freshness: all refreshable sources within their max age, all gates ok"
