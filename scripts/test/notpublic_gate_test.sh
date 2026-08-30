#!/usr/bin/env bash
# Locking test for scripts/validation/gate_notpublic_green.sh — the output-property gate.
#
# The property under test is not "does the gate pass today" but "can the gate FAIL". This session
# produced a version of this very gate that reported
#     ✓ CA clean: 0 above the 400 m2 floor (0 raw) of 0 sampled
# for all eight states and exited 0, because a stray pair of double quotes truncated its SQL. A
# safety gate that cannot fail is worse than no gate: it launders an unknown as a green tick.
#
# Runtime ~2-4 min: proving a regression is caught requires one real state sweep. NV is used because
# it is the fastest state with a NON-ZERO baseline, which is what makes a forced regression possible.
#
# Usage:  ./scripts/test/notpublic_gate_test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

GATE=./scripts/validation/gate_notpublic_green.sh
BASE=db/fixtures/notpublic_baseline.json
TMP="${TMPDIR:-/tmp}/orescout_gate_test_$$"
mkdir -p "$TMP"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass=0; fail=0
chk() { if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "  ✓ $1"; else fail=$((fail+1)); echo "  ✗ $1"; fi; }

echo "== A. the baseline file is well-formed and complete =="

python3 -c "
import json,sys
d=json.load(open('$BASE'))
assert isinstance(d.get('states'), dict) and d['states'], 'no states map'
assert all(isinstance(v,int) and v>=0 for v in d['states'].values()), 'non-integer or negative count'
" 2>/dev/null
chk "baseline parses and holds non-negative integer counts" $?

# Every confirm-open state should be represented, so a missing entry is a deliberate zero rather
# than an oversight that silently holds a state to zero it cannot meet.
# shellcheck source=/dev/null
. scripts/etl/registry_lib.sh
STATES_LIST=$(reg_states_for_role confirm_open | tr '\n' ' ')
n_states=$(printf '%s' "$STATES_LIST" | wc -w | tr -d ' ')
# An empty list would make the loop below vacuously pass — the same 0-of-0 trap that produced a
# false clean run earlier in this project. Assert we actually enumerated states.
[ "${n_states:-0}" -ge 8 ]
chk "registry enumerated the confirm_open states (got ${n_states:-0}, expect >=8)" $?

missing=""
for st in $STATES_LIST; do
  python3 -c "
import json,sys
sys.exit(0 if '$st' in json.load(open('$BASE'))['states'] else 1)" 2>/dev/null || missing="$missing $st"
done
[ -z "$missing" ] && [ "${n_states:-0}" -ge 8 ]
chk "every confirm_open state has a baseline entry (missing:${missing:-none})" $?

echo "== B. the gate refuses to score something that is not there =="
GATE_TARGET=tiles.__definitely_not_a_table $GATE nv >/dev/null 2>&1
[ $? -eq 2 ]
chk "nonexistent target table exits 2 rather than sweeping nothing" $?

echo "== C. the gate FAILS on a regression past baseline =="
# Pick the state with the LARGEST recorded residual and hold it to zero. This used to hardcode NV,
# which broke the moment NV was actually fixed (PP-36 took it 1 -> 0): forcing a baseline of 0 on a
# state that genuinely has 0 produces no regression, and three checks failed for a GOOD reason.
# Deriving the state keeps this a real measurement against a stricter bar rather than a fixture that
# silently rots every time the pipeline improves.
RS=$(python3 -c "
import json;d=json.load(open('$BASE'))['states']
k=max(d,key=lambda x:d[x])
print(k if d[k]>0 else '')")
if [ -z "$RS" ]; then
  # Genuinely wonderful, and genuinely untestable this way. Say so instead of passing vacuously.
  echo "  ✗ BROKEN: every state's baseline is 0, so regression detection cannot be exercised."
  echo "    Rewrite C/D against a synthetic baseline of -1, or retire them." >&2
  fail=$((fail+1))
else
  rsl=$(echo "$RS" | tr '[:upper:]' '[:lower:]')
  python3 -c "
import json
d=json.load(open('$BASE')); d['states']['$RS']=0
json.dump(d, open('$TMP/zero.json','w'))"
  GATE_BASELINE="$TMP/zero.json" $GATE "$rsl" > "$TMP/regress.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ]
  chk "exits non-zero when $RS exceeds a baseline of 0 (got exit $rc)" $?
  grep -q 'REGRESSION' "$TMP/regress.out"
  chk "reports the word REGRESSION with the delta" $?
  grep -q 'REGRESSED STATES' "$TMP/regress.out"
  chk "names the regressed state in the summary" $?

  echo "== D. the gate PASSES at its recorded baseline =="
  $GATE "$rsl" > "$TMP/atbase.out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ]
  chk "exits 0 when $RS is at its recorded baseline (got exit $rc)" $?
  grep -q 'at baseline' "$TMP/atbase.out"
  chk "reports 'at baseline' rather than a clean pass, so the residual stays visible" $?
fi

echo
echo "not-public gate: $pass passed, $fail failed (of $((pass+fail)))"
[ "$fail" -eq 0 ]
