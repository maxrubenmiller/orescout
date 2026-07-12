#!/usr/bin/env bash
# run.sh — the §6.13 registry-driven ETL orchestrator (skeleton). Reads etl/sources.json and
# dispatches each source BY ROLE to the existing thin per-source adapters. This is the "one place
# that iterates the registry" the plan describes; the per-source pull/build logic still lives in
# the individual scripts (run.sh is the dispatcher, not a reimplementation).
#
# SAFE BY DEFAULT: prints the plan and exits (dry-run). Pass --run to actually execute. Filter to a
# subset with --state <XX> or --key <source_key> (handy for onboarding one new state).
#
#   ./scripts/etl/run.sh                      # dry-run: print the full role-ordered pipeline
#   ./scripts/etl/run.sh --state NV           # dry-run: just NV's sources
#   ./scripts/etl/run.sh --key blmsma_nv --run   # execute one source
#   ./scripts/etl/run.sh provenance            # emit registry-derived data_sources UPSERT SQL
#
# Role dispatch (§6.13 table):
#   base         -> access.loader                     (then classify via unify.sql — separate step)
#   confirm_open -> refresh_confirm_open.sh <state>   (pull + confirm SQL + gates, per state)
#   claims       -> access.loader / refresh_claims.sh
#   reference    -> access.loader                     (builds its own tiles.<key>; engine untouched)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

DO_RUN=0; FILTER_STATE=""; FILTER_KEY=""; SUBCMD="plan"
while [ $# -gt 0 ]; do
  case "$1" in
    --run) DO_RUN=1 ;;
    --state) FILTER_STATE="$(echo "${2:-}" | tr '[:lower:]' '[:upper:]')"; shift ;;
    --key) FILTER_KEY="${2:-}"; shift ;;
    plan|provenance) SUBCMD="$1" ;;
    *) echo "usage: $0 [plan|provenance] [--state XX] [--key KEY] [--run]" >&2; exit 2 ;;
  esac
  shift
done

# ---- provenance: emit registry-derived UPSERT for public.data_sources -------------------------
# Replaces the STATIC columns of the hand-written backfill_data_sources.sql with registry-sourced
# values (source_key, role, vintage, max_age_days, upstream_ref). refreshed_at / last_gate_status
# stay owned by the live refresh jobs (refresh_lib.sh stamp_source), which is why this UPSERTs only
# the descriptive columns and never clobbers a job's freshness stamp.
if [ "$SUBCMD" = "provenance" ]; then
  jq -r '
    # SQL single-quoted literal with proper '\'''\'' escaping (NOT @json, which emits SQL identifiers)
    def sq: "'\''" + (gsub("'\''"; "'\'''\''")) + "'\''";
    "INSERT INTO public.data_sources (source_key, role, vintage, max_age_days, upstream_ref) VALUES",
    ([.sources[] | "  (" +
        (.key|sq) + ", " + (.role|sq) + ", " + (.vintage|sq) + ", " +
        (if .max_age_days == null then "NULL" else (.max_age_days|tostring) end) + ", " +
        ((.upstream_ref // "")|sq) + ")"
     ] | join(",\n")) + "\n" +
    "ON CONFLICT (source_key) DO UPDATE SET" + "\n" +
    "  role = EXCLUDED.role, vintage = EXCLUDED.vintage," + "\n" +
    "  max_age_days = EXCLUDED.max_age_days, upstream_ref = EXCLUDED.upstream_ref;"
  ' "$REG_JSON"
  exit 0
fi

# ---- plan / run: iterate the registry in role order -------------------------------------------
step() { # step <key> <role> <human action> <command-or-"">
  local key="$1" role="$2" action="$3" cmd="$4"
  printf '  [%-12s] %-12s %s\n' "$key" "$role" "$action"
  [ -n "$cmd" ] && printf '                             $ %s\n' "$cmd"
  if [ "$DO_RUN" -eq 1 ] && [ -n "$cmd" ]; then
    echo "                             → running…"
    ( eval "$cmd" )
  fi
}

# Preserve the registry's role order intent: base → confirm_open → claims → reference.
for role in base confirm_open claims reference; do
  for key in $(reg_raw ".sources[] | select(.role==\"$role\") | .key"); do
    [ -n "$FILTER_KEY" ] && [ "$FILTER_KEY" != "$key" ] && continue
    # state filter: keep the source only if it covers the requested state
    if [ -n "$FILTER_STATE" ]; then
      reg_raw ".sources[] | select(.key==\"$key\") | .states[]" | grep -qx "$FILTER_STATE" || continue
    fi
    case "$role" in
      base)
        loader=$(reg_access "$key" loader)
        step "$key" "$role" "load base layer, then classify via unify.sql" "$loader" ;;
      confirm_open)
        # one adapter handles pull + confirm SQL + gates per state
        states=$(reg_raw ".sources[] | select(.key==\"$key\") | .states[]" | tr '[:upper:]' '[:lower:]')
        for st in $states; do
          [ -n "$FILTER_STATE" ] && [ "$st" != "$(echo "$FILTER_STATE"|tr '[:upper:]' '[:lower:]')" ] && continue
          step "$key" "$role" "confirm-open for $st" "./scripts/etl/refresh_confirm_open.sh $st"
        done ;;
      claims)
        loader=$(reg_loader "$key")
        step "$key" "$role" "refresh claims overlay" "./$loader" ;;
      reference)
        loader=$(reg_loader "$key")
        step "$key" "$role" "build display-only tiles.<key> (engine untouched)" "./$loader" ;;
    esac
  done
done

[ "$DO_RUN" -eq 0 ] && echo "" && echo "(dry-run — pass --run to execute; provenance via: $0 provenance)"
