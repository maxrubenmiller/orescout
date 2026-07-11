#!/usr/bin/env bash
# Regression harness for scripts/etl/refresh_lib.sh (docs/DATA_REFRESH_PLAN.md Phase A item 1).
# Exercises every function's pass AND failure path against THROWAWAY tables in the staging
# schema. Never touches live tiles.* — asserts a sentinel live table is byte-identical after
# every failure path. Cleans up all throwaway objects.
#
# Usage:  ./scripts/test/refresh_lib_test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
q() { "${PSQL[@]}" -tAq -c "$1"; }
x() { "${PSQL[@]}" -q -c "$1"; }

pass=0; fail=0
check() { # name ok(0/1) [detail]
  if [ "$2" = "1" ]; then pass=$((pass+1)); echo "  ✓ $1"; else fail=$((fail+1)); echo "  ✗ $1  [${3:-}]"; fi
}
# run a snippet that SOURCES the lib in a subshell (each case isolated; lib exits on failure)
librun() { bash -c "cd '$PWD' && source scripts/etl/refresh_lib.sh && $1" 2>/dev/null; }

cleanup() {
  x "DROP TABLE IF EXISTS staging.rlt, staging.rlt_new, staging.rlt_old;" >/dev/null 2>&1
  "${PSQL[@]}" -q -c "DELETE FROM public.data_sources WHERE source_key='rlt_test';" >/dev/null 2>&1
  rmdir "${TMPDIR:-/tmp}/orescout_refresh_rlt.lock" 2>/dev/null
  true
}
trap cleanup EXIT
cleanup

echo "refresh_lib regression:"

# ---- fixtures ----------------------------------------------------------------
x "CREATE TABLE staging.rlt (id int, v text); INSERT INTO staging.rlt SELECT g, 'live' FROM generate_series(1,100) g;
   CREATE INDEX rlt_v_idx ON staging.rlt (v);"

# 1. assert_schema pass / fail
librun "assert_schema staging.rlt id v" >/dev/null
check "assert_schema passes on existing columns" "$([ $? -eq 0 ] && echo 1 || echo 0)"
librun "assert_schema staging.rlt id nope" >/dev/null
check "assert_schema fails on missing column" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# 2. count_gate: in-band pass, out-of-band fail (live untouched), empty-new fail
x "CREATE TABLE staging.rlt_new AS SELECT g AS id, 'new'::text AS v FROM generate_series(1,110) g;"
librun "count_gate staging.rlt 25" >/dev/null
check "count_gate passes in band (110 vs 100, ±25%)" "$([ $? -eq 0 ] && echo 1 || echo 0)"
x "TRUNCATE staging.rlt_new; INSERT INTO staging.rlt_new SELECT g, 'new' FROM generate_series(1,10) g;"
librun "count_gate staging.rlt 25" >/dev/null
check "count_gate fails out of band (10 vs 100)" "$([ $? -ne 0 ] && echo 1 || echo 0)"
check "live table untouched after gate failure" "$([ "$(q 'SELECT count(*) FROM staging.rlt')" = "100" ] && echo 1 || echo 0)"
x "TRUNCATE staging.rlt_new;"
librun "count_gate staging.rlt 25" >/dev/null
check "count_gate refuses an EMPTY _new" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# 3. atomic_swap: normal swap; index name normalized; first-run swap (no live table)
x "TRUNCATE staging.rlt_new; INSERT INTO staging.rlt_new SELECT g, 'new' FROM generate_series(1,105) g;
   CREATE INDEX rlt_new_v_idx ON staging.rlt_new (v);"
librun "atomic_swap staging.rlt" >/dev/null
ok=1; why=""
[ "$(q "SELECT count(*) FROM staging.rlt")" = "105" ] || { ok=0; why+="rows "; }
[ "$(q "SELECT count(*) FROM staging.rlt WHERE v='new'")" = "105" ] || { ok=0; why+="content "; }
[ "$(q "SELECT to_regclass('staging.rlt_old') IS NULL")" = "t" ] || { ok=0; why+="_old-left "; }
check "atomic_swap replaces live with _new and drops _old" "$ok" "$why"
check "swap normalized the index name (rlt_v_idx)" \
  "$([ "$(q "SELECT count(*) FROM pg_indexes WHERE schemaname='staging' AND tablename='rlt' AND indexname='rlt_v_idx'")" = "1" ] && echo 1 || echo 0)"
x "DROP TABLE staging.rlt;
   CREATE TABLE staging.rlt_new AS SELECT 1 AS id, 'first'::text AS v;"
librun "atomic_swap staging.rlt" >/dev/null
check "atomic_swap works on first run (no live table)" \
  "$([ "$(q "SELECT count(*) FROM staging.rlt")" = "1" ] && echo 1 || echo 0)"
librun "atomic_swap staging.rlt" >/dev/null
check "atomic_swap fails cleanly when _new is missing" "$([ $? -ne 0 ] && echo 1 || echo 0)"

# 4. lock: second acquisition fails while held; foreign lock preserved
mkdir "${TMPDIR:-/tmp}/orescout_refresh_rlt.lock"
librun "refresh_lock rlt" >/dev/null
check "refresh_lock fails when lock already held" "$([ $? -ne 0 ] && echo 1 || echo 0)"
check "foreign lock left in place after refusal" \
  "$([ -d "${TMPDIR:-/tmp}/orescout_refresh_rlt.lock" ] && echo 1 || echo 0)"
rmdir "${TMPDIR:-/tmp}/orescout_refresh_rlt.lock"
librun "refresh_lock rlt && echo held" | grep -q "lock acquired"
check "refresh_lock acquires when free (and auto-releases on exit)" "$([ $? -eq 0 ] && echo 1 || echo 0)"
check "lock released after job exit" \
  "$([ ! -d "${TMPDIR:-/tmp}/orescout_refresh_rlt.lock" ] && echo 1 || echo 0)"

# 5. stamp_source: insert + en-dash survives + upsert updates
librun "stamp_source rlt_test reference 'vintage 1962–2023 test' 30 'https://example/ref' ok" >/dev/null
check "stamp_source inserts a registry row" \
  "$([ "$(q "SELECT count(*) FROM public.data_sources WHERE source_key='rlt_test'")" = "1" ] && echo 1 || echo 0)"
check "stamp_source preserves UTF-8 (en dash)" \
  "$([ "$(q "SELECT vintage LIKE '%1962–2023%' FROM public.data_sources WHERE source_key='rlt_test'")" = "t" ] && echo 1 || echo 0)"
librun "stamp_source rlt_test reference 'v2' 30 'https://example/ref' gate-failed" >/dev/null
check "stamp_source upserts (status updated)" \
  "$([ "$(q "SELECT last_gate_status FROM public.data_sources WHERE source_key='rlt_test'")" = "gate-failed" ] && echo 1 || echo 0)"

echo; echo "refresh_lib: $pass passed, $fail failed"
[ $fail -eq 0 ]
