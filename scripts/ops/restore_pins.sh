#!/usr/bin/env bash
# Restore public.pins from a backup produced by backup_pins.sh (review finding PR-7).
#
# A backup nobody has restored from is a hypothesis, not a backup. This script exists so the restore
# path is exercised BEFORE it is needed, and so that using it in anger cannot make things worse.
#
# TWO MODES:
#   (default)  VERIFY — load the dump into a throwaway database, count the rows, drop it. Touches
#              nothing live. This is what you run on a schedule and after any infra change.
#   --apply    RESTORE — load the dump into the real database. If public.pins already exists it is
#              MOVED ASIDE to a per-restore schema pins_attic_<stamp>, never dropped, so the restore
#              is itself reversible. Refuses to overwrite a pins table that has rows unless --force.
#              The dump is applied in a single transaction, and if it fails the moved-aside table is
#              put back — a failed restore leaves the database exactly as it started.
#
# The move-aside-verify-swap-keep-the-old-one shape mirrors the ETL's atomic_swap idiom, so it should
# read as normal to anyone who knows this codebase.
#
# Usage:
#   ./scripts/ops/restore_pins.sh <dump.sql>              # verify only, safe
#   ./scripts/ops/restore_pins.sh <dump.sql> --apply      # restore (pins must be absent or empty)
#   ./scripts/ops/restore_pins.sh <dump.sql> --apply --force   # restore over a NON-empty pins
set -euo pipefail
cd "$(dirname "$0")/../.."

DUMP="${1:-}"
[ -n "$DUMP" ] && [ -f "$DUMP" ] || {
  echo "usage: $0 <dump.sql> [--apply] [--force]" >&2; exit 2; }
shift
APPLY=0; FORCE=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --force) FORCE=1 ;;
    *) echo "✗ unknown flag: $a" >&2; exit 2 ;;
  esac
done

CONTAINER="${ORESCOUT_PG_CONTAINER:-orescout-postgres}"
DB="${ORESCOUT_DB:-miningapp}"
USER_="${ORESCOUT_DB_USER:-postgres}"
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "✗ container '$CONTAINER' not running" >&2; exit 2; }

expected=$(sed -n 's/^-- taken: .*rows: \([0-9]*\) .*/\1/p' "$DUMP" | head -1)
echo "[restore] dump: $DUMP (header claims ${expected:-?} row(s))"

# ---- Always verify first, in a throwaway database -----------------------------------------------
SCRATCH="orescout_restore_check_$$"
cleanup() { docker exec "$CONTAINER" psql -U "$USER_" -d postgres -q \
              -c "DROP DATABASE IF EXISTS \"$SCRATCH\";" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[restore] verifying into throwaway database $SCRATCH ..."
docker exec "$CONTAINER" psql -U "$USER_" -d postgres -q -c "DROP DATABASE IF EXISTS \"$SCRATCH\";" >/dev/null 2>&1
docker exec "$CONTAINER" psql -U "$USER_" -d postgres -q -c "CREATE DATABASE \"$SCRATCH\";" >/dev/null

if ! docker exec -i "$CONTAINER" psql -U "$USER_" -d "$SCRATCH" -v ON_ERROR_STOP=1 -q < "$DUMP" >/dev/null 2>/tmp/orescout_restore_err_$$; then
  echo "✗ restore: the dump FAILED to load into a clean database. It is not a usable backup." >&2
  sed -n '1,15p' /tmp/orescout_restore_err_$$ >&2; rm -f /tmp/orescout_restore_err_$$; exit 1
fi
rm -f /tmp/orescout_restore_err_$$

got=$(docker exec "$CONTAINER" psql -U "$USER_" -d "$SCRATCH" -tAq -c "SELECT count(*) FROM public.pins;")
trg=$(docker exec "$CONTAINER" psql -U "$USER_" -d "$SCRATCH" -tAq -c "
  SELECT count(*) FROM pg_trigger t JOIN pg_proc p ON p.oid=t.tgfoid
  WHERE t.tgrelid='public.pins'::regclass AND NOT t.tgisinternal;")
geom=$(docker exec "$CONTAINER" psql -U "$USER_" -d "$SCRATCH" -tAq -c "
  SELECT count(*) FROM information_schema.columns
  WHERE table_schema='public' AND table_name='pins' AND column_name='geom' AND is_generated='ALWAYS';")
idx=$(docker exec "$CONTAINER" psql -U "$USER_" -d "$SCRATCH" -tAq -c "
  SELECT count(*) FROM pg_indexes WHERE schemaname='public' AND tablename='pins';")

echo "[restore]   rows restored:        $got${expected:+ (dump header said $expected)}"
echo "[restore]   working triggers:     $trg  (expect 1 — proves update_updated_at() came along)"
echo "[restore]   generated geom col:   $geom  (expect 1)"
echo "[restore]   indexes:              $idx  (expect 3 — pkey + gist + gin)"

fail=0
[ -n "$expected" ] && [ "$got" != "$expected" ] && { echo "✗ row count mismatch" >&2; fail=1; }
[ "$trg"  = "1" ] || { echo "✗ trigger did not survive the round trip" >&2; fail=1; }
[ "$geom" = "1" ] || { echo "✗ generated geom column did not survive" >&2; fail=1; }
[ "$idx" -ge 3 ]  || { echo "✗ indexes did not survive" >&2; fail=1; }
[ "$fail" -eq 0 ] || { echo "✗ restore: VERIFY FAILED — do not rely on this dump" >&2; exit 1; }
echo "[restore] ✓ verify passed — this dump is loadable and complete"

[ "$APPLY" -eq 1 ] || { echo "[restore] verify-only (pass --apply to restore for real)"; exit 0; }

# ---- Apply to the live database -----------------------------------------------------------------
live=$(docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -tAq \
        -c "SELECT COALESCE((SELECT count(*) FROM public.pins), 0);" 2>/dev/null || echo "absent")

if [ "$live" != "absent" ] && [ "$live" != "0" ] && [ "$FORCE" -ne 1 ]; then
  echo "✗ restore: public.pins already holds $live row(s). Refusing to overwrite." >&2
  echo "  Re-run with --force if you really mean to replace live data (the current table will be" >&2
  echo "  renamed, not dropped, so this stays reversible)." >&2
  exit 1
fi

STAMP=$(docker exec "$CONTAINER" date -u +%Y%m%dT%H%M%SZ)
# A UNIQUE schema per restore. A shared attic cannot work: SET SCHEMA carries the table's indexes
# along under their ORIGINAL names, so a second --force collides on `PK_pins already exists in
# schema pins_attic` and the restore dies. Found by rehearsing --force twice.
ATTIC="pins_attic_${STAMP}"
MOVED=0
if [ "$live" != "absent" ]; then
  # MOVE TO ANOTHER SCHEMA, do not RENAME. `ALTER TABLE ... RENAME TO` renames only the table —
  # its indexes (PK_pins, pins_geom_idx, pins_tags_idx), CHECK constraint and trigger keep their
  # original names in `public`, so restoring the dump then dies on `relation "PK_pins" already
  # exists`. The rehearsal hit exactly that and left the database with NO public.pins at all: the
  # old data renamed aside, the new table half-built. SET SCHEMA moves the table together with its
  # indexes and constraints, which frees every name the dump needs.
  echo "[restore] moving live public.pins ($live row(s)) -> ${ATTIC}.pins_kept"
  docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -v ON_ERROR_STOP=1 -q -c "
    CREATE SCHEMA IF NOT EXISTS ${ATTIC};
    ALTER TABLE public.pins SET SCHEMA ${ATTIC};
    ALTER TABLE ${ATTIC}.pins RENAME TO pins_kept;" >/dev/null
  MOVED=1
fi

# -1 wraps the whole dump in ONE transaction, so a failure leaves NOTHING behind rather than a
# half-created table. Combined with the attic move + rollback below, a failed restore returns the
# database to exactly the state it started in.
echo "[restore] applying dump to $DB ..."
if ! docker exec -i "$CONTAINER" psql -U "$USER_" -d "$DB" -v ON_ERROR_STOP=1 -1 -q < "$DUMP" >/dev/null 2>/tmp/orescout_apply_err_$$; then
  echo "✗ restore: applying the dump FAILED — rolling back" >&2
  sed -n '1,10p' /tmp/orescout_apply_err_$$ >&2; rm -f /tmp/orescout_apply_err_$$
  if [ "$MOVED" -eq 1 ]; then
    docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -v ON_ERROR_STOP=1 -q -c "
      DROP TABLE IF EXISTS public.pins CASCADE;
      ALTER TABLE ${ATTIC}.pins_kept SET SCHEMA public;
      ALTER TABLE public.pins_kept RENAME TO pins;
      DROP SCHEMA IF EXISTS ${ATTIC} CASCADE;" >/dev/null
    echo "✓ rolled back: the original public.pins is restored untouched" >&2
  fi
  exit 1
fi
rm -f /tmp/orescout_apply_err_$$
final=$(docker exec "$CONTAINER" psql -U "$USER_" -d "$DB" -tAq -c "SELECT count(*) FROM public.pins;")
echo "[restore] ✓ public.pins restored with $final row(s)"
# NOT `[ test ] && echo ...` — under `set -e` that list returns 1 when the test is false, and the
# false case here is pins being ABSENT, i.e. the real disaster path. The script would have exited
# non-zero after a successful restore. Caught during the rehearsal only because the exit code was
# checked explicitly; a pipe to grep had hidden it.
if [ "$MOVED" -eq 1 ]; then
  echo "[restore]   previous table kept as ${ATTIC}.pins_kept — drop the schema once satisfied"
fi
exit 0
