-- One-shot idempotent backfill of the freshness registry (public.data_sources) for a DB that
-- predates it (docs/DATA_REFRESH_PLAN.md Phase A item 2). Values reflect the actual state of
-- this dev DB's layers at backfill time; jobs overwrite their own rows on every refresh.
-- max_age_days per the plan's staleness-alarm table; NULL = static source.
CREATE TABLE IF NOT EXISTS public.data_sources (
    source_key text PRIMARY KEY, role text, vintage text, refreshed_at timestamptz,
    max_age_days int, last_gate_status text, upstream_ref text,
    updated_at timestamptz NOT NULL DEFAULT now());

INSERT INTO public.data_sources
  (source_key, role, vintage, refreshed_at, max_age_days, last_gate_status, upstream_ref) VALUES
  ('padus', 'base', 'PAD-US 4.1 (2024, ScienceBase State GDBs)', '2026-07-01', 900, 'ok',
   'https://www.sciencebase.gov/catalog/item/6759abcfd34edfeb8710a004'),
  ('calfire_ca', 'confirm_open', 'CAL FIRE land ownership 2024 (CC-BY)', '2026-06-22', 420, 'ok',
   'CAL FIRE Public_Land_Ownership_view FeatureServer'),
  ('ugrc_ut', 'confirm_open', 'Utah SGID/SITLA land ownership (weekly upstream revisions; CC-BY 4.0)', '2026-07-02', 180, 'ok',
   'https://gis.trustlands.utah.gov/server/rest/services/Ownership/UT_SITLA_Ownership_LandOwnership_WM/FeatureServer/0'),
  ('mlrs_claims', 'claims',
   'BLM MLRS not-closed claims (as of ' || coalesce((SELECT value FROM public.meta WHERE key='claims_as_of'), 'unknown') || ')',
   coalesce((SELECT value FROM public.meta WHERE key='claims_as_of')::timestamptz, NULL), 2, 'ok',
   'https://gis.blm.gov/nlsdb/rest/services/HUB/BLM_Natl_MLRS_Mining_Claims_Not_Closed/MapServer/0'),
  ('mrds', 'reference', 'USGS MRDS (static — USGS stopped updates 2011)', '2026-07-09', NULL, 'ok',
   'USGS MRDS Compact FeatureServer'),
  ('ca_streams', 'reference', 'California Streams © CDFW (NHD-derived, static ~2020)', '2026-06-23', NULL, 'ok',
   'CDFW CA_Streams_wm FeatureServer'),
  ('ngdb_prospectivity', 'reference', 'USGS NGDB geochemistry (samples 1962–2023, 2026 release) + historic MRDS records', '2026-07-11', 540, 'ok',
   'https://doi.org/10.5066/P1FXE9GK'),
  ('wbd', 'reference',
   coalesce((SELECT value FROM public.meta WHERE key='wbd_snapshot'), 'WBD national snapshot'), '2026-07-10', 540, 'ok',
   'https://prd-tnm.s3.amazonaws.com/StagedProducts/Hydrography/WBD/National/GDB/WBD_National_GDB.zip')
ON CONFLICT (source_key) DO NOTHING;   -- backfill never overwrites a live job's stamp

SELECT source_key, role, refreshed_at::date, max_age_days,
       (max_age_days IS NOT NULL AND refreshed_at < now() - make_interval(days => max_age_days)) AS stale
FROM public.data_sources ORDER BY source_key;
