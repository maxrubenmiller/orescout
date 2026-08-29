#!/usr/bin/env bash
# Class-2 refresh job: re-pull a confirm-open ownership source and rebuild its YELLOW rows
# (docs/DATA_REFRESH_PLAN.md §3; PROJECT_PLAN §6.4.1/§6.13). One wrapper, both sources:
#
#   ./scripts/etl/refresh_confirm_open.sh ut      # Utah SGID/SITLA (upstream revises weekly)
#   ./scripts/etl/refresh_confirm_open.sh ca      # CA CAL FIRE (upstream ~annual)
#
# Env:
#   REFRESH_DRY_RUN=1         run every pre-swap gate, then discard and stop (live untouched)
#   ORESCOUT_DEFER_DERIVED=1  skip the global derived rebuild; the CALLER must run it (PP-33)
#   SKIP_NOTPUBLIC_GATE=1     skip the output-property gate (say why in writing)
#   CONFIRM_OPEN_BAND_PCT=N   widen the ±40% row-count band. ONLY for a change known to move row
#                             counts legitimately (PP-36). Prints the area delta and says loudly
#                             that it is in force. Do not use it to push through a surprise.
#   REFRESH_SKIP_PULL=1       re-carve from the EXISTING staging data, no upstream pull. For when
#                             the carve SQL changed but the ownership data did not (e.g. PP-36).
#                             Every gate still runs. Deliberately does NOT stamp a new vintage:
#                             nothing was refreshed, so resetting the max_age clock would be a lie.
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
  # Registry-vs-SQL drift gate (review finding PP-12). This used to be an existence check only, so
  # the job would happily execute a committed file that no longer matched the registry claiming to
  # define it — a registry edit did nothing until someone remembered to regenerate, and a hand-edit
  # to a "GENERATED, do not edit" file survived indefinitely. Cheap: regenerates to a temp dir and
  # diffs; it never writes to scripts/etl.
  ./scripts/test/gen_drift_check.sh >/dev/null 2>&1 || {
    echo "✗ ${ST}: committed confirm_open SQL has DRIFTED from etl/sources.json." >&2
    echo "  Run ./scripts/test/gen_drift_check.sh to see the diff. Refusing to refresh with SQL" >&2
    echo "  that does not match the registry — the registry is supposed to be the source of truth." >&2
    exit 2
  }
else
  SQL="$(reg_sql "$KEY")"
fi

refresh_lock "confirm_open_${ST}"

echo "[confirm-open ${ST}] previous row count…"
before=$(_rq "SELECT count(*) FROM tiles.legality_polygons WHERE source_key='${SRC_KEY}'")
echo "[confirm-open ${ST}] live ${SRC_KEY} rows before: $before"

if [ "${REFRESH_SKIP_PULL:-0}" = "1" ]; then
  echo "[confirm-open ${ST}] REFRESH_SKIP_PULL=1 — re-carving from existing ${STAGING}, no pull"
else
  echo "[confirm-open ${ST}] pulling upstream -> ${STAGING}…"
  $PULL
fi

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
  # The band defaults to +/-40% and MUST stay there for routine refreshes: it is what catches an
  # under-producing rebuild before it can serve. CONFIRM_OPEN_BAND_PCT exists only for a change
  # that is KNOWN to move row counts legitimately — PP-36 keeps sub-floor fragments of large
  # parcels, which raised ID from 19,848 to 28,954 rows (+45.9%) while the AREA moved just 365.18
  # -> 366.70 km2 (+0.4%). Row count is the wrong invariant for that change; area is the right one,
  # so the override prints both and says loudly that it is in force.
  BAND="${CONFIRM_OPEN_BAND_PCT:-40}"
  if [ "$BAND" != "40" ]; then
    a_before=$(_rq "SELECT COALESCE(round((sum(ST_Area(geom::geography))/1e6)::numeric,2),0) FROM ${LIVE} WHERE source_key='${SRC_KEY}'")
    a_after=$(_rq "SELECT COALESCE(round((sum(ST_Area(geom::geography))/1e6)::numeric,2),0) FROM ${NEW} WHERE source_key='${SRC_KEY}'")
    echo "[confirm-open ${ST}] !! COUNT BAND WIDENED to ±${BAND}% by CONFIRM_OPEN_BAND_PCT (default 40)"
    echo "[confirm-open ${ST}] !! rows ${before} -> ${after} · area ${a_before} -> ${a_after} km2"
    echo "[confirm-open ${ST}] !! area is the invariant that matters here — check it, not the count"
  fi
  lo=$(( before * (100 - BAND) / 100 )); hi=$(( before * (100 + BAND) / 100 ))
  if [ "$after" -lt "$lo" ] || [ "$after" -gt "$hi" ]; then
    rfail "confirm-open ${ST}: row count $after outside ±40% of previous $before — investigate before trusting (nothing is live; ${NEW} left for inspection)"
  fi
fi
echo "[confirm-open ${ST}] rows: $before -> $after (not yet live)"

echo "[confirm-open ${ST}] pre-swap golden gate…"
./scripts/etl/gate_legality_tilebase.sh "$NEW" \
  || rfail "confirm-open ${ST}: pre-swap tileBase gate failed — ${NEW} left for inspection, live table untouched"

# Output-property gate, scoped to THIS state only (~1-3 min rather than ~40 for all eight). A
# refresh changes exactly one state's rows, so gating exactly that state is both cheaper and more
# precise than the full sweep. Pre-swap, so a bad refresh never serves.
if [ "${SKIP_NOTPUBLIC_GATE:-0}" = "1" ]; then
  echo "[confirm-open ${ST}] ⚠ not-public/GREEN gate SKIPPED by SKIP_NOTPUBLIC_GATE=1"
else
  echo "[confirm-open ${ST}] pre-swap not-public/GREEN gate (${STU} only)…"
  GATE_TARGET="$NEW" ./scripts/validation/gate_notpublic_green.sh "$ST" \
    || rfail "confirm-open ${ST}: not-public/GREEN gate regressed — ${NEW} left for inspection, live table untouched"
fi

# ---- DRY RUN stop point ------------------------------------------------------
# REFRESH_DRY_RUN=1 exercises everything above this line for real — registry lookup, upstream pull,
# assert_schema, the clone, the carve against _new, and all three pre-swap gates — then discards the
# candidate and stops. Live is untouched by construction, because the swap is the next statement.
#
# Two uses. Operationally: rehearse a refresh before committing to one, e.g. when upstream has
# changed and you want to see the row delta and the golden gate before it can serve. And as the
# cheap integration test for this job, which is otherwise expensive to exercise (a full run rebuilds
# the derived display chain and takes ~45-60 min).
if [ "${REFRESH_DRY_RUN:-0}" = "1" ]; then
  echo "[confirm-open ${ST}] DRY RUN — pre-swap gates PASSED; discarding ${NEW}, not swapping."
  echo "[confirm-open ${ST}]   would have gone live: ${before} -> ${after} ${SRC_KEY} rows"
  _rx "DROP TABLE IF EXISTS ${NEW};"
  echo "[confirm-open ${ST}] ✓ dry run complete — live table untouched, nothing stamped"
  exit 0
fi

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
# Each derived table builds into _new and swaps atomically (PP-31): a failure mid-build leaves the
# live display serving its previous generation instead of an empty table.
#
# BATCHING (review finding PP-33). The three derived tables are global — they are computed from the
# WHOLE of legality_polygons, not from one state's rows — so a per-state refresh has to rebuild all
# of them, and refreshing N states rebuilds them N times with the first N-1 results discarded. All 8
# states would be ~3.3 h of derived rebuilds, ~2.9 h of it wasted.
#
# ORESCOUT_DEFER_DERIVED=1 skips the rebuild AND the display stamp, leaving the caller to run the
# chain once after the last state. refresh_due.sh does exactly that. A standalone run never defers,
# so an operator refreshing one state by hand is never left with a stale map by surprise.
#
# The deferral deliberately re-opens PP-6's window (map contradicting the verdict) between here and
# the caller's trailing rebuild. That is acceptable ONLY because PP-6's own guard now exists: the
# two generation stamps disagree in that interval, so display_sync_check.sh check A fails and says
# the derived tables are stale. Detectable and alarmed, rather than silent, is the whole difference.
if [ "${ORESCOUT_DEFER_DERIVED:-0}" = "1" ]; then
  echo "[confirm-open ${ST}] derived display rebuild DEFERRED to the caller (PP-33 batching)."
  echo "[confirm-open ${ST}]   legality_generation is stamped; legality_display_generation is NOT."
  echo "[confirm-open ${ST}]   display_sync_check.sh will FAIL until the caller rebuilds the derived chain."
  if [ "${REFRESH_SKIP_PULL:-0}" = "1" ]; then
  echo "[confirm-open ${ST}] skipping vintage stamp — no upstream pull happened"
else
  stamp_source "$SRC_KEY" confirm_open "$VINTAGE (refreshed $(date +%Y-%m-%d))" "$MAXAGE" "$REF" ok
fi
  echo "[confirm-open ${ST}] ✓ refreshed, gated, stamped (derived deferred)"
  exit 0
fi

echo "[confirm-open ${ST}] rebuilding derived display tables (lowzoom + display partition)…"
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -q -v lowzoom_tbl=tiles.legality_lowzoom_new" < scripts/etl/build_lowzoom.sql >/dev/null \
  || rfail "confirm-open ${ST}: build_lowzoom failed — live low-zoom layer untouched, but it is now STALE vs legality_polygons; re-run ./scripts/etl/rebuild_legality.sh"
count_gate tiles.legality_lowzoom 40
atomic_swap tiles.legality_lowzoom
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -q -v src=tiles.legality_polygons -v tgt=tiles.legality_display_new" \
  < scripts/etl/build_legality_display.sql >/dev/null \
  || rfail "confirm-open ${ST}: build_legality_display (normal) failed — live display untouched but STALE"
count_gate tiles.legality_display 40
atomic_swap tiles.legality_display
eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -q -v src=tiles.legality_lowzoom -v tgt=tiles.legality_display_lowzoom_new -v cellsize=1.0" \
  < scripts/etl/build_legality_display.sql >/dev/null \
  || rfail "confirm-open ${ST}: build_legality_display (low-zoom) failed — live display untouched but STALE"
count_gate tiles.legality_display_lowzoom 40
atomic_swap tiles.legality_display_lowzoom
stamp_display_generation

echo "[confirm-open ${ST}] post-swap fixture gates…"
./scripts/run-fixtures.sh
curl -sqf -o /dev/null --max-time 5 "$API/health" \
  || rfail "API not reachable at $API — start it and run ./scripts/run-tier-b.sh to finish the gate"
./scripts/run-tier-b.sh "$API"

if [ "${REFRESH_SKIP_PULL:-0}" = "1" ]; then
  echo "[confirm-open ${ST}] skipping vintage stamp — no upstream pull happened"
else
  stamp_source "$SRC_KEY" confirm_open "$VINTAGE (refreshed $(date +%Y-%m-%d))" "$MAXAGE" "$REF" ok
fi
echo "[confirm-open ${ST}] ✓ refreshed, gated, stamped"
