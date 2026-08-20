#!/usr/bin/env bash
# Registry-vs-committed-SQL drift gate (review finding PP-12).
#
# etl/sources.json claims to be the single source of truth, but for the six sql:"generated" states
# the pipeline executes the COMMITTED scripts/etl/confirm_open_<st>.sql. Nothing verified those two
# agreed: refresh_confirm_open.sh only checked the file EXISTS, and registry_roundtrip.sh compares
# the registry against string literals hardcoded inside the test itself — it proves the Phase-0
# transcription was faithful, not that the SQL being run today matches the registry.
#
# Two ways that bites:
#   * a registry edit does nothing until someone remembers to re-run gen_confirm_open.sh, so the
#     pipeline quietly executes stale parameters;
#   * a hand-edit to a generated file survives indefinitely, and the header comment saying
#     "GENERATED ... edit the generator, not this file" is the only thing standing in its way.
#
# This regenerates each generated state into a temp dir and diffs against the committed file.
# It never writes to scripts/etl — GEN_OUT_DIR keeps the committed files untouched even on failure.
#
# Usage:  ./scripts/test/gen_drift_check.sh
set -uo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

TMP="${TMPDIR:-/tmp}/orescout_gendrift_$$"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0; drifted=""

# Only sql:"generated" sources are checked. CA and UT are committed bespoke files by design and
# have no generator to compare against — that is a documented exception, not an omission.
n=0
for st in $(reg_states_for_role confirm_open); do
  key=$(reg_key_for_state_role "$st" confirm_open) || continue
  [ "$(reg_sql "$key")" = "generated" ] || continue
  n=$((n+1))
  stl=$(echo "$st" | tr '[:upper:]' '[:lower:]')
  committed="scripts/etl/confirm_open_${stl}.sql"

  if [ ! -f "$committed" ]; then
    echo "  ✗ $st: $committed missing — run ./scripts/etl/gen_confirm_open.sh $stl"
    fail=$((fail+1)); drifted="$drifted $st"; continue
  fi
  if ! GEN_OUT_DIR="$TMP" ./scripts/etl/gen_confirm_open.sh "$stl" >/dev/null 2>&1; then
    echo "  ✗ $st: generator failed (missing registry field? see docs/ADD_A_STATE.md)"
    fail=$((fail+1)); drifted="$drifted $st"; continue
  fi
  if diff -q "$TMP/confirm_open_${stl}.sql" "$committed" >/dev/null 2>&1; then
    echo "  ✓ $st: committed SQL matches the registry"
    pass=$((pass+1))
  else
    echo "  ✗ $st: DRIFT — committed SQL does not match what the registry generates"
    diff -u "$committed" "$TMP/confirm_open_${stl}.sql" | sed -n '1,25p' | sed 's/^/        /'
    fail=$((fail+1)); drifted="$drifted $st"
  fi
done

# A run that checked nothing must not read as a pass — the recurring 0-of-0 trap in this project.
if [ "$n" -eq 0 ]; then
  echo "  ✗ BROKEN: no sql:'generated' sources found in the registry; nothing was checked" >&2
  exit 1
fi

echo
echo "gen drift: $pass matched, $fail drifted (of $n generated states)"
if [ "$fail" -ne 0 ]; then
  echo "  DRIFTED:$drifted"
  echo "  Fix by regenerating (./scripts/etl/gen_confirm_open.sh <st>) and reviewing the diff —"
  echo "  or by correcting etl/sources.json if the committed file is the one that is right."
  exit 1
fi
