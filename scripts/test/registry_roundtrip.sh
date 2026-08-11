#!/usr/bin/env bash
# registry_roundtrip.sh — proves etl/sources.json (PROJECT_PLAN §6.13) was transcribed FAITHFULLY
# from the scripts it consolidates. Asserts, for every source, that registry_lib.sh returns exactly
# the value the old hardcoded case block used. This is the Phase-0 safety net: if this passes, the
# scripts can safely be pointed at the registry (Phases 1–3) with zero behavior change.
#
# Pure string comparison, no DB / no network. Run: ./scripts/test/registry_roundtrip.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

fail=0
chk() { # chk <label> <expected> <actual>
  if [ "$2" = "$3" ]; then printf '  ✓ %s\n' "$1"
  else printf '  ✗ %s\n     expected: %s\n     actual:   %s\n' "$1" "$2" "$3"; fail=1; fi
}

echo "== state lists (must equal the literals in the loaders) =="
chk "reg_states_space"  "NV CA AZ CO UT NM OR ID"                       "$(reg_states_space)"
chk "reg_states_sqlcsv" "'NV','CA','AZ','CO','UT','NM','OR','ID'"       "$(reg_states_sqlcsv)"
chk "reg_states_like(states)" \
  "states LIKE '%NV%' OR states LIKE '%CA%' OR states LIKE '%AZ%' OR states LIKE '%CO%' OR states LIKE '%UT%' OR states LIKE '%NM%' OR states LIKE '%OR%' OR states LIKE '%ID%'" \
  "$(reg_states_like states)"

echo "== pull_sma.sh access params (URL / FIELDS / PAGE per state) =="
chk "nv url"    "https://services1.arcgis.com/KbxwQRRfWyEYLgp4/arcgis/rest/services/Surface_Management_Agency_SMA/FeatureServer/0/query" "$(reg_access blmsma_nv url)"
chk "nv fields" "ABBR,NAME"          "$(reg_fields_csv blmsma_nv)"
chk "az fields" "CATEGORY"           "$(reg_fields_csv blmsma_az)"
chk "co fields" "adm_code,adm_manage" "$(reg_fields_csv blmsma_co)"
chk "nm fields" "own"                "$(reg_fields_csv blmsma_nm)"
chk "or fields" "LandManager"        "$(reg_fields_csv odf_or)"
chk "id fields" "MGMT_AGNCY,AGNCY_NAME" "$(reg_fields_csv idl_id)"
chk "id url"    "https://gis1.idl.idaho.gov/arcgis/rest/services/Portal/Idaho_Surface_Management_Agency/FeatureServer/0/query" "$(reg_access idl_id url)"
chk "nv page"   "2000"               "$(reg_page blmsma_nv)"

echo "== gen_confirm_open.sh params (staging / public_predicate / crs / sliver / attribution / vintage) =="
chk "nv staging" "staging.sma_nv"    "$(reg_confirm blmsma_nv staging)"
chk "nv pub"     "upper(abbr) IN ('BLM','FS','NPS','FWS','BR')" "$(reg_confirm blmsma_nv public_predicate)"
chk "az pub"     "category IN ('BLM','USFS','NPS','USFWS','BR','Bankhead-Jones Act')" "$(reg_confirm blmsma_az public_predicate)"
chk "co pub"     "upper(adm_code) IN ('BLM','BLM_LU','USFS','USFS_LU','USFS_NG','NPS','USFW','BOR')" "$(reg_confirm blmsma_co public_predicate)"
chk "nm pub"     "upper(own) IN ('BLM','FS','NPS','FWS','BOR','OFA','DOA')" "$(reg_confirm blmsma_nm public_predicate)"
chk "or pub"     "landmanager IN ('BLM','USFS','FWS','NPS','USBR','USACE','BPA','GSA','USDA','FAA')" "$(reg_confirm odf_or public_predicate)"
chk "id pub"     "upper(mgmt_agncy) IN ('BLM','USFS','NPS','NWR','BOR','COE','LU_DOI','LU_USDA')" "$(reg_confirm idl_id public_predicate)"
chk "nv crs"     "5070"              "$(reg_confirm blmsma_nv crs)"
chk "nv sliver"  "1000"              "$(reg_confirm blmsma_nv sliver_min_m2)"
chk "nv attr"    "BLM Nevada Surface Management Agency" "$(reg_attribution blmsma_nv)"
chk "or attr"    "Oregon Land Ownership © ODF"          "$(reg_attribution odf_or)"
chk "id vintage" "IDL SMA (republished 2026-07-07)"     "$(reg_vintage idl_id)"

echo "== refresh_confirm_open.sh params (staging / schema_cols / loader / sql / vintage / ref / maxage) =="
chk "ut schema"  "owner geom"        "$(reg_schema_cols ugrc_ut)"
chk "ca schema"  "own_level geom"    "$(reg_schema_cols calfire_ca)"
chk "nv schema"  "geom"              "$(reg_schema_cols blmsma_nv)"
chk "ut loader"  "scripts/etl/pull_ugrc.sh"   "$(reg_loader ugrc_ut)"
chk "ca loader"  "scripts/etl/pull_calfire.sh" "$(reg_loader calfire_ca)"
chk "nv loader"  "scripts/etl/pull_sma.sh"    "$(reg_loader blmsma_nv)"
chk "ca sql"     "scripts/etl/confirm_open_ca.sql" "$(reg_sql calfire_ca)"
chk "nv sql"     "generated"         "$(reg_sql blmsma_nv)"
chk "ut maxage"  "180"               "$(reg_maxage ugrc_ut)"
chk "ca maxage"  "420"               "$(reg_maxage calfire_ca)"
chk "co maxage"  "365"               "$(reg_maxage blmsma_co)"
chk "nv maxage"  "540"               "$(reg_maxage blmsma_nv)"
chk "ut ref"     "https://gis.trustlands.utah.gov/server/rest/services/Ownership/UT_SITLA_Ownership_LandOwnership_WM/FeatureServer/0" "$(reg_upstream ugrc_ut)"

echo "== confirm_open (CA/UT bespoke) confirm params =="
chk "ca pub"     "own_level = 'Federal'"        "$(reg_confirm calfire_ca public_predicate)"
chk "ca crs"     "3310"                         "$(reg_confirm calfire_ca crs)"
chk "ut pub"     "owner = 'Federal'" "$(reg_confirm ugrc_ut public_predicate)"
chk "ut crs"     "26912"                        "$(reg_confirm ugrc_ut crs)"
chk "ut carve"   "owner IS NULL OR owner <> 'Federal'" "$(reg_confirm ugrc_ut carve_private)"
chk "ut sliver"  "500"                          "$(reg_confirm ugrc_ut sliver_min_m2)"

echo "== mrds reference details (popup-enrichment loader) =="
chk "mrds details loader" "scripts/etl/pull_mrds_details.sh" "$(reg_raw '.sources[]|select(.key=="mrds").details.loader')"
chk "mrds details source" "https://mrdata.usgs.gov/mrds/rdbms-tab.zip" "$(reg_raw '.sources[]|select(.key=="mrds").details.source')"
chk "mrds details join_key" "dep_id" "$(reg_raw '.sources[]|select(.key=="mrds").details.join_key')"

if [ "$fail" -eq 0 ]; then echo ""; echo "ALL GREEN — registry transcription is faithful."; else
  echo ""; echo "FAILURES above — fix etl/sources.json before wiring scripts to it." >&2; exit 1; fi
