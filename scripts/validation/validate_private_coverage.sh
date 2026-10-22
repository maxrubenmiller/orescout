#!/usr/bin/env bash
# POC private-land coverage validation (docs/planning/PROJECT_PLAN.md §6.4.1).
#
# Hunts for FALSE-GREEN on known-private land (the trespass-risk defect; zero-tolerance).
# Ground truth = curated known private inholdings (independent of PAD-US — see §6.4.1).
# Each point is run through the legality engine via the most-restrictive base-verdict lookup
# against tiles.legality_polygons (identical to the API's base verdict; the live-claims overlay
# only ever ESCALATES, so it cannot create or hide a false-GREEN). Outcomes:
#   RED / YELLOW-KNOWN (mapped designation) / YELLOW-UNKNOWN (no polygon) / GREEN (DEFECT).
# Writes the ground-truth set to db/fixtures/private-points.json.
set -euo pipefail
cd "$(dirname "$0")/../.."
OUT="db/fixtures/private-points.json"
NOM="https://nominatim.openstreetmap.org/search"
UA="OreScout-Validation/0.1 (maxrubenmiller@gmail.com)"

# id|geocode-query|state|note   (#15 uses the provided coordinate, appended after the loop)
PLACES=(
"1|Idyllwild, California, USA|CA|San Bernardino NF inholding"
"2|Wrightwood, California, USA|CA|Angeles/San Bernardino NF inholding"
"3|Greer, Arizona, USA|AZ|Apache-Sitgreaves NF inholding"
"4|Strawberry, Arizona, USA|AZ|Tonto NF inholding"
"5|Ward, Colorado, USA|CO|Roosevelt NF inholding"
# 6 (Alta) moved to a FIXED coordinate below (IMP-01): the Nominatim town centroid lands on
#   land Utah SGID maps as Federal/USFS (0 m), i.e. NOT known-private — a bad ground-truth
#   point. Replaced with SGID owner='Private' parcel interiors (state-authority-confirmed).
"7|Brian Head, Utah, USA|UT|Dixie NF inholding"
"8|Cloudcroft, New Mexico, USA|NM|Lincoln NF inholding"
"9|Jemez Springs, New Mexico, USA|NM|Santa Fe NF inholding"
"10|Government Camp, Oregon, USA|OR|Mt Hood NF inholding"
"11|Atlanta, Idaho, USA|ID|Boise NF inholding"
"12|Stanley, Idaho, USA|ID|Sawtooth NRA private townsite"
"13|Lamoille, Nevada, USA|NV|Humboldt-Toiyabe NF edge inholding"
"14|Kohls Ranch, Arizona, USA|AZ|Tonto NF ranch/resort inholding"
)

tmp=$(mktemp); echo "[" > "$tmp"; first=1
for row in "${PLACES[@]}"; do
  IFS='|' read -r id q st note <<< "$row"
  enc=$(python3 -c "import urllib.parse,sys;print(urllib.parse.quote(sys.argv[1]))" "$q")
  res=$(curl -s -A "$UA" "${NOM}?q=${enc}&format=json&limit=1&countrycodes=us")
  coords=$(echo "$res" | python3 -c "import sys,json;d=json.load(sys.stdin);print(f\"{d[0]['lat']} {d[0]['lon']}\" if d else 'NA NA')")
  lat=${coords% *}; lon=${coords#* }
  if [ "$lat" = "NA" ]; then echo "  GEOCODE FAIL: #$id $q"; continue; fi
  [ $first -eq 0 ] && echo "," >> "$tmp"; first=0
  printf '  {"id":%s,"place":"%s","state":"%s","note":"%s","lat":%s,"lng":%s,"source":"nominatim"}' \
    "$id" "${q%%,*}" "$st" "$note" "$lat" "$lon" >> "$tmp"
  echo "  #$id ${q%%,*} -> $lat, $lon"
  sleep 1
done
echo "," >> "$tmp"
printf '  {"id":15,"place":"Cartwright Ranch (52610 7 Springs Rd)","state":"AZ","note":"Tonto NF undeveloped ranch inholding","lat":33.961887,"lng":-111.865120,"source":"provided"}' >> "$tmp"
echo "," >> "$tmp"
printf '  {"id":6,"place":"Alta townsite (SGID private parcel)","state":"UT","note":"Wasatch NF private townsite; SGID/SITLA owner=Private, parcel interior","lat":40.588993,"lng":-111.643138,"source":"ugrc-sgid"}' >> "$tmp"
echo "," >> "$tmp"
printf '  {"id":16,"place":"Grizzly Gulch nr Alta (SGID private parcel)","state":"UT","note":"2.5 ha SGID owner=Private parcel (patented-claim country) inside PAD-US USFS GREEN","lat":40.567619,"lng":-111.624833,"source":"ugrc-sgid"}' >> "$tmp"
echo "" >> "$tmp"; echo "]" >> "$tmp"
mkdir -p db/fixtures
python3 -c "import json;json.dump(json.load(open('$tmp')),open('$OUT','w'),indent=2)"
echo "wrote $OUT ($(python3 -c "import json;print(len(json.load(open('$OUT'))))") points)"
echo

VALUES=$(python3 -c "
import json
pts=json.load(open('$OUT'))
print(','.join(\"({},'{}','{}',{},{})\".format(p['id'],p['place'].replace(chr(39),chr(39)*2),p['state'],p['lat'],p['lng']) for p in pts))
")

docker compose exec -T postgres psql -U postgres -d miningapp <<SQL
CREATE TEMP TABLE val AS
SELECT p.id, p.place, p.state, lr.verdict, lr.land_manager AS mgr, lr.unit_nm,
  CASE WHEN lr.verdict IS NULL  THEN 'YELLOW-UNKNOWN'
       WHEN lr.verdict='GREEN'  THEN 'GREEN  ***FALSE-GREEN***'
       WHEN lr.verdict='YELLOW' THEN 'YELLOW-KNOWN'
       ELSE lr.verdict END AS outcome
FROM (VALUES ${VALUES}) AS p(id,place,state,lat,lng)
LEFT JOIN LATERAL (
  SELECT verdict, land_manager, unit_nm FROM tiles.legality_polygons
  WHERE ST_Covers(geom, ST_SetSRID(ST_MakePoint(p.lng, p.lat),4326))
  ORDER BY orescout_rank(verdict) DESC LIMIT 1
) lr ON true;

\echo '=== PER-POINT ==='
SELECT id, left(place,28) AS place, state, outcome, mgr, left(unit_nm,28) AS unit FROM val ORDER BY id;
\echo '=== SUMMARY ==='
SELECT outcome, count(*) FROM val GROUP BY outcome ORDER BY 2 DESC;
\echo '=== FALSE-GREEN DEFECTS (must be zero) ==='
SELECT id, place, state, mgr, unit_nm FROM val WHERE verdict='GREEN';
SQL
