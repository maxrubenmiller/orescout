#!/usr/bin/env bash
# Class-2 refresh job: re-pull a confirm-open ownership source and rebuild its YELLOW rows
# (docs/DATA_REFRESH_PLAN.md §3; PROJECT_PLAN §6.4.1/§6.13). One wrapper, both sources:
#
#   ./scripts/etl/refresh_confirm_open.sh ut      # Utah SGID/SITLA (upstream revises weekly)
#   ./scripts/etl/refresh_confirm_open.sh ca      # CA CAL FIRE (upstream ~annual)
#
# Sequence + gates (any failure exits non-zero; the live layer keeps its previous rows):
#   lock -> pull to staging -> schema assertion -> confirm_open_<st>.sql in ONE TRANSACTION
#   (psql -1: readers keep the old YELLOW rows until commit — no window where the confirm-open
#   layer is missing, the F-4 failure mode) -> row-count band vs previous -> Tier-A fixtures ->
#   Tier-B goldens (needs the API up; includes the confirm-open golden points) -> registry stamp.
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

echo "[confirm-open ${ST}] rebuilding rows (single transaction — old rows serve until commit)…"
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -1 -q" < "$SQL"

after=$(_rq "SELECT count(*) FROM tiles.legality_polygons WHERE source_key='${SRC_KEY}'")
[ "$after" -gt 0 ] || rfail "confirm-open ${ST}: rebuild produced 0 rows"
if [ "$before" -gt 0 ]; then
  lo=$(( before * 60 / 100 )); hi=$(( before * 140 / 100 ))
  if [ "$after" -lt "$lo" ] || [ "$after" -gt "$hi" ]; then
    rfail "confirm-open ${ST}: row count $after outside ±40% of previous $before — investigate before trusting (rows ARE live; rerun the previous data via git-pinned staging if needed)"
  fi
fi
echo "[confirm-open ${ST}] rows: $before -> $after"

echo "[confirm-open ${ST}] fixture gates…"
./scripts/run-fixtures.sh
curl -sqf -o /dev/null --max-time 5 "$API/health" \
  || rfail "API not reachable at $API — start it and run ./scripts/run-tier-b.sh to finish the gate"
./scripts/run-tier-b.sh "$API"

stamp_source "$SRC_KEY" confirm_open "$VINTAGE (refreshed $(date +%Y-%m-%d))" "$MAXAGE" "$REF" ok
echo "[confirm-open ${ST}] ✓ refreshed, gated, stamped"
