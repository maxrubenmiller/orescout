#!/usr/bin/env bash
# OreScout refresh library (docs/DATA_REFRESH_PLAN.md, Phase A item 1).
#
# The five safety patterns every refresh job needs, extracted from the hardened claims refresh
# (IMP-13) into sourceable functions. Contract: a job builds into `<table>_new`, then calls the
# gates and the swap; ANY failure exits non-zero with the LIVE table untouched. Same code on dev
# (docker compose psql) and prod (override REFRESH_PSQL with a DATABASE_URL psql).
#
# Usage (from a job script):
#   source "$(dirname "$0")/refresh_lib.sh"
#   refresh_lock "myjob"
#   ... build staging + tiles.mytable_new (indexes named *_new*, GRANTs applied) ...
#   assert_schema tiles.mytable_new geom tier vintage
#   count_gate    tiles.mytable 25          # _new within ±25% of live (skips if no live table)
#   atomic_swap   tiles.mytable             # _new -> live in one transaction; old dropped after
#   stamp_source  mykey reference "vintage str" 180 "https://upstream/ref" ok
#
# Bash 3.2-safe (macOS). Functions echo progress on stdout; failures go to stderr.
# Regression harness: scripts/test/refresh_lib_test.sh (throwaway tables; live tables untouched).

# ---- plumbing ---------------------------------------------------------------
# REFRESH_PSQL: full psql command as a string (overridable for prod). Executed via eval so a
# multi-word default works under bash 3.2 without arrays-in-env.
REFRESH_PSQL="${REFRESH_PSQL:-docker compose exec -T postgres psql -U postgres -d miningapp}"

_rq()   { eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -tAq -c \"\$1\""; }   # query, print result
_rx()   { eval "$REFRESH_PSQL -v ON_ERROR_STOP=1 -q  -c \"\$1\""; }    # execute, quiet
rfail() { echo "✗ refresh: $*" >&2; exit 1; }

# ---- lock -------------------------------------------------------------------
# mkdir-based (atomic on all filesystems; flock is not on macOS). Auto-released on exit.
refresh_lock() {
  local name="${1:?lock name}" dir
  dir="${TMPDIR:-/tmp}/orescout_refresh_${name}.lock"
  if ! mkdir "$dir" 2>/dev/null; then
    rfail "another '$name' refresh appears to be running (lock: $dir). Remove it only if you are sure."
  fi
  # shellcheck disable=SC2064  # expand $dir now, on purpose
  trap "rmdir '$dir' 2>/dev/null" EXIT
  echo "[refresh] lock acquired: $name"
}

# ---- schema assertion --------------------------------------------------------
# assert_schema <schema.table> <col> [col...]  — every named column must exist.
assert_schema() {
  local tbl="${1:?table}"; shift
  [ "$(_rq "SELECT to_regclass('$tbl') IS NOT NULL")" = "t" ] || rfail "$tbl does not exist"
  local col missing=""
  for col in "$@"; do
    [ "$(_rq "SELECT count(*) FROM information_schema.columns
              WHERE table_schema||'.'||table_name = '$tbl' AND column_name = '$col'")" = "1" ] \
      || missing="$missing $col"
  done
  [ -z "$missing" ] || rfail "$tbl missing expected column(s):$missing"
  echo "[refresh] schema ok: $tbl ($*)"
}

# ---- row-count sanity gate ----------------------------------------------------
# count_gate <schema.table> <pct>  — <table>_new must be non-empty and within ±pct% of the live
# table. Skips the band check (with a message) when the live table is missing/empty (first run).
count_gate() {
  local tbl="${1:?table}" pct="${2:?pct}" newn liven lo hi
  newn=$(_rq "SELECT count(*) FROM ${tbl}_new") || rfail "count_gate: ${tbl}_new unreadable"
  [ "$newn" -gt 0 ] || rfail "count_gate: ${tbl}_new is EMPTY — refusing to swap"
  if [ "$(_rq "SELECT to_regclass('$tbl') IS NOT NULL")" != "t" ]; then
    echo "[refresh] count gate skipped (no live $tbl yet): new=$newn"; return 0
  fi
  liven=$(_rq "SELECT count(*) FROM $tbl")
  if [ "$liven" -eq 0 ]; then
    echo "[refresh] count gate skipped (live $tbl empty): new=$newn"; return 0
  fi
  lo=$(( liven * (100 - pct) / 100 )); hi=$(( liven * (100 + pct) / 100 ))
  if [ "$newn" -lt "$lo" ] || [ "$newn" -gt "$hi" ]; then
    rfail "count gate: ${tbl}_new=$newn outside ±${pct}% of live=$liven (allowed $lo..$hi). ${tbl}_new left for inspection."
  fi
  echo "[refresh] count gate ok: new=$newn vs live=$liven (±${pct}%)"
}

# ---- atomic swap ---------------------------------------------------------------
# atomic_swap <schema.table> — renames live -> _old and _new -> live in ONE transaction, then
# drops _old and normalizes index names (strips the '_new' infix) so repeated runs don't collide.
atomic_swap() {
  local tbl="${1:?table}" sch="${1%%.*}" name="${1##*.}"
  [ "$(_rq "SELECT to_regclass('${tbl}_new') IS NOT NULL")" = "t" ] || rfail "atomic_swap: ${tbl}_new missing"
  _rx "DROP TABLE IF EXISTS ${tbl}_old;" || rfail "atomic_swap: could not clear ${tbl}_old"
  _rx "BEGIN;
       ALTER TABLE IF EXISTS ${tbl} RENAME TO ${name}_old;
       ALTER TABLE ${tbl}_new RENAME TO ${name};
       COMMIT;" || rfail "atomic_swap: swap transaction failed — live table unchanged"
  _rx "DROP TABLE IF EXISTS ${tbl}_old;"
  # normalize index names: <anything>_new<rest> -> <anything><rest> (skip on collision)
  local idx
  for idx in $(_rq "SELECT indexname FROM pg_indexes
                    WHERE schemaname='$sch' AND tablename='$name' AND indexname LIKE '%_new%'"); do
    _rx "ALTER INDEX ${sch}.\"${idx}\" RENAME TO \"$(echo "$idx" | sed 's/_new//')\";" \
      || echo "[refresh] note: kept index name $idx (rename collision)"
  done

  # ...and sequence names, for the same reason. A bigserial/identity sequence created on <tbl>_new
  # keeps its '_new' name through the table rename, so it lingers attached to the LIVE table. The
  # next build's CREATE SEQUENCE <tbl>_new_..._seq then collides with it. Jobs that let Postgres
  # auto-name (bigserial) never noticed — Postgres just appends a digit, which is why this schema
  # accumulated claims_polygons_new_ogc_fid_seq1 and friends. A job that names the sequence
  # explicitly fails outright on the second run, which is how this was finally found.
  # Matched by ownership rather than by name pattern so nothing unrelated is touched.
  local seq
  for seq in $(_rq "SELECT s.relname
                    FROM pg_class s
                    JOIN pg_depend d ON d.objid = s.oid AND d.deptype = 'a'
                    JOIN pg_class t ON t.oid = d.refobjid
                    JOIN pg_namespace n ON n.oid = s.relnamespace
                    WHERE s.relkind = 'S' AND n.nspname = '$sch'
                      AND t.relname = '$name' AND s.relname LIKE '%\\_new%'"); do
    _rx "ALTER SEQUENCE ${sch}.\"${seq}\" RENAME TO \"$(echo "$seq" | sed 's/_new//')\";" \
      || echo "[refresh] note: kept sequence name $seq (rename collision)"
  done
  echo "[refresh] swapped: $tbl is live ($(_rq "SELECT count(*) FROM $tbl") rows)"
}

# ---- legality generation stamp (review finding PP-6) -----------------------------
# tiles.legality_polygons and its derived tables (legality_lowzoom, legality_display,
# legality_display_lowzoom) must be built from the same generation of the source. Nothing recorded
# that: the derived tables have no vintage column, no public.meta entry and no data_sources row, so
# a job that rebuilt the source without the derivatives left the map contradicting the verdict with
# no way to detect it. Two stamps, compared by scripts/test/display_sync_check.sh:
#   stamp_legality_generation   — call right after the source table becomes live
#   stamp_display_generation    — call after the derived tables are rebuilt; copies the source's
#                                 current value, so a missed derived rebuild leaves them unequal.
stamp_legality_generation() {
  local gen="${1:-}"
  [ -n "$gen" ] || gen="$(date -u +%Y%m%dT%H%M%SZ)"
  _rx "INSERT INTO public.meta (key, value) VALUES ('legality_generation', '$gen')
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();" \
    || rfail "stamp_legality_generation failed"
  echo "[refresh] legality generation: $gen"
}

stamp_display_generation() {
  _rx "INSERT INTO public.meta (key, value)
       SELECT 'legality_display_generation', value FROM public.meta WHERE key = 'legality_generation'
       ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now();" \
    || rfail "stamp_display_generation failed"
  echo "[refresh] display generation synced to legality generation"
}

# ---- freshness registry stamp ---------------------------------------------------
# stamp_source <key> <role> <vintage> <max_age_days|-> <upstream_ref> <status> [watermark]
# Upserts public.data_sources (creates it if this DB predates the registry). The optional
# watermark records the upstream version marker this refresh consumed (check_upstream.sh
# compares live upstream state against it).
stamp_source() {
  local key="${1:?key}" role="${2:?role}" vintage="${3:?vintage}" maxage="${4:--}" ref="${5:-}" status="${6:-ok}" wm="${7:-}"
  local maxage_sql="NULL"; [ "$maxage" != "-" ] && maxage_sql="$maxage"
  _rx "CREATE TABLE IF NOT EXISTS public.data_sources (
         source_key       text PRIMARY KEY,
         role             text,
         vintage          text,
         refreshed_at     timestamptz,
         max_age_days     int,
         last_gate_status text,
         upstream_ref     text,
         upstream_watermark text,
         updated_at       timestamptz NOT NULL DEFAULT now());"
  _rx "ALTER TABLE public.data_sources ADD COLUMN IF NOT EXISTS upstream_watermark text;"
  local wm_sql="NULL"; [ -n "$wm" ] && wm_sql="\$q\$${wm}\$q\$"
  _rx "INSERT INTO public.data_sources
         (source_key, role, vintage, refreshed_at, max_age_days, last_gate_status, upstream_ref, upstream_watermark, updated_at)
       VALUES ('$key', '$role', \$q\$${vintage}\$q\$, now(), $maxage_sql, '$status', \$q\$${ref}\$q\$, $wm_sql, now())
       ON CONFLICT (source_key) DO UPDATE SET
         role = EXCLUDED.role, vintage = EXCLUDED.vintage, refreshed_at = EXCLUDED.refreshed_at,
         max_age_days = EXCLUDED.max_age_days, last_gate_status = EXCLUDED.last_gate_status,
         upstream_ref = EXCLUDED.upstream_ref, updated_at = now(),
         upstream_watermark = COALESCE(EXCLUDED.upstream_watermark, public.data_sources.upstream_watermark);" \
    || rfail "stamp_source: registry upsert failed for $key"
  echo "[refresh] stamped: $key ($vintage)"
}
