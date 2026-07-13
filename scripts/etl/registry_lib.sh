#!/usr/bin/env bash
# registry_lib.sh — the ONE reader for the per-state source registry (etl/sources.json,
# PROJECT_PLAN §6.13). Source this from any ETL script that needs a per-state parameter:
#
#   source "$(dirname "$0")/registry_lib.sh"
#   URL=$(reg_access blmsma_nv url)
#   PUB=$(reg_confirm blmsma_nv public_predicate)
#   for st in $(reg_states_all); do … ; done
#
# Design: sources.json is the single source of truth; these helpers are the only place that
# knows its shape. Adding a state = one entry there (§6.13 🔒 invariant). Requires jq (>=1.6);
# jq 1.7.1 ships on the dev box — see docs/ADD_A_STATE.md. All lookups are BY KEY (the stable
# source_key), never by array position. A missing field is a hard error (fail loud, not silent).

# Resolve the registry path once (repo-root/etl/sources.json), overridable via $REG_JSON.
REG_JSON="${REG_JSON:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/etl/sources.json}"

_reg_require() {
  command -v jq >/dev/null 2>&1 || { echo "registry_lib: jq not found (brew install jq)" >&2; return 1; }
  [ -f "$REG_JSON" ] || { echo "registry_lib: registry not found at $REG_JSON" >&2; return 1; }
}

# reg_raw <jq-filter> — run an arbitrary jq filter against the registry (advanced/escape hatch).
reg_raw() { _reg_require || return 1; jq -r "$1" "$REG_JSON"; }

# _reg_one <key> <jq-filter-relative-to-the-entry> — fetch one field for a source, erroring if
# the key is unknown or the field is absent/null. `$e` is the entry object inside the filter.
_reg_one() {
  _reg_require || return 1
  local key="$1" filter="$2" out
  out=$(jq -er --arg k "$key" '
    (.sources[] | select(.key == $k)) as $e
    | ('"$filter"')
    | if . == null then error("null") else . end
  ' "$REG_JSON" 2>/dev/null) || {
    echo "registry_lib: no value for key='$key' filter='$filter' in $REG_JSON" >&2; return 1; }
  printf '%s' "$out"
}

# --- top-level fields -------------------------------------------------------
reg_field()       { _reg_one "$1" "\$e.$2"; }                 # reg_field padus vintage
reg_role()        { _reg_one "$1" '$e.role'; }
reg_loader()      { _reg_one "$1" '$e.loader // $e.access.loader'; }
reg_attribution() { _reg_one "$1" '$e.attribution'; }
reg_vintage()     { _reg_one "$1" '$e.vintage'; }
reg_upstream()    { _reg_one "$1" '$e.upstream_ref'; }
reg_maxage()      { _reg_one "$1" '$e.max_age_days'; }
reg_sql()         { _reg_one "$1" '$e.sql'; }

# --- access.* ---------------------------------------------------------------
reg_access()      { _reg_one "$1" "\$e.access.$2"; }          # reg_access blmsma_nv url
reg_fields_csv()  { _reg_one "$1" '$e.access.fields | join(",")'; }   # -> "ABBR,NAME"
reg_page()        { _reg_one "$1" '$e.access.page'; }

# --- confirm.* (confirm_open sources) ---------------------------------------
reg_confirm()     { _reg_one "$1" "\$e.confirm.$2"; }         # reg_confirm blmsma_nv public_predicate
reg_schema_cols() { _reg_one "$1" '$e.confirm.schema_cols | join(" ")'; }  # -> "owner geom"

# reg_key_for_state_role <STATE> <ROLE> — the source_key of the (single) source with that role
# covering that state, e.g. reg_key_for_state_role NV confirm_open -> "blmsma_nv". Errors if none.
reg_key_for_state_role() {
  _reg_require || return 1
  local out
  out=$(jq -er --arg s "$1" --arg r "$2" '
    [.sources[] | select(.role==$r and (.states|index($s)))][0].key
    | if . == null then error("none") else . end' "$REG_JSON" 2>/dev/null) || {
    echo "registry_lib: no $2 source for state=$1 in $REG_JSON" >&2; return 1; }
  printf '%s' "$out"
}

# --- state lists (canonical order = first appearance in the registry, i.e. padus's order) ---
# reg_states_all            -> newline list of every distinct state, canonical order
# reg_states_for_role ROLE  -> same, filtered to one role
reg_states_all() {
  _reg_require || return 1
  jq -r 'reduce (.sources[].states[]) as $s ([]; if index($s) then . else . + [$s] end) | .[]' "$REG_JSON"
}
reg_states_for_role() {
  _reg_require || return 1
  jq -r --arg r "$1" '
    reduce (.sources[] | select(.role==$r) | .states[]) as $s
      ([]; if index($s) then . else . + [$s] end) | .[]' "$REG_JSON"
}

# --- formatted state lists (match the exact literals they replace) ----------
reg_states_space()  { reg_states_all | paste -sd' ' -; }                       # "NV CA AZ CO UT NM OR ID"
reg_states_sqlcsv() { reg_states_all | sed "s/.*/'&'/" | paste -sd',' -; }     # "'NV','CA',…"
# reg_states_like <col> -> "col LIKE '%NV%' OR col LIKE '%CA%' OR …"
reg_states_like() {
  local col="$1"
  reg_states_all | sed "s/.*/${col} LIKE '%&%'/" | paste -sd'|' - | sed 's/|/ OR /g'
}
