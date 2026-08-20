#!/usr/bin/env bash
# Parcel ground-truth adapters for the Tier-1 private-land validation (TODO Track 2; harness:
# scripts/validation/). Each source maps into the ONE staging.parcels contract:
#   parcel_id · state · geom(MultiPolygon,4326) · owner_class · source_key
#   owner_class: 'private' | 'other_public' | 'federal' | 'unknown'  (PP-32; was 3 classes)
#
#   ./scripts/etl/pull_parcels.sh ut    # UGRC SGID statewide parcels — explicit OWN_TYPE flag
#   ./scripts/etl/pull_parcels.sh co    # CO OIT statewide composite — owner-name regex classing
#   ./scripts/etl/pull_parcels.sh nm    # NM OSE County Parcels 2025 — owner-name regex classing
#
# STATED BOUNDS (no-silent-caps invariant):
#   * County-scoped to prospecting-relevant counties (mining districts + federal-adjacent rural;
#     lists below) — metro-only counties add volume, not validation signal. Counts printed.
#   * UT pulls OWN_TYPE='Private' rows only (the validation samples private parcels; the public
#     side of the frame comes from tiles.legality_polygons, not the parcel fabric).
#   * CO/NM have no ownership-class field: owner_class is derived from owner-name regex —
#     tribal/state/county/city names => 'other_public', federal agencies => 'federal',
#     empty/unparseable => 'unknown', else 'private'.
#     Consumers must read these correctly, because 'not private' no longer means 'open':
#       carve (confirm_open_*.sql)  protects owner_class <> 'federal'  — private, other_public
#                                   and unknown all get carved; only federal confirms open.
#       §6.4.1 validation frame     samples owner_class = 'private' — affirmative private ground
#                                   truth, now more accurate since city/county/tribal moved out.
#     Before PP-32 there was one 'public' class and the carve protected only 'private', so a
#     city park, a county yard or tribal land silently counted as confirming that PAD-US's GREEN
#     was open.
#   * PRIVACY: owner names are used ONLY transiently for classification and are NOT loaded into
#     staging.parcels (classification happens in the transform; names never reach Postgres).
#     Nothing with names is ever committed to the repo (fixtures carry APN + class + geometry).
#
# Licenses: UT SGID "State of Utah, SGID" attribution; CO terms forbid RESALE (validation use ok,
# no redistribution of the data itself); NM OSE public MapServer. All as-is.
set -euo pipefail
cd "$(dirname "$0")/../.."
ST="${1:-}"
OUT="data/parcels/${ST}"
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
UA="OreScout-ETL/0.1"
PAGE=2000

PSQL() { docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d miningapp "$@"; }
die() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

# Government/public owner-name patterns (CO/NM classing). Greedy toward public on doubt.
#
# WORD BOUNDARIES (review finding PP-10 + a defect found while fixing it): this regex is evaluated
# by Postgres (`upper(owner) ~ '<regex>'`), and in Postgres ARE `\b` is BACKSPACE, not a word
# boundary — the word-boundary escape is `\y` (`\m`/`\M` for word start/end). Every `\b` pattern
# here was therefore dead: verified in psql, 'BLM' ~ '\bBLM\b' is FALSE, 'CITY OF DENVER' ~
# '\bCITY OF\b' is FALSE, 'USA' ~ '^USA\b' is FALSE. Ten alternatives never matched anything, so
# city/town/county/tribal parcels were classed 'private'. That direction is safe for the carve
# (over-carving yields extra YELLOW) but it pollutes the §6.4.1 validation frame, which counts
# those parcels as private ground truth. All `\b` -> `\y`, and the `BbIA\b` typo -> `\yBIA\y`.
#
# 'STATE OF' (PP-10) was unbounded, so 'ESTATE OF JOHN A SMITH', 'SMITH JOHN ESTATE OF' and
# 'REAL ESTATE OF THE ROCKIES INC' all classed 'public' — and estates of deceased owners are
# common in exactly the rural CO/NM cabin/ranch counties the parcel carve targets. A private
# parcel misclassified public is NOT carved, so PAD-US GREEN over it survives. Note the safe
# direction INVERTS between the two consumers: the header above reasons about the validation
# frame, where greedy-toward-public is conservative; for the carve it is the dangerous direction.
# `\mSTATE OF` anchors to a word start: 'STATE OF COLORADO' matches, 'ESTATE OF' does not,
# 'INTERSTATE OFFICE PARK LLC' does not.
# OWNER CLASSES (review finding PP-32). Three classes were not enough. The carve protects only
# owner_class='private', so anything else is treated as confirming that PAD-US's GREEN is open —
# which is fine for BLM and USFS and wrong for a city park, a county yard, or tribal land. Splitting
# the old single PUB_REGEX in two lets 'public but not open' be its own class, the same distinction
# PP-2 established for the SMA layer.
#
# OTHER_PUB is tested FIRST, deliberately. A name like "UNITED STATES BUREAU OF INDIAN AFFAIRS"
# matches both patterns; tribal land must never come out as open, so ambiguity resolves to the
# non-confirming class. Safe direction on a tie.
#
# Word boundaries are \y and word-start is \m — Postgres ARE, not PCRE. \b is BACKSPACE here and
# silently matches nothing (PP-27). scripts/test/parcel_owner_regex_test.sh pins this in Postgres.

# Public, but NOT open: state / county / city / special district / tribal. Also BIA, which is a
# federal agency administering land that is emphatically not open for collecting. 'PUBLIC LAND(S)'
# lives here rather than in FED because it is ambiguous, and ambiguity must not confirm open.
OTHERPUB_REGEX='(\mSTATE OF|\yCITY OF\y|\yTOWN OF\y|\yCOUNTY OF\y|COUNTY COMMISSIONERS|SCHOOL DISTRICT|HOUSING AUTHORITY|WATER DISTRICT|FIRE DISTRICT|IRRIGATION DISTRICT|\yDISTRICT\y.*(WATER|FIRE|SCHOOL)|INDIAN TRIBE|\yTRIBE\y|\yNATION\y|\yPUEBLO OF\y|\yBIA\y|BUREAU OF INDIAN AFFAIRS|LAND BOARD|DIVISION OF WILDLIFE|PARKS AND WILDLIFE|GAME (AND|&) FISH|PUBLIC LANDS?)'

# Federal land-management agencies whose ownership DOES support an open reading.
FED_REGEX='(UNITED STATES|^USA\y|U S A|US GOVT|BUREAU OF LAND|\yBLM\y|FOREST SERVICE|USDA|USFS|DEPT OF AGRICULTURE|DEPARTMENT OF (THE )?INTERIOR|NATIONAL PARK|FISH AND WILDLIFE|BUREAU OF RECLAMATION|CORPS OF ENGINEERS)'

# paginated ArcGIS GeoJSON pull -> files (mirrors pull_mrds.sh conventions)
pull_pages() { # <query_url> <where> <fields> <prefix>
  local url="$1" where="$2" fields="$3" prefix="$4" offset=0 i=0 cnt f
  while :; do
    f="$OUT/${prefix}_${i}.geojson"
    curl -sq -A "$UA" --max-time 120 -G "$url" \
      --data-urlencode "where=$where" \
      --data-urlencode "outFields=$fields" \
      --data-urlencode "orderByFields=OBJECTID" \
      --data-urlencode "outSR=4326" \
      --data-urlencode "f=geojson" \
      --data-urlencode "resultOffset=$offset" \
      --data-urlencode "resultRecordCount=$PAGE" -o "$f" || die "$prefix page $i: fetch failed"
    cnt=$(python3 -c "
import json,sys
try:
  d=json.load(open('$f'))
  assert 'error' not in d, d.get('error')
  print(len(d.get('features',[])))
except AssertionError as e: print('ERR', e); sys.exit(1)
except Exception: print('ERR bad json'); sys.exit(1)") || die "$prefix page $i: bad response (see $f)"
    if [ "$cnt" = "0" ]; then rm -f "$f"; break; fi
    offset=$((offset + cnt)); i=$((i + 1))
    [ $((i % 25)) -eq 0 ] && echo "  …$prefix: $((offset)) features"
    [ "$cnt" -lt "$PAGE" ] && break
  done
  echo "  $prefix: $offset features ($i pages)"
}

load_staging() { # <staging_table> — loads all $OUT/*.geojson
  local tbl="$1" first=1 f
  for f in "$OUT"/*.geojson; do
    [ -e "$f" ] || die "no geojson pulled"
    if [ "$first" -eq 1 ]; then
      ogr2ogr -f PostgreSQL "$PG" "$f" -nln "$tbl" -nlt PROMOTE_TO_MULTI \
        -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite && first=0 || die "ogr2ogr overwrite failed"
    else
      ogr2ogr -f PostgreSQL "$PG" "$f" -nln "$tbl" -nlt PROMOTE_TO_MULTI -append || die "ogr2ogr append failed ($f)"
    fi
  done
}

ensure_parcels_table() {
  PSQL -q <<'SQL'
CREATE TABLE IF NOT EXISTS staging.parcels (
    parcel_id   text,
    state       text,
    geom        geometry(MultiPolygon, 4326),
    owner_class text CHECK (owner_class IN ('private','federal','other_public','unknown')),
    source_key  text
);
CREATE INDEX IF NOT EXISTS parcels_geom_idx ON staging.parcels USING GIST (geom);
CREATE INDEX IF NOT EXISTS parcels_class_idx ON staging.parcels (owner_class, state);
SQL
  # CREATE TABLE IF NOT EXISTS leaves an EXISTING table's CHECK constraint alone, so a table built
  # before PP-32 still forbids 'federal'/'other_public' and every insert would fail. Migrate it.
  PSQL -q <<'SQL'
DO $$
DECLARE con text;
BEGIN
  SELECT conname INTO con FROM pg_constraint
   WHERE conrelid = 'staging.parcels'::regclass AND contype = 'c'
     AND pg_get_constraintdef(oid) LIKE '%owner_class%'
     AND pg_get_constraintdef(oid) NOT LIKE '%other_public%';
  IF con IS NOT NULL THEN
    EXECUTE format('ALTER TABLE staging.parcels DROP CONSTRAINT %I', con);
    -- NOT VALID: enforce on new rows, tolerate pre-PP-32 rows still carrying the old catch-all
    -- 'public' class. Those cannot be reclassified in place — splitting 'public' into federal vs
    -- other_public needs the owner NAMES, which are deliberately never persisted (privacy: the raw
    -- tables are dropped at load). They are replaced state-by-state as each source is re-pulled.
    -- Once every state has been re-pulled:
    --   ALTER TABLE staging.parcels VALIDATE CONSTRAINT parcels_owner_class_check;
    -- Without NOT VALID this ALTER fails outright against any table built before PP-32, which is
    -- exactly what happened on the first attempt — loudly, and with the whole DO block rolling
    -- back, so no data was touched.
    ALTER TABLE staging.parcels
      ADD CONSTRAINT parcels_owner_class_check
      CHECK (owner_class IN ('private','federal','other_public','unknown')) NOT VALID;
    RAISE NOTICE 'migrated staging.parcels owner_class CHECK for PP-32 (NOT VALID; legacy rows tolerated until re-pull)';
  END IF;
END $$;
SQL
}

mkdir -p "$OUT"; rm -f "$OUT"/*.geojson
ensure_parcels_table

case "$ST" in
# ---------------------------------------------------------------- Utah -----
ut)
  URL="https://services1.arcgis.com/99lidPhWCzftIe9K/arcgis/rest/services/UtahStatewideParcels/FeatureServer/0/query"
  # Prospecting-relevant counties: west desert + southern/SE Utah mining country. Metro
  # (Salt Lake/Utah/Davis/Weber) excluded — volume without validation signal.
  COUNTIES="'TOOELE','JUAB','MILLARD','BEAVER','IRON','WASHINGTON','KANE','GARFIELD','PIUTE','SEVIER','WAYNE','EMERY','GRAND','SAN JUAN'"
  echo "[parcels ut] pulling SGID private parcels (14 rural/mining counties)…"
  pull_pages "$URL" "OWN_TYPE='Private' AND UPPER(County) IN (${COUNTIES})" "PARCEL_ID,County,OWN_TYPE" ut
  load_staging staging.parcels_ut_raw
  echo "[parcels ut] transform -> staging.parcels…"
  PSQL -q <<'SQL'
DELETE FROM staging.parcels WHERE source_key = 'ugrc_parcels';
INSERT INTO staging.parcels (parcel_id, state, geom, owner_class, source_key)
SELECT 'ut:' || coalesce(parcel_id, 'fid' || ogc_fid), 'UT',
       ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)),
       'private',                       -- pull was OWN_TYPE='Private' (explicit assessor flag)
       'ugrc_parcels'
FROM staging.parcels_ut_raw
WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom);
DROP TABLE staging.parcels_ut_raw;
SQL
  ;;
# ------------------------------------------------------------ Colorado -----
co)
  URL="https://gis.colorado.gov/public/rest/services/Address_and_Parcel/Colorado_Public_Parcels/FeatureServer/0/query"
  # Historic mining counties + foothill front-range (Boulder/Jefferson gold districts).
  COUNTIES="'CLEAR CREEK','GILPIN','PARK','TELLER','LAKE','SUMMIT','SAN JUAN','OURAY','SAN MIGUEL','HINSDALE','GUNNISON','CUSTER','SAGUACHE','BOULDER','JEFFERSON'"
  echo "[parcels co] pulling CO composite (15 mining/foothill counties)…"
  pull_pages "$URL" "UPPER(countyName) IN (${COUNTIES})" "parcel_id,owner,countyName" co
  load_staging staging.parcels_co_raw
  echo "[parcels co] transform (owner-name regex; names NOT persisted) -> staging.parcels…"
  PSQL -q <<SQL
DELETE FROM staging.parcels WHERE source_key = 'co_composite';
INSERT INTO staging.parcels (parcel_id, state, geom, owner_class, source_key)
SELECT 'co:' || coalesce(parcel_id, 'fid' || ogc_fid), 'CO',
       ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)),
       CASE
         WHEN owner IS NULL OR btrim(owner) = '' THEN 'unknown'
         WHEN upper(owner) ~ '${OTHERPUB_REGEX}' THEN 'other_public'
         WHEN upper(owner) ~ '${FED_REGEX}' THEN 'federal'
         ELSE 'private'
       END,
       'co_composite'
FROM staging.parcels_co_raw
WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom);
DROP TABLE staging.parcels_co_raw;   -- owner names leave the database here
SQL
  ;;
# ---------------------------------------------------------- New Mexico -----
nm)
  BASE="https://gis.ose.nm.gov/server_s/rest/services/Parcels/County_Parcels_2025/MapServer"
  # Mining/prospecting counties + Bernalillo control. Layer ids resolved from service JSON.
  WANTED="GRANT SIERRA HIDALGO CATRON SOCORRO OTERO LINCOLN TAOS COLFAX RIO_ARRIBA BERNALILLO"
  echo "[parcels nm] resolving county layer ids…"
  LAYERS=$(curl -sq -A "$UA" --max-time 60 "${BASE}?f=json" | python3 -c "
import json,sys
d=json.load(sys.stdin)
want={w.replace('_',' ').upper() for w in '''${WANTED}'''.split()}
for l in d.get('layers',[]):
    county=l['name'].upper().replace(' COUNTY PARCELS 2025','').strip()
    if county in want:
        print(f\"{l['id']}:{l['name'].split(' County')[0].replace(' ','_')}\")") || die "service JSON unreadable"
  [ -n "$LAYERS" ] || die "no county layers matched"
  for pair in $LAYERS; do
    id="${pair%%:*}"; name="${pair##*:}"
    echo "[parcels nm] layer $id ($name)…"
    pull_pages "${BASE}/${id}/query" "1=1" "UPC,OwnerAll,Owner1" "nm_${name}"
  done
  load_staging staging.parcels_nm_raw
  echo "[parcels nm] transform (owner-name regex; names NOT persisted) -> staging.parcels…"
  PSQL -q <<SQL
DELETE FROM staging.parcels WHERE source_key = 'nm_ose';
INSERT INTO staging.parcels (parcel_id, state, geom, owner_class, source_key)
SELECT 'nm:' || coalesce(upc, 'fid' || ogc_fid), 'NM',
       ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)),
       CASE
         WHEN coalesce(ownerall, owner1) IS NULL OR btrim(coalesce(ownerall, owner1)) = '' THEN 'unknown'
         WHEN upper(coalesce(ownerall, owner1)) ~ '${OTHERPUB_REGEX}' THEN 'other_public'
         WHEN upper(coalesce(ownerall, owner1)) ~ '${FED_REGEX}' THEN 'federal'
         ELSE 'private'
       END,
       'nm_ose'
FROM staging.parcels_nm_raw
WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom);
DROP TABLE staging.parcels_nm_raw;   -- owner names leave the database here
SQL
  ;;
*) echo "usage: $0 <ut|co|nm>" >&2; exit 2 ;;
esac

echo "[parcels ${ST}] inventory:"
PSQL -c "SELECT source_key, owner_class, count(*) FROM staging.parcels WHERE state = upper('${ST}') GROUP BY 1,2 ORDER BY 1,2;"
