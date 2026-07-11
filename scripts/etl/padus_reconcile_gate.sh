#!/usr/bin/env bash
# PAD-US release reconciliation gate (docs/DATA_REFRESH_PLAN.md §3; the #35 lesson as a runnable
# assertion). Run AFTER load_padus_gdb.sh, BEFORE rebuild_legality.sh, on every PAD-US bump.
#
# A new PAD-US release can introduce designation / manager / ownership codes the classifier has
# never seen. An unmapped code is NOT neutral: a feature whose only signals are unmapped falls
# through to manager-GREEN or to no-row — the 4.1 bump surfaced 21 new Des_Tp codes that needed
# human classification (#35), and the classifier tightening (#36) exists because "unknown earns
# GREEN" is exactly the failure mode we hunt. This gate FAILS LOUD with the named code lists;
# a human maps them in db/02_classifier.sql (red-lane) before the rebuild proceeds.
#
# Checks staging.padus_staging against the LIVE classifier functions:
#   1. Des_Tp values that contribute no signal (not in any classifier list)
#   2. Mang_Name values unknown to orescout_classify_sma
#   3. Own_Type values outside the known domain
#   4. features with NO signal at all whose manager is BLM/USFS (the GREEN-by-fallthrough set —
#      informational count; these are the acres a wrong "no signal" would silently open)
#
# Usage:  ./scripts/etl/padus_reconcile_gate.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)

[ "$("${PSQL[@]}" -tAq -c "SELECT to_regclass('staging.padus_staging') IS NOT NULL")" = "t" ] \
  || { echo "✗ staging.padus_staging missing — run load_padus_gdb.sh first" >&2; exit 2; }

fails=0

# Des_Tp codes REVIEWED AS DELIBERATELY NEUTRAL during the #35 (PAD-US 4.1) + #36 reconciliations:
# they contribute no signal ON PURPOSE — the manager/ownership decides (e.g. NF/NG/NT on USFS,
# IRA roadless, PUB on BLM). A code is only a gate failure if it is neither mapped NOR in this
# reviewed set. Adding to this list = a reviewed product decision; record it in the §9 log.
# (Cleaner future home: a neutral-set function in db/02_classifier.sql — red-lane, not done here.)
REVIEWED_NEUTRAL="'ACC','AGRE','FORE','FOTH','IRA','LCA','LOTH','LP','LREC','LRMA','MIT','ND','NF','NG','NLS','NT','OTHE','PAGR','PCON','PHCA','POTH','PPRK','PRAN','PREC','PROC','PUB','RECE','SOTH','SREC','SRMA','UNK','WPA'"

echo "=== 1. Des_Tp codes neither mapped nor reviewed-neutral (must be empty) ==="
out=$("${PSQL[@]}" -tAq -c "
SELECT DISTINCT upper(des_tp) FROM staging.padus_staging s
WHERE des_tp IS NOT NULL
  AND (SELECT verdict FROM orescout_classify_padus(s.des_tp, NULL, NULL)) IS NULL
  AND upper(des_tp) NOT IN (${REVIEWED_NEUTRAL})
ORDER BY 1;")
if [ -n "$out" ]; then
  echo "$out" | sed 's/^/  UNMAPPED Des_Tp: /'
  echo "  → map these in db/02_classifier.sql (designation lists) — red-lane, needs owner sign-off"
  fails=$((fails+1))
else echo "  ok — every designation code maps"; fi

echo "=== 2. Mang_Name codes unknown to the manager classifier (must be empty) ==="
out=$("${PSQL[@]}" -tAq -c "
SELECT DISTINCT upper(mang_name) FROM staging.padus_staging s
WHERE mang_name IS NOT NULL
  AND (SELECT verdict FROM orescout_classify_sma(s.mang_name)) IS NULL
ORDER BY 1;")
if [ -n "$out" ]; then
  echo "$out" | sed 's/^/  UNMAPPED Mang_Name: /'
  echo "  → map these in db/02_classifier.sql (orescout_classify_sma) — red-lane"
  fails=$((fails+1))
else echo "  ok — every manager code maps"; fi

echo "=== 3. Own_Type codes outside the known domain (must be empty) ==="
out=$("${PSQL[@]}" -tAq -c "
SELECT DISTINCT upper(own_type) FROM staging.padus_staging
WHERE own_type IS NOT NULL
  AND upper(own_type) NOT IN ('PVT','TRIB','UNK','LOC','FED','DESG','DIST','JNT','NGO','STAT')
ORDER BY 1;")
if [ -n "$out" ]; then
  echo "$out" | sed 's/^/  NEW Own_Type: /'
  echo "  → decide RED (private-like) / YELLOW (weak) / neutral in db/02_classifier.sql — red-lane"
  fails=$((fails+1))
else echo "  ok — ownership domain unchanged"; fi

echo "=== 4. informational: no-signal features under BLM/USFS management ==="
"${PSQL[@]}" -c "
SELECT count(*) AS features, round(sum(ST_Area(geom::geography))/1e6) AS km2
FROM staging.padus_staging s
CROSS JOIN LATERAL orescout_base_verdict(s.des_tp, s.own_type, s.gap_sts, s.mang_name) bv
WHERE bv.verdict = 'GREEN';"

echo
if [ "$fails" -gt 0 ]; then
  echo "✗ reconciliation gate FAILED ($fails class(es) of unmapped codes) — do NOT run the rebuild until mapped" >&2
  exit 1
fi
echo "✓ reconciliation gate passed — safe to run ./scripts/etl/rebuild_legality.sh"
