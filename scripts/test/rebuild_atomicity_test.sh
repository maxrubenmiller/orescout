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

echo "== E. the refresh job's psql command strings actually dispatch =="
# refresh_confirm_open.sh builds its psql invocations as strings passed through `eval`. That form is
# where a stray quote or an unexpanded variable turns into a silent no-op or a hard parse error, and
# this job is expensive to exercise end-to-end (~45-60 min, it rebuilds the whole derived chain), so
# it went to review never having been run once. Dispatching each command string with EMPTY input
# proves the quoting and wiring without doing any work. This is not a substitute for a real run —
# see REFRESH_DRY_RUN=1 for that — it is the cheap check that catches the likeliest failure class.
# Precedent: a stray pair of double quotes inside a SQL comment silently truncated the
# gate_notpublic_green.sh command string and made it report "0 of 0 sampled — clean".
# shellcheck source=/dev/null
. scripts/etl/refresh_lib.sh >/dev/null 2>&1
_NEW=tiles.legality_polygons_new
for spec in \
  "carve|-v ON_ERROR_STOP=1 -v legality_tbl=${_NEW} -1 -q" \
  "lowzoom|-v ON_ERROR_STOP=1 -q -v lowzoom_tbl=tiles.legality_lowzoom_new" \
  "display|-v ON_ERROR_STOP=1 -q -v src=tiles.legality_polygons -v tgt=tiles.legality_display_new" \
  "display_lowzoom|-v ON_ERROR_STOP=1 -q -v src=tiles.legality_lowzoom -v tgt=tiles.legality_display_lowzoom_new -v cellsize=1.0"
do
  n="${spec%%|*}"; a="${spec#*|}"
  eval "$REFRESH_PSQL $a" < /dev/null >/dev/null 2>&1
  chk "refresh psql command string dispatches: $n" $?
done

# The output-property gate must also sit before the swap in both jobs — a gate that runs after the
# rows are serving reports history, not a decision.
ng_r=$(lineno "$R" 'GATE_TARGET="\$NEW" ./scripts/validation/gate_notpublic_green.sh')
[ "$ng_r" -gt 0 ] && [ "$swap_ln" -gt 0 ] && [ "$ng_r" -lt "$swap_ln" ]
chk "rebuild_legality.sh: not-public gate precedes atomic_swap (line $ng_r < $swap_ln)" $?
ng_c=$(lineno "$C" 'GATE_TARGET="\$NEW" ./scripts/validation/gate_notpublic_green.sh')
[ "$ng_c" -gt 0 ] && [ "$cswap_ln" -gt 0 ] && [ "$ng_c" -lt "$cswap_ln" ]
chk "refresh_confirm_open.sh: not-public gate precedes atomic_swap (line $ng_c < $cswap_ln)" $?

# The dry-run stop must sit BEFORE the swap, or it is not a dry run.
dry_ln=$(lineno "$C" 'if \[ "${REFRESH_DRY_RUN:-0}" = "1" \]')
[ "$dry_ln" -gt 0 ] && [ "$cswap_ln" -gt 0 ] && [ "$dry_ln" -lt "$cswap_ln" ]
chk "refresh_confirm_open.sh: DRY_RUN stop precedes atomic_swap (line $dry_ln < $cswap_ln)" $?

echo "== F. PP-33 deferral is wired safely =="
# The deferral must skip the derived rebuild AND the display stamp. Skipping the rebuild while still
# stamping would tell display_sync_check the derived tables are current when they are not — turning
# the PP-6 guard into a liar, which is strictly worse than not deferring at all.
def_ln=$(lineno "$C" 'if \[ "${ORESCOUT_DEFER_DERIVED:-0}" = "1" \]')
lz_ln=$(lineno "$C" 'build_lowzoom.sql')
[ "$def_ln" -gt 0 ] && [ "$lz_ln" -gt 0 ] && [ "$def_ln" -lt "$lz_ln" ]
chk "refresh_confirm_open.sh: defer branch precedes the derived rebuild (line $def_ln < $lz_ln)" $?

# The defer branch must exit before stamp_display_generation is reachable.
stampd_ln=$(lineno "$C" '^stamp_display_generation')
awk -v a="$def_ln" -v b="$stampd_ln" 'NR>a && NR<b && /^  exit 0$/ {found=1} END {exit !found}' "$C"
chk "refresh_confirm_open.sh: defer branch exits before stamp_display_generation (line $def_ln .. $stampd_ln)" $?

grep -q 'ORESCOUT_DEFER_DERIVED=1 ./scripts/etl/refresh_confirm_open.sh' scripts/etl/refresh_due.sh
chk "refresh_due.sh: runs per-state refreshes deferred" $?
grep -q 'stamp_display_generation' scripts/etl/refresh_due.sh
chk "refresh_due.sh: stamps the display generation after its own trailing rebuild" $?

# PP-12: the job mapping must come from the registry, not a hardcoded list of two states.
grep -q 'confirm_state_for_key' scripts/etl/refresh_due.sh
chk "refresh_due.sh: confirm-open job mapping is registry-derived (PP-12)" $?
! grep -qE '^\s*(ugrc_ut|calfire_ca)\)\s*cmd=' scripts/etl/refresh_due.sh
chk "refresh_due.sh: no hardcoded per-state confirm-open case arms remain" $?

echo
echo "rebuild atomicity (PP-8/PP-9): $pass passed, $fail failed (of $((pass+fail)))"
[ "$fail" -eq 0 ]
