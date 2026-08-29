#!/usr/bin/env bash
# PP-36: every carve, and the cross-border sweep, must threshold the SOURCE PARCEL — not the
# fragment it happened to be cut into.
#
# WHY THIS TEST EXISTS. PP-1/PP-18 already "fixed" this once by lowering the threshold from 1000 to
# 400 m² for notpub-overlapping fragments. That moved the edge without changing the BASIS, so the
# bug survived at a smaller scale: ST_Subdivide(...,256) chunk lines and the 100 m buffer edge cut a
# large private parcel into pieces, and a piece can measure less than the floor while the parcel it
# belongs to is enormous. Measured on ID (42.031603, -115.564597): a 366 m² fragment whose
# notpub_m2 was also 366 — under both tests — carved off a parcel of 667,003 m² that sma_id maps
# PRIVATE. Dropped, and the app served GREEN there.
#
# It is also the reason gate_notpublic_green.sh and the carve disagreed and the residuals looked
# unexplained for so long: the gate selects SOURCE polygons >= 400 m² (it judges the parcel) while
# the carve judged the fragment. Same number, different subject.
#
# A threshold on a fragment is a threshold on an artifact of how the geometry was chopped. If
# someone "simplifies" these predicates back to fragment-only, that is a silent safety regression
# with no failing fixture anywhere else — hence this test.
set -uo pipefail
cd "$(dirname "$0")/.."/..

pass=0; fail=0

check() { # file, needle, description
  if grep -q -- "$2" "$1" 2>/dev/null; then
    echo "  ✓ $(basename "$1"): $3"; pass=$((pass+1))
  else
    echo "  ✗ $(basename "$1"): MISSING $3"; fail=$((fail+1))
  fi
}

echo "== carve files threshold the source parcel, not just the fragment =="
n=0
for f in scripts/etl/confirm_open_*.sql; do
  [ -f "$f" ] || continue
  n=$((n+1))
  check "$f" "notpub_src_m2" "computes notpub_src_m2 (source-polygon area)"
  check "$f" "OR d.notpub_src_m2  > 400" "keeps fragments whose SOURCE parcel clears the floor"
done

# A loop that iterated over nothing must not read as a pass — the recurring 0-of-0 trap here.
if [ "$n" -eq 0 ]; then
  echo "  ✗ BROKEN: no scripts/etl/confirm_open_*.sql found; nothing was checked" >&2; exit 1
fi
echo "  ($n carve files checked)"

echo "== the generator emits it, so regenerated states cannot silently lose it =="
check scripts/etl/gen_confirm_open.sh "notpub_src_m2" "template computes the source-polygon area"
check scripts/etl/gen_confirm_open.sh 'OR d.notpub_src_m2  > 400' "template keeps source-parcel fragments"

echo "== the cross-border sweep has the same basis =="
check scripts/etl/sweep_crossborder.sh "ST_Area(np.geom::geography) AS src_m2" "carries the source parcel area"
check scripts/etl/sweep_crossborder.sh 'OR d.src_m2 > ${FLOOR}' "floors on the parcel, not just the overlap"

echo
echo "pp36 parcel basis: $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
