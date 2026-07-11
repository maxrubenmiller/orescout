#!/usr/bin/env bash
# Release watcher (docs/DATA_REFRESH_PLAN.md §2.3): read-only probes of every versioned upstream,
# compared against the registry's stored upstream_watermark. Never downloads, never refreshes —
# it only reports. Class-3 sources (PAD-US / NGDB / WBD) flagged here get a HUMAN-approved bump.
#
#   ./scripts/etl/check_upstream.sh              # compare + report; exit 1 if update/unreachable
#   ./scripts/etl/check_upstream.sh --baseline   # record current upstream state as the watermark
#
# Probes (cheap; curl -q to dodge the machine's curlrc retry trap):
#   padus, ngdb  ScienceBase item JSON -> newest file upload date
#   wbd          S3 HEAD Last-Modified of the national GDB
#   ugrc_ut,     ArcGIS layer JSON editingInfo.lastEditDate (falls back to feature count
#   calfire_ca   when a service omits editingInfo)
# Skipped: mlrs_claims (near-daily churn — cadence-managed by the nightly job + freshness_check),
# static sources (mrds, ca_streams).
set -uo pipefail
cd "$(dirname "$0")/../.."
MODE="${1:-check}"

PSQL=(docker compose exec -T postgres psql -U postgres -d miningapp -v ON_ERROR_STOP=1)
q() { "${PSQL[@]}" -tAq -c "$1"; }
UA="OreScout-watcher/0.1"

probe_sciencebase() { # <item_id> -> newest file date
  curl -sq -A "$UA" --max-time 30 "https://www.sciencebase.gov/catalog/item/$1?format=json" \
    | python3 -c "import json,sys
try:
  d=json.load(sys.stdin); fs=d.get('files') or []
  print(max((f.get('dateUploaded') or '') for f in fs) if fs else 'NO-FILES')
except Exception: print('UNREACHABLE')" 2>/dev/null || echo UNREACHABLE
}
probe_s3() { # <url> -> Last-Modified
  curl -sq -A "$UA" --max-time 30 -I "$1" | awk -F': ' 'tolower($1)=="last-modified" {print $2}' | tr -d '\r'
}
probe_arcgis() { # <layer_url> -> lastEditDate (epoch ms) or feature count
  curl -sq -A "$UA" --max-time 30 "$1?f=json" | python3 -c "import json,sys
try:
  d=json.load(sys.stdin)
  le=(d.get('editingInfo') or {}).get('lastEditDate')
  print(f'edit:{le}' if le else 'COUNT-FALLBACK')
except Exception: print('UNREACHABLE')" 2>/dev/null || echo UNREACHABLE
}
probe_arcgis_count() { # <layer_url> -> feature count
  curl -sq -A "$UA" --max-time 60 "$1/query?where=1%3D1&returnCountOnly=true&f=json" \
    | python3 -c "import json,sys
try: print('count:%s' % json.load(sys.stdin)['count'])
except Exception: print('UNREACHABLE')" 2>/dev/null || echo UNREACHABLE
}

probe() { # <source_key> -> current upstream marker
  case "$1" in
    padus) probe_sciencebase 6759abcfd34edfeb8710a004 ;;
    ngdb_prospectivity) probe_sciencebase 63a107a0d34e0de3a1f2795f ;;
    wbd) probe_s3 "https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/WBD/National/GDB/WBD_National_GDB.zip" ;;
    ugrc_ut)
      local u="https://gis.trustlands.utah.gov/server/rest/services/Ownership/UT_SITLA_Ownership_LandOwnership_WM/FeatureServer/0"
      local r; r=$(probe_arcgis "$u"); [ "$r" = "COUNT-FALLBACK" ] && r=$(probe_arcgis_count "$u"); echo "$r" ;;
    calfire_ca)
      local u="https://jUJYIo9tSA7EHvfZ.svcs1.arcgis.com/jUJYIo9tSA7EHvfZ/arcgis/rest/services/Public_Land_Ownership_view/FeatureServer/0"
      local r; r=$(probe_arcgis "$u"); [ "$r" = "COUNT-FALLBACK" ] && r=$(probe_arcgis_count "$u"); echo "$r" ;;
    *) echo SKIP ;;
  esac
}

SOURCES="padus ngdb_prospectivity wbd ugrc_ut calfire_ca"
alerts=0
printf "%-20s %-14s %-34s %s\n" "source" "status" "upstream now" "watermark"
for key in $SOURCES; do
  cur=$(probe "$key")
  wm=$(q "SELECT coalesce(upstream_watermark,'') FROM public.data_sources WHERE source_key='$key'")
  if [ "$MODE" = "--baseline" ]; then
    [ "$cur" = "UNREACHABLE" ] || q "UPDATE public.data_sources SET upstream_watermark = \$q\$${cur}\$q\$, updated_at = now() WHERE source_key='$key'" >/dev/null
    printf "%-20s %-14s %-34s %s\n" "$key" "baselined" "$cur" "(recorded)"
    [ "$cur" = "UNREACHABLE" ] && { printf "%-20s %-14s\n" "$key" "UNREACHABLE"; alerts=$((alerts+1)); }
    continue
  fi
  if [ "$cur" = "UNREACHABLE" ]; then status="UNREACHABLE"; alerts=$((alerts+1))
  elif [ -z "$wm" ]; then status="no-baseline"; alerts=$((alerts+1))
  elif [ "$cur" = "$wm" ]; then status="current"
  else status="UPDATE-AVAIL"; alerts=$((alerts+1)); fi
  printf "%-20s %-14s %-34s %s\n" "$key" "$status" "$cur" "${wm:-—}"
done

if [ "$MODE" != "--baseline" ] && [ "$alerts" -gt 0 ]; then
  echo; echo "✗ watcher: $alerts source(s) need attention. Class-3 (padus/ngdb/wbd) updates are" >&2
  echo "  HUMAN-APPROVED bumps — see docs/DATA_REFRESH_PLAN.md §3 for each runbook." >&2
  exit 1
fi
[ "$MODE" = "--baseline" ] && exit $(( alerts > 0 ? 1 : 0 ))
echo; echo "✓ watcher: all versioned upstreams match their watermarks"
