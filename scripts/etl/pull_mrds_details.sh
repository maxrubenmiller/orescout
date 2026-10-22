#!/usr/bin/env bash
# Ingest the MRDS *related tables* (Commodity / Materials / Names) that enrich the gold popup
# (docs/planning/BACKLOG.md "Enrich the gold popup"). REFERENCE-ONLY, additive: it feeds extra display columns
# on tiles.mrds and NEVER touches the verdict engine (upholds the §6.13 `reference` invariant).
#
# ── Source (join-key trap resolved empirically; see docs/briefs/OPUS_BRIEF_mrds_enrichment.md) ──
# The hosted "MRDS Compact Version" FeatureServer (used by pull_mrds.sh) exposes NO related tables
# and NO relationships (FeatureServer/0?f=json -> "relationships": []). The three related tables
# live only in USGS's bulk relational export: mrdata.usgs.gov/mrds/rdbms-tab.zip (tab-delimited,
# CSV-quoted). In that export EVERY related table keys on column `dep_id` — which schema.ini labels
# "Record ID". So the popup brief's "Record_ID" == our stored `dep_id` (8-digit MRDS deposit id).
# Verified: dep_id 10086589 (Empire) -> Commodity Gold/Lead/Copper, Materials Ore Gold+Gangue
# Quartz, Names Empire/Gold Valley. The per-table `i` column is a global row index, NOT the key.
#
# We therefore deviate from pull_mrds.sh's OID-paged FeatureServer pattern (there is nothing to page
# here) but keep its conventions: registry-driven URL (single source of truth, §6.13), UA header,
# curl -q (dev ~/.curlrc auto-retry would corrupt a partial download), fail-fast (set -euo).
# Static source — USGS stopped updating MRDS in 2011.
#
# Loads gold-relevant rows only (filtered to the dep_ids in tiles.mrds) into:
#   staging.mrds_commodity(dep_id, line, commod, code, import)
#   staging.mrds_materials(dep_id, rec, ore_gangue, material)
#   staging.mrds_names(dep_id, line, name, status)
# Reports kept/dropped counts (repo invariant: stated bounds, no silent gaps).
#
# Usage:  ./scripts/etl/pull_mrds_details.sh [outdir]
# Next:   ./scripts/etl/build_mrds.sh   (aggregates -> additive columns, atomic-swaps tiles.mrds)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

OUT="${1:-data/mrds}"
UA="OreScout-ETL/0.1"
# Registry is the single source of truth for the bulk URL (etl/sources.json mrds.details.source).
URL="$(reg_raw '.sources[] | select(.key=="mrds") | .details.source')"
[ -n "$URL" ] && [ "$URL" != "null" ] || { echo "pull_mrds_details: no mrds.details.source in registry" >&2; exit 1; }

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
q()  { "${PSQL[@]}" -tAq -c "$1"; }

[ "$(q "SELECT to_regclass('tiles.mrds') IS NOT NULL")" = "t" ] \
  || { echo "pull_mrds_details: tiles.mrds missing — run pull_mrds.sh + build_mrds.sql first" >&2; exit 1; }

mkdir -p "$OUT"
ZIP="$OUT/rdbms-tab.zip"
echo "[mrds-details] downloading $URL"
curl -qsSf -A "$UA" --max-time 300 "$URL" -o "$ZIP"
echo "[mrds-details] downloaded $(wc -c < "$ZIP") bytes"

WORK="$OUT/rdbms"
rm -rf "$WORK"; mkdir -p "$WORK"
unzip -o "$ZIP" 'Commodity.txt' 'Materials.txt' 'Names.txt' -d "$WORK" >/dev/null
for f in Commodity.txt Materials.txt Names.txt; do
  [ -s "$WORK/$f" ] || { echo "pull_mrds_details: $f missing/empty in archive" >&2; exit 1; }
done

# COPY the full tab-delimited, CSV-quoted files into raw tables, then keep only gold dep_ids.
# The files quote text fields with " and use a header row; FORMAT csv + DELIMITER tab handles both
# (embedded delimiters/quotes/newlines). dep_id stays text — we join to tiles.mrds.dep_id::text.
load_one() { # load_one <raw-table> <final-table> <ddl-cols-csv> <copy-cols> <file> <keep-select>
  local raw="$1" fin="$2" ddl="$3" cols="$4" file="$5" keep="$6"
  "${PSQL[@]}" -q -c "DROP TABLE IF EXISTS $raw; CREATE UNLOGGED TABLE $raw ($ddl);"
  # psql runs inside the container, so stream the host file over STDIN (\copy … FROM STDIN).
  "${PSQL[@]}" -q -c "\copy $raw ($cols) FROM STDIN WITH (FORMAT csv, DELIMITER E'\t', QUOTE '\"', HEADER true)" < "$WORK/$file"
  local total; total=$(q "SELECT count(*) FROM $raw")
  "${PSQL[@]}" -q -c "DROP TABLE IF EXISTS $fin;
    CREATE TABLE $fin AS $keep;
    CREATE INDEX ON $fin (dep_id);"
  local kept; kept=$(q "SELECT count(*) FROM $fin")
  "${PSQL[@]}" -q -c "DROP TABLE IF EXISTS $raw;"
  echo "[mrds-details] $fin: kept $kept / $total rows (dropped $((total - kept)) non-gold)"
}

load_one staging.mrds_commodity_raw staging.mrds_commodity \
  "i text, dep_id text, line int, commod text, code text, commod_tp text, commod_group text, import text, inserted_by text, insert_date text, updated_by text, update_date text" \
  "i, dep_id, line, commod, code, commod_tp, commod_group, import, inserted_by, insert_date, updated_by, update_date" \
  Commodity.txt \
  "SELECT dep_id, line, commod, code, import FROM staging.mrds_commodity_raw
     WHERE dep_id IN (SELECT dep_id::text FROM tiles.mrds WHERE dep_id IS NOT NULL)"

load_one staging.mrds_materials_raw staging.mrds_materials \
  "i text, dep_id text, rec int, ore_gangue text, material text, inserted_by text, insert_date text, updated_by text, update_date text" \
  "i, dep_id, rec, ore_gangue, material, inserted_by, insert_date, updated_by, update_date" \
  Materials.txt \
  "SELECT dep_id, rec, ore_gangue, material FROM staging.mrds_materials_raw
     WHERE dep_id IN (SELECT dep_id::text FROM tiles.mrds WHERE dep_id IS NOT NULL)"

load_one staging.mrds_names_raw staging.mrds_names \
  "i text, dep_id text, line int, name text, status text, inserted_by text, insert_date text, updated_by text, update_date text" \
  "i, dep_id, line, name, status, inserted_by, insert_date, updated_by, update_date" \
  Names.txt \
  "SELECT dep_id, line, name, status FROM staging.mrds_names_raw
     WHERE dep_id IN (SELECT dep_id::text FROM tiles.mrds WHERE dep_id IS NOT NULL)"

echo "[mrds-details] done. next: ./scripts/etl/build_mrds.sh"
