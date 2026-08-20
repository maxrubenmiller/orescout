#!/usr/bin/env bash
# Locking test for the parcel owner-name classifier (review finding PP-10 + the \b/\y defect
# found alongside it). Asserts scripts/etl/pull_parcels.sh's PUB_REGEX classifies representative
# owner strings correctly, evaluated by POSTGRES — the same engine that runs it in the loader, so
# the test cannot pass on a regex dialect the loader does not use. That distinction is the whole
# point here: the original regex used `\b`, which is a word boundary in PCRE and BACKSPACE in
# Postgres ARE, so ten alternatives were silently dead.
#
# Why this matters in both directions:
#   * The carve consumes owner_class <> 'federal' (PP-32). Anything wrongly classed 'federal' is
#     NOT carved, so PAD-US GREEN over it survives -> false-GREEN. That is the dangerous direction.
#   * The §6.4.1 validation frame treats owner_class='private' as ground truth. A public parcel
#     wrongly classed 'private' inflates the denominator and can report false-GREENs that are not.
# So neither direction is free, and the regexes need pinning rather than tuning by feel.
#
# ORDERING IS LOAD-BEARING. OTHERPUB is tested before FED because names like
# "UNITED STATES BUREAU OF INDIAN AFFAIRS" match both, and tribal land must never resolve to the
# class that confirms open. The last three cases below exist solely to pin that tie-break.
#
# Usage:  ./scripts/test/parcel_owner_regex_test.sh
set -uo pipefail
cd "$(dirname "$0")/../.."

PSQL="docker compose exec -T postgres psql -U postgres -d miningapp"

# Extract the live regexes from the loader so the test can never drift from what ships.
OTHERPUB_REGEX=$(grep -m1 "^OTHERPUB_REGEX=" scripts/etl/pull_parcels.sh | sed "s/^OTHERPUB_REGEX='//; s/'$//")
FED_REGEX=$(grep -m1 "^FED_REGEX=" scripts/etl/pull_parcels.sh | sed "s/^FED_REGEX='//; s/'$//")
[ -n "$OTHERPUB_REGEX" ] && [ -n "$FED_REGEX" ] \
  || { echo "✗ could not extract OTHERPUB_REGEX/FED_REGEX from scripts/etl/pull_parcels.sh" >&2; exit 2; }

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
federal|UNITED STATES OF AMERICA
federal|USA
federal|US GOVT
federal|BUREAU OF LAND MANAGEMENT
federal|BLM
federal|USDA FOREST SERVICE
federal|USFS
federal|NATIONAL PARK SERVICE
federal|BUREAU OF RECLAMATION
federal|CORPS OF ENGINEERS
federal|US DEPARTMENT OF THE INTERIOR
other_public|STATE OF COLORADO
other_public|STATE OF NEW MEXICO
other_public|CITY OF DENVER
other_public|TOWN OF SILVERTON
other_public|COUNTY OF GRANT
other_public|COUNTY COMMISSIONERS OF PITKIN
other_public|DENVER WATER DISTRICT
other_public|SCHOOL DISTRICT RE-1
other_public|STATE LAND BOARD
other_public|COLORADO DIVISION OF WILDLIFE
other_public|NEW MEXICO GAME AND FISH
other_public|BIA
other_public|PUEBLO OF ACOMA
other_public|NAVAJO NATION
other_public|SOUTHERN UTE INDIAN TRIBE
other_public|UNITED STATES BUREAU OF INDIAN AFFAIRS
other_public|US DEPARTMENT OF THE INTERIOR BUREAU OF INDIAN AFFAIRS
other_public|PUBLIC LANDS TRUST
EOF
)

# One psql round-trip: build a VALUES list and let Postgres classify every string.
VALUES=$(printf '%s\n' "$CASES" | while IFS='|' read -r exp owner; do
  [ -n "${owner:-}" ] || continue
  printf "('%s','%s')," "$exp" "$(printf '%s' "$owner" | sed "s/'/''/g")"
done | sed 's/,$//')

OUT=$(printf '%s' "
SELECT v.exp, v.owner,
       CASE WHEN v.owner IS NULL OR btrim(v.owner) = '' THEN 'unknown'
            WHEN upper(v.owner) ~ '${OTHERPUB_REGEX}' THEN 'other_public'
            WHEN upper(v.owner) ~ '${FED_REGEX}'      THEN 'federal'
            ELSE 'private' END
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
