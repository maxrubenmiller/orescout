#!/usr/bin/env bash
# Locking regression test for review findings PP-8 and PP-9 (legality rebuild atomicity +
# gate ordering). Runs in seconds; safe to run against a live dev DB.
#
# What it locks:
#   A. The pre-swap gate actually gates — it PASSES on the live layer and FAILS on exactly the
#      states PP-8/PP-9 produce (all confirm-open overlays reverted to GREEN, and a single
#      state's overlay vanishing). A gate that cannot fail is not a gate.
#   B. No script in the rebuild path writes the live legality table directly; every read/write
#      goes through :legality_tbl, so a rebuild can be redirected to _new.
#   C. Gates run BEFORE the swap in both jobs. This is the literal PP-9 defect (gates executed
#      after the commit that made the rows live) and the PP-8 defect (no swap at all).
#
# What it does NOT cover — stated plainly so nobody reads a green run as more than it is:
#   * No end-to-end rebuild. ./scripts/etl/rebuild_legality.sh takes ~40 min and re-runs every
#     state's confirm-open; exercising it here would make this untestable in CI. The ordering
#     and redirection are asserted structurally instead.
#   * Postgres-level swap semantics are covered by scripts/test/refresh_lib_test.sh, not here.
#
# Usage:  ./scripts/test/rebuild_atomicity_test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

PSQL="docker compose exec -T postgres psql -U postgres -d miningapp"
LIVE=tiles.legality_polygons
TMP=tiles.__pp8_test_clone

pass=0; fail=0
chk() {  # chk <description> <0|1 result>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "  ✓ $1"
  else fail=$((fail+1)); echo "  ✗ $1"; fi
}
cleanup() { $PSQL -q -c "DROP TABLE IF EXISTS ${TMP};" >/dev/null 2>&1; }
trap cleanup EXIT

# line number of the first line matching a pattern in a file, or 0
lineno() { grep -n -- "$2" "$1" 2>/dev/null | head -1 | cut -d: -f1 || echo 0; }

echo "== A. the pre-swap gate actually gates =="

./scripts/etl/gate_legality_tilebase.sh "$LIVE" >/dev/null 2>&1
chk "gate PASSES on the current live layer" $?

# PP-8's window / PP-9's total-vanish: every confirm-open overlay gone, PAD-US GREEN exposed.
cleanup
$PSQL -q -c "CREATE TABLE ${TMP} AS SELECT * FROM ${LIVE} WHERE source_key='padus';
             CREATE INDEX ON ${TMP} USING GIST (geom);" >/dev/null 2>&1
./scripts/etl/gate_legality_tilebase.sh "$TMP" >/dev/null 2>&1
[ $? -ne 0 ]; chk "gate FAILS when all confirm-open overlays revert to GREEN (PP-8 window)" $?

# PP-9's realistic case: one state under-produces and its overlay disappears.
cleanup
$PSQL -q -c "CREATE TABLE ${TMP} AS SELECT * FROM ${LIVE} WHERE source_key <> 'calfire_ca';
             CREATE INDEX ON ${TMP} USING GIST (geom);" >/dev/null 2>&1
./scripts/etl/gate_legality_tilebase.sh "$TMP" >/dev/null 2>&1
[ $? -ne 0 ]; chk "gate FAILS when a single state's overlay vanishes (PP-9 under-production)" $?
cleanup

# The gate must use the engine's predicate or it certifies something the engine doesn't do.
grep -q 'ST_Covers' scripts/etl/gate_legality_tilebase.sh
chk "gate uses ST_Covers, matching AssessmentService's Stage-1 predicate" $?

echo "== B. no rebuild-path SQL writes the live table directly =="

bare=0
for f in scripts/etl/unify.sql scripts/etl/confirm_open_*.sql; do
  [ -e "$f" ] || continue
  # strip comment lines and the default-assignment, then look for the literal table name
  if sed 's/--.*//' "$f" | grep -v 'set legality_tbl' | grep -q 'tiles\.legality_polygons'; then
    echo "     (offender: $f)"; bare=1
  fi
done
[ "$bare" -eq 0 ]; chk "unify.sql + confirm_open_*.sql reference only :legality_tbl" $?

missing=0
for f in scripts/etl/unify.sql scripts/etl/confirm_open_*.sql; do
  [ -e "$f" ] || continue
  grep -q 'legality_tbl' "$f" || { echo "     (offender: $f)"; missing=1; }
done
[ "$missing" -eq 0 ]; chk "every rebuild-path SQL file declares the :legality_tbl default" $?

echo "== C. gates run BEFORE the swap =="

R=scripts/etl/rebuild_legality.sh
swap_ln=$(lineno "$R" 'atomic_swap "\$LIVE"')
cnt_ln=$(lineno "$R" 'count_gate "\$LIVE"')
tb_ln=$(lineno "$R" 'gate_legality_tilebase.sh "\$NEW"')
[ "$swap_ln" -gt 0 ] && [ "$cnt_ln" -gt 0 ] && [ "$cnt_ln" -lt "$swap_ln" ]
chk "rebuild_legality.sh: count_gate precedes atomic_swap (line $cnt_ln < $swap_ln)" $?
[ "$swap_ln" -gt 0 ] && [ "$tb_ln" -gt 0 ] && [ "$tb_ln" -lt "$swap_ln" ]
chk "rebuild_legality.sh: tileBase gate precedes atomic_swap (line $tb_ln < $swap_ln)" $?

C=scripts/etl/refresh_confirm_open.sh
cswap_ln=$(lineno "$C" 'atomic_swap "\$LIVE"')
ctb_ln=$(lineno "$C" 'gate_legality_tilebase.sh "\$NEW"')
crow_ln=$(lineno "$C" 'rebuild produced 0 rows')
[ "$cswap_ln" -gt 0 ] && [ "$ctb_ln" -gt 0 ] && [ "$ctb_ln" -lt "$cswap_ln" ]
chk "refresh_confirm_open.sh: tileBase gate precedes atomic_swap (line $ctb_ln < $cswap_ln)" $?
[ "$cswap_ln" -gt 0 ] && [ "$crow_ln" -gt 0 ] && [ "$crow_ln" -lt "$cswap_ln" ]
chk "refresh_confirm_open.sh: 0-row gate precedes atomic_swap (line $crow_ln < $cswap_ln)" $?

# The gates must inspect the candidate table, not the live one — checking live would pass
# trivially and prove nothing (this is how PP-9 hid: the checks read already-committed rows).
grep -q 'FROM \${NEW} WHERE source_key' "$C"
chk "refresh_confirm_open.sh: 0-row gate counts rows in _new, not the live table" $?

echo "== D. the rebuild redirects every step to _new =="

grep -q 'legality_tbl="\$NEW" < scripts/etl/unify.sql' "$R"
chk "rebuild_legality.sh: unify.sql targets _new" $?
grep -q 'legality_tbl="\$NEW" < "\$f"' "$R"
chk "rebuild_legality.sh: every confirm_open_*.sql targets _new" $?
grep -q 'legality_tbl=\${NEW}' "$C"
chk "refresh_confirm_open.sh: confirm_open SQL targets _new" $?

echo
echo "rebuild atomicity (PP-8/PP-9): $pass passed, $fail failed (of $((pass+fail)))"
[ "$fail" -eq 0 ]
