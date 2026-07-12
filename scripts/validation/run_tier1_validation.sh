#!/usr/bin/env bash
# Tier-1 private-land validation runner (Pass-B design; the pre-launch zero-false-GREEN gate at
# production rigor). Prereq: staging.parcels loaded by one or more source adapters
# (scripts/etl/pull_parcels_*.sh) with owner_class mapped per source.
#
#   1. build the deterministic stratified sample (build_validation_sample.sql, default n=1500)
#   2. run every sampled parcel's interior point through the SAME most-restrictive lookup the
#      engine uses (ST_Covers; the live claims overlay only escalates, so it cannot hide GREEN)
#   3. tabulate RED / YELLOW-KNOWN / YELLOW-UNKNOWN / GREEN by state & size bucket
#   4. compute the false-GREEN rate with an exact Clopper–Pearson 95% upper bound
#      (the release-gating number; target: UB < 0.5% AND every GREEN hit individually reviewed)
#
# Exit non-zero if any GREEN hits exist (they are release-blocking until dispositioned as
# ground-truth errors or fixed). Writes the per-hit list for review.
#
# Usage:  ./scripts/validation/run_tier1_validation.sh [sample_n]
set -euo pipefail
cd "$(dirname "$0")/../.."
N="${1:-1500}"

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
q() { "${PSQL[@]}" -tAq -c "$1"; }

[ "$(q "SELECT to_regclass('staging.parcels') IS NOT NULL")" = "t" ] \
  || { echo "✗ staging.parcels missing — run the parcel adapters first (scripts/etl/pull_parcels_*.sh)" >&2; exit 2; }

echo "[tier1] parcel inventory:"
"${PSQL[@]}" -c "SELECT source_key, state, owner_class, count(*) FROM staging.parcels GROUP BY 1,2,3 ORDER BY 1,2,3;"

echo "[tier1] building stratified sample (n=${N})…"
"${PSQL[@]}" -v sample_n="$N" < scripts/validation/build_validation_sample.sql

echo "[tier1] scoring sampled parcels against the legality layer…"
"${PSQL[@]}" <<'SQL'
DROP TABLE IF EXISTS staging.validation_results;
CREATE TABLE staging.validation_results AS
SELECT s.parcel_id, s.state, s.bucket, s.source_key, s.pt,
       lr.verdict, lr.land_manager, lr.unit_nm,
       CASE WHEN lr.verdict IS NULL  THEN 'YELLOW-UNKNOWN'
            WHEN lr.verdict = 'GREEN' THEN 'GREEN'
            WHEN lr.verdict = 'YELLOW' THEN 'YELLOW-KNOWN'
            ELSE lr.verdict END AS outcome
FROM staging.validation_sample s
LEFT JOIN LATERAL (
  SELECT verdict, land_manager, unit_nm FROM tiles.legality_polygons
  WHERE ST_Covers(geom, s.pt)
  ORDER BY orescout_rank(verdict) DESC LIMIT 1
) lr ON true;
SQL

echo "=== outcomes by state ==="
"${PSQL[@]}" -c "SELECT state, outcome, count(*) FROM staging.validation_results GROUP BY 1,2 ORDER BY 1,2;"
echo "=== outcomes by size bucket ==="
"${PSQL[@]}" -c "SELECT bucket, outcome, count(*) FROM staging.validation_results GROUP BY 1,2 ORDER BY 1,2;"

total=$(q "SELECT count(*) FROM staging.validation_results")
greens=$(q "SELECT count(*) FROM staging.validation_results WHERE outcome='GREEN'")

# Exact Clopper–Pearson upper bound via binary search on the binomial CDF (pure python —
# no scipy on this machine).
ub=$(python3 - "$greens" "$total" <<'EOF'
import sys, math
k, n = int(sys.argv[1]), int(sys.argv[2])
def binom_cdf(k, n, p):
    # sum_{i=0..k} C(n,i) p^i (1-p)^(n-i), log-space for stability
    if p <= 0: return 1.0
    if p >= 1: return 0.0 if k < n else 1.0
    s = 0.0
    for i in range(0, k + 1):
        s += math.exp(math.lgamma(n+1) - math.lgamma(i+1) - math.lgamma(n-i+1)
                      + i*math.log(p) + (n-i)*math.log(1-p))
    return min(s, 1.0)
lo, hi = k / n if n else 0.0, 1.0
for _ in range(60):                       # CP upper: smallest p with CDF(k;n,p) <= alpha
    mid = (lo + hi) / 2
    if binom_cdf(k, n, mid) > 0.025: lo = mid
    else: hi = mid
print(f"{hi:.5f}")
EOF
)
echo
echo "=== FALSE-GREEN: ${greens} of ${total} (95% Clopper–Pearson upper bound: ${ub}) ==="
if [ "$greens" -gt 0 ]; then
  echo "=== GREEN hits (each is release-blocking until dispositioned) ==="
  "${PSQL[@]}" -c "SELECT parcel_id, state, bucket, land_manager, unit_nm,
                          round(ST_Y(pt)::numeric,5) AS lat, round(ST_X(pt)::numeric,5) AS lng
                   FROM staging.validation_results WHERE outcome='GREEN' ORDER BY state, parcel_id;"
  exit 1
fi
echo "✓ zero false-GREEN in the Tier-1 sample"
