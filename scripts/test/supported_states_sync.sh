#!/usr/bin/env bash
# supported_states_sync.sh — guards the §6.13 invariant across the ETL/API boundary. The ETL's
# source of truth is etl/sources.json; the API exposes SupportedStates from appsettings.json (read
# by /meta + the Geocoder in-region filter). These MUST agree — a state present in the registry but
# missing from appsettings (or vice versa) means the map masks/geocodes a different set than the
# data covers. This makes that drift a caught error instead of a silent bug.
#
# Run: ./scripts/test/supported_states_sync.sh   (no DB / no network; jq only)
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/etl/registry_lib.sh

REG=$(reg_states_all | sort | paste -sd',' -)
APP=$(jq -r '.SupportedStates | sort | join(",")' src/OreScout.Api/appsettings.json)

if [ "$REG" = "$APP" ]; then
  echo "✓ SupportedStates in sync: $REG"
else
  echo "✗ SupportedStates DRIFT between etl/sources.json and appsettings.json:" >&2
  echo "    registry:    $REG" >&2
  echo "    appsettings: $APP" >&2
  echo "  Adding a state = edit BOTH (etl/sources.json entry + appsettings SupportedStates)." >&2
  echo "  See docs/ADD_A_STATE.md." >&2
  exit 1
fi
