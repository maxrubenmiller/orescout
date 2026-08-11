#!/usr/bin/env bash
# Class-2 refresh job: re-pull a confirm-open ownership source and rebuild its YELLOW rows
# (docs/DATA_REFRESH_PLAN.md §3; PROJECT_PLAN §6.4.1/§6.13). One wrapper, both sources:
#
#   ./scripts/etl/refresh_confirm_open.sh ut      # Utah SGID/SITLA (upstream revises weekly)
#   ./scripts/etl/refresh_confirm_open.sh ca      # CA CAL FIRE (upstream ~annual)
#
# Sequence + gates (any failure exits non-zero; the live layer keeps its previous rows):
#   lock -> pull to staging -> schema assertion -> clone live legality to _new ->
#   confirm_open_<st>.sql against _new in ONE TRANSACTION -> PRE-SWAP gates (0-row, row-count
#   band vs previous, Tier-B golden tileBase) -> atomic_swap -> POST-SWAP Tier-A/Tier-B ->
#   registry stamp.
#
# GATE ORDERING (review finding PP-9) — why the clone step exists:
#   This job used to run confirm_open_<st>.sql directly against the live table with psql -1.
#   The single transaction removed the *missing-layer* window, but it COMMITTED before any gate
#   ran: the 0-row check, the ±40% band, and the fixture gates all executed against rows that
#   were already serving. (The band's own error text admitted "rows ARE live".) A rebuild that
#   succeeded in SQL but under-produced YELLOW — upstream ownership-semantics drift, a corrupt
#   staging load — was live the moment it committed, and every point that lost its YELLOW
#   overlay fell through to the underlying PAD-US GREEN. A drop of less than 40% passed every
#   gate silently and got stamped fresh.
#   Now the SQL runs against a clone and the gates decide whether it ever becomes live, per the
#   refresh_lib.sh contract ("ANY failure exits non-zero with the LIVE table untouched") that
#   refresh_claims.sh already honored and this job did not. The clone costs ~11s.
#
# NOT wired into refresh_due auto-runs for legality-adjacent safety? It IS Class-2 (auto): the
# same scripts, newer data, gated by the fixture suites — the design's normal operation. The
# zero-false-GREEN private validation is a PAD-US-class (Class-3) gate, run on base-layer bumps.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/refresh_lib.sh
source scripts/etl/registry_lib.sh   # per-state params come from etl/sources.json (§6.13)

ST="${1:-}"
API="${2:-http://localhost:5167/api/v1}"

# All per-state params (staging, schema_cols, loader, sql, vintage, upstream_ref, max_age_days)
# come from the registry (was two nested case blocks here; §6.13). The stamp vintage is now the
# single canonical registry vintage — same string the generator bakes into the polygons — so
# provenance is consistent across data_sources and legality_polygons. Handles all 8 confirm_open
# states (CA/UT bespoke SQL + the 6 SMA template states) uniformly.
STU=$(echo "$ST" | tr '[:lower:]' '[:upper:]')
KEY=$(reg_key_for_state_role "$STU" confirm_open) \
  || { echo "usage: $0 <ut|ca|nv|az|co|nm|or|id> [api_base_url]" >&2; exit 2; }
SRC_KEY="$KEY"
STAGING=$(reg_confirm "$KEY" staging)
SCHEMA_COLS=$(reg_schema_cols "$KEY")
VINTAGE=$(reg_vintage "$KEY")
REF=$(reg_upstream "$KEY")
MAXAGE=$(reg_maxage "$KEY")
LOADER=$(reg_loader "$KEY")
case "$LOADER" in
  *pull_sma.sh) PULL="./$LOADER $ST" ;;   # the shared SMA adapter takes the state arg
  *)            PULL="./$LOADER" ;;        # CA/UT have dedicated single-source loaders
esac
if [ "$(reg_sql "$KEY")" = "generated" ]; then
  SQL="scripts/etl/confirm_open_${ST}.sql"
  [ -f "$SQL" ] || { echo "✗ $SQL missing — run ./scripts/etl/gen_confirm_open.sh ${ST} first" >&2; exit 2; }
else
  SQL="$(reg_sql "$KEY")"
fi

refresh_lock "confirm_open_${ST}"

echo "[confirm-open ${ST}] previous row count…"
before=$(_rq "SELECT count(*) FROM tiles.legality_polygons WHERE source_key='${SRC_KEY}'")
echo "[confirm-open ${ST}] live ${SRC_KEY} rows before: $before"

echo "[confirm-open ${ST}] pulling upstream -> ${STAGING}…"
$PULL

# shellcheck disable=SC2086  # word-splitting SCHEMA_COLS is intended
assert_schema "$STAGING" $SCHEMA_COLS

LIVE=tiles.legality_polygons
NEW="${LIVE}_new"

# Structural clone of the live layer, then rebuild THIS state's rows inside it. LIKE INCLUDING ALL
# carries the indexes, PK and CHECK constraint, but its ogc_fid default would point at the live
# table's sequence (dropped with the old table at swap time), so the clone gets its own.
echo "[confirm-open ${ST}] cloning ${LIVE} -> ${NEW}…"
_rx "DROP TABLE IF EXISTS ${NEW};
     CREATE TABLE ${NEW} (LIKE ${LIVE} INCLUDING ALL);
     CREATE SEQUENCE ${NEW}_ogc_fid_seq OWNED BY ${NEW}.ogc_fid;
     ALTER TABLE ${NEW} ALTER COLUMN ogc_fid SET DEFAULT nextval('${NEW}_ogc_fid_seq');
     INSERT INTO ${NEW} SELECT * FROM ${LIVE};
     SELECT setval('${NEW}_ogc_fid_seq', COALESCE((SELECT max(ogc_fid) FROM ${NEW}), 1));
     GRANT SELECT ON ${NEW} TO tileserv_ro;" \
  || rfail "confirm-open ${ST}: could not clone ${LIVE}"

echo "[confirm-open ${ST}] rebuilding rows in ${NEW} (single transaction)…"
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -v legality_tbl=${NEW} -1 -q" < "$SQL" \
  || rfail "confirm-open ${ST}: SQL failed — ${NEW} left for inspection, live table untouched"

# ---- PRE-SWAP gates: nothing below is serving yet ----------------------------
after=$(_rq "SELECT count(*) FROM ${NEW} WHERE source_key='${SRC_KEY}'")
[ "$after" -gt 0 ] || rfail "confirm-open ${ST}: rebuild produced 0 rows — live table untouched"
if [ "$before" -gt 0 ]; then
  lo=$(( before * 60 / 100 )); hi=$(( before * 140 / 100 ))
  if [ "$after" -lt "$lo" ] || [ "$after" -gt "$hi" ]; then
    rfail "confirm-open ${ST}: row count $after outside ±40% of previous $before — investigate before trusting (nothing is live; ${NEW} left for inspection)"
  fi
fi
echo "[confirm-open ${ST}] rows: $before -> $after (not yet live)"

echo "[confirm-open ${ST}] pre-swap golden gate…"
./scripts/etl/gate_legality_tilebase.sh "$NEW" \
  || rfail "confirm-open ${ST}: pre-swap tileBase gate failed — ${NEW} left for inspection, live table untouched"

# ---- swap, then confirm ------------------------------------------------------
atomic_swap "$LIVE"
stamp_legality_generation

# ---- derived display tables (review finding PP-6) ----------------------------
# This job used to rebuild ONLY tiles.legality_polygons. tiles.legality_lowzoom and both display
# tables are derived from it and were never touched, so every Class-2 refresh silently widened the
# gap between what /assessment says and what the map paints — and refresh_due.sh auto-runs this
# job, so the divergence re-created itself forever. It is how the z<9 map came to paint GREEN over
# 243 km² of blmsma_nm land the engine already called YELLOW. There is no staleness guard because
# the derived tables carry no vintage; the generation stamp below adds one.
# This is the slow part of the job (~10-15 min). Correctness over cadence: a fast refresh that
# leaves the map contradicting the verdict is not a refresh worth having.
echo "[confirm-open ${ST}] rebuilding derived display tables (lowzoom + display partition)…"
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -q" < scripts/etl/build_lowzoom.sql >/dev/null \
  || rfail "confirm-open ${ST}: build_lowzoom failed — legality_polygons is live but the low-zoom map is now STALE; re-run ./scripts/etl/rebuild_legality.sh"
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -q -v src=tiles.legality_polygons -v tgt=tiles.legality_display" \
  < scripts/etl/build_legality_display.sql >/dev/null \
  || rfail "confirm-open ${ST}: build_legality_display (normal) failed — map display is STALE"
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -q -v src=tiles.legality_lowzoom -v tgt=tiles.legality_display_lowzoom -v cellsize=1.0" \
  < scripts/etl/build_legality_display.sql >/dev/null \
  || rfail "confirm-open ${ST}: build_legality_display (low-zoom) failed — map display is STALE"
stamp_display_generation

echo "[confirm-open ${ST}] post-swap fixture gates…"
./scripts/run-fixtures.sh
curl -sqf -o /dev/null --max-time 5 "$API/health" \
  || rfail "API not reachable at $API — start it and run ./scripts/run-tier-b.sh to finish the gate"
./scripts/run-tier-b.sh "$API"

stamp_source "$SRC_KEY" confirm_open "$VINTAGE (refreshed $(date +%Y-%m-%d))" "$MAXAGE" "$REF" ok
echo "[confirm-open ${ST}] ✓ refreshed, gated, stamped"
