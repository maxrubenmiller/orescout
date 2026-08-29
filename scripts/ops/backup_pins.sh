#!/usr/bin/env bash
# Back up public.pins — the ONLY non-reproducible data in this database (review finding PR-7).
#
# WHY THIS EXISTS. Every other table here is a cache of a computation over public data: tiles.*,
# staging.* and the rest can all be rebuilt from PAD-US / BLM / CAL FIRE by re-running the ETL. Lose
# them and you lose hours, not information. public.pins is the exception — a user stood somewhere and
# typed it, there is no upstream to re-download, and each row carries an assessment_snapshot
# recording what the app TOLD them at save time, which cannot be regenerated even in principle
# (re-running the assessment today gives a different answer; this remediation alone moved
# legality_polygons 171,293 -> 229,923 rows). Losing pins is irreversible in a way nothing else is.
#
# TWO DEPENDENCIES A NAIVE `pg_dump -t public.pins` SILENTLY DROPS:
#   1. The pins_updated_at trigger calls public.update_updated_at(), a SEPARATE function object.
#      `pg_dump -t` emits the trigger but NOT the function, so the restore produces a table whose
#      trigger references something that does not exist. This script dumps the function too.
#   2. The geom column is GENERATED ALWAYS ... STORED and needs PostGIS in the target database.
#      Recorded in the header below so a restore into a bare database fails loudly, not subtly.
#
# SCOPE. This is a bridge for the pre-launch, runs-on-a-laptop period, NOT the permanent answer.
# Once the app is on hosted Postgres, automated backups + point-in-time recovery are the platform's
# job and are strictly better than this (a daily dump can lose a day; PITR recovers to the second).
# Keep a logical pins dump even then: it restores ONE table without rolling the whole database back
# and undoing ETL work, which a volume snapshot cannot do.
#
# Usage:  ./scripts/ops/backup_pins.sh [outdir]
#   env:  KEEP=30   how many dumps to retain (0 = keep everything)
set -euo pipefail
cd "$(dirname "$0")/../.."

OUTDIR="${1:-./backups/pins}"
KEEP="${KEEP:-30}"
CONTAINER="${ORESCOUT_PG_CONTAINER:-orescout-postgres}"
DB="${ORESCOUT_DB:-miningapp}"
USER_="${ORESCOUT_DB_USER:-postgres}"

command -v docker >/dev/null || { echo "✗ docker not found" >&2; exit 2; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "✗ container '$CONTAINER' not running" >&2; exit 2; }

mkdir -p "$OUTDIR"
STAMP=$(docker exec "$CONTAINER" date -u +%Y%m%dT%H%M%SZ)
OUT="$OUTDIR/pins_${STAMP}.sql"

rows=$(docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -tAq -c "SELECT count(*) FROM public.pins;")
echo "[backup] public.pins has $rows row(s) -> $OUT"

{
  echo "-- OreScout public.pins backup"
  echo "-- taken: ${STAMP}   rows: ${rows}   source db: ${DB}"
  echo "-- REQUIRES PostGIS in the target database (pins.geom is geometry(Point,4326),"
  echo "-- GENERATED ALWAYS AS ... STORED). Restore with scripts/ops/restore_pins.sh."
  echo "CREATE EXTENSION IF NOT EXISTS postgis;"
  echo
  echo "-- Trigger dependency: pins_updated_at calls this. pg_dump -t public.pins does NOT include it."
  docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -tAq \
    -c "SELECT pg_get_functiondef(p.oid) || ';'
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname='public' AND p.proname='update_updated_at';"
  echo
  docker exec "$CONTAINER" pg_dump -U "$USER_" -d "$DB" --table=public.pins
} > "$OUT"

# A dump that captured nothing is not a backup. Fail loudly rather than retaining an empty file —
# this project has been bitten repeatedly by checks that pass on zero work.
grep -q "CREATE TABLE public.pins" "$OUT" || {
  echo "✗ backup: dump does not contain CREATE TABLE public.pins — refusing to keep it" >&2
  rm -f "$OUT"; exit 1; }
grep -q "FUNCTION public.update_updated_at" "$OUT" || {
  echo "✗ backup: trigger function missing from dump — restore would be broken" >&2
  rm -f "$OUT"; exit 1; }

echo "[backup] ✓ $(wc -c < "$OUT" | tr -d ' ') bytes, schema + function + $rows row(s)"

if [ "$KEEP" -gt 0 ]; then
  # shellcheck disable=SC2012
  n=$(ls -1 "$OUTDIR"/pins_*.sql 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt "$KEEP" ]; then
    ls -1t "$OUTDIR"/pins_*.sql | tail -n +$((KEEP + 1)) | while read -r old; do
      echo "[backup] pruning $(basename "$old")"; rm -f "$old"
    done
  fi
fi

echo "[backup] NOTE: $OUTDIR is on this machine. A dump that dies with the disk it protects is not"
echo "[backup]       a backup — copy it off-box (or move to hosted Postgres) before real users exist."
