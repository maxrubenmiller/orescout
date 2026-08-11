#!/usr/bin/env bash
# Locking test for the parcel owner-name classifier (review finding PP-10 + the \b/\y defect
# found alongside it). Asserts scripts/etl/pull_parcels.sh's PUB_REGEX classifies representative
# owner strings correctly, evaluated by POSTGRES — the same engine that runs it in the loader, so
# the test cannot pass on a regex dialect the loader does not use. That distinction is the whole
# point here: the original regex used `\b`, which is a word boundary in PCRE and BACKSPACE in
# Postgres ARE, so ten alternatives were silently dead.
#
# Why this matters in both directions:
#   * The carve (confirm_open_<st>.sql) consumes owner_class='private'. A private parcel
#     misclassified 'public' is NOT carved, so PAD-US GREEN over it survives -> false-GREEN.
#   * The §6.4.1 validation frame treats owner_class='private' as ground truth. A public parcel
#     misclassified 'private' inflates the denominator and can report false-GREENs that are not.
# So neither direction is free, and the regex needs pinning rather than tuning by feel.
#
# Usage:  ./scripts/test/parcel_owner_regex_test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

PSQL="docker compose exec -T postgres psql -U postgres -d miningapp"

# Extract the live regex from the loader so the test can never drift from what ships.
PUB_REGEX=$(grep -m1 "^PUB_REGEX=" scripts/etl/pull_parcels.sh | sed "s/^PUB_REGEX='//; s/'$//")
[ -n "$PUB_REGEX" ] || { echo "✗ could not extract PUB_REGEX from scripts/etl/pull_parcels.sh" >&2; exit 2; }

pass=0; fail=0; fails=()

# expect|owner string      (expect: public = matches the government pattern; private = does not)
CASES=$(cat <<'EOF'
private|ESTATE OF JOHN A SMITH
private|SMITH JOHN ESTATE OF
private|ESTATE OF MARY JONES TRUST
private|REAL ESTATE OF THE ROCKIES INC
private|INTERSTATE OFFICE PARK LLC
private|SMITH RANCH LLC
private|JONES FAMILY TRUST
private|HIGH COUNTRY CATTLE CO
private|ROCKY MOUNTAIN ESTATES HOA
public|STATE OF COLORADO
public|STATE OF NEW MEXICO
public|UNITED STATES OF AMERICA
public|USA
public|US GOVT
public|BUREAU OF LAND MANAGEMENT
public|BLM
public|USDA FOREST SERVICE
public|USFS
public|CITY OF DENVER
public|TOWN OF SILVERTON
public|COUNTY OF GRANT
public|COUNTY COMMISSIONERS OF PITKIN
public|BIA
public|PUEBLO OF ACOMA
public|NAVAJO NATION
public|SOUTHERN UTE INDIAN TRIBE
public|DENVER WATER DISTRICT
public|SCHOOL DISTRICT RE-1
public|STATE LAND BOARD
public|COLORADO DIVISION OF WILDLIFE
public|NEW MEXICO GAME AND FISH
public|NATIONAL PARK SERVICE
public|BUREAU OF RECLAMATION
public|CORPS OF ENGINEERS
EOF
)

# One psql round-trip: build a VALUES list and let Postgres classify every string.
VALUES=$(printf '%s\n' "$CASES" | while IFS='|' read -r exp owner; do
  [ -n "${owner:-}" ] || continue
  printf "('%s','%s')," "$exp" "$(printf '%s' "$owner" | sed "s/'/''/g")"
done | sed 's/,$//')

OUT=$(printf '%s' "
SELECT v.exp, v.owner, CASE WHEN upper(v.owner) ~ '${PUB_REGEX}' THEN 'public' ELSE 'private' END
FROM (VALUES ${VALUES}) AS v(exp, owner);" | eval "$PSQL -tAq -F'|'") \
  || { echo "✗ regex query failed — is the stack up?" >&2; exit 1; }

while IFS='|' read -r exp owner got; do
  [ -n "${exp:-}" ] || continue
  if [ "$exp" = "$got" ]; then pass=$((pass+1))
  else fail=$((fail+1)); fails+=("$owner :: expected $exp, got $got"); fi
done <<< "$OUT"

echo
echo "parcel owner regex: $pass passed, $fail failed (of $((pass+fail)))"
for x in "${fails[@]:-}"; do [ -n "$x" ] && echo "  ✗ $x"; done
[ "$fail" -eq 0 ]
