-- ============================================================================
-- OreScout — database bootstrap (docs/planning/PROJECT_PLAN.md §6.5 / §6.8 / §6.11)
--
-- Owns: extensions, schemas, the low-privilege pg_tileserv role, the `meta`
-- table, and the `supported_region` table used by the Stage-0 in-region gate.
--
-- Does NOT own `public.pins` — that table belongs to EF Core migrations (§6.11).
-- Does NOT own the spatial layers — `tiles.legality_polygons` is built by the ETL
-- unify step and `tiles.claims_polygons` by the nightly claims job.
--
-- Idempotent: safe to re-run.
-- ============================================================================

-- ---- Extensions ------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS postgis;

-- ---- Schemas ---------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS tiles;     -- tile-served layers ONLY (pg_tileserv sees this)
CREATE SCHEMA IF NOT EXISTS staging;   -- raw ETL loads; intermediate, never tile-served

-- ---- Low-privilege role for pg_tileserv ------------------------------------
-- The tile server connects as this role. It has USAGE on `tiles` only and SELECT
-- on its tables, and NO access to public.pins — so user data can never leak as a
-- tile, even by accident (§6.8 gap G).
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'tileserv_ro') THEN
    CREATE ROLE tileserv_ro LOGIN PASSWORD 'tileserv';
  END IF;
END
$$;

GRANT USAGE ON SCHEMA tiles TO tileserv_ro;
GRANT SELECT ON ALL TABLES IN SCHEMA tiles TO tileserv_ro;
-- Future tables created in `tiles` are auto-granted to the role:
ALTER DEFAULT PRIVILEGES IN SCHEMA tiles GRANT SELECT ON TABLES TO tileserv_ro;
-- Explicitly ensure no access to the public schema's tables (defense in depth):
REVOKE ALL ON SCHEMA public FROM tileserv_ro;

-- ---- meta: data-vintage surfaced via GET /api/v1/meta ----------------------
-- Populated by the ETL pipelines; read by the API. Key/value keeps it open-ended.
CREATE TABLE IF NOT EXISTS public.meta (
    key        text PRIMARY KEY,
    value      text,
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Seed the known keys (values filled in by ETL; NULL = "not yet loaded").
INSERT INTO public.meta (key, value) VALUES
    ('padus_version', NULL),
    ('padus_date',    NULL),
    ('sma_date',      NULL),
    ('claims_as_of',  NULL)
ON CONFLICT (key) DO NOTHING;

-- ---- supported_region: the 8-state boundary (Stage-0 in-region gate, §6.4) --
-- Populated by the ETL from the 8-state subset of us-states.geojson. Until then
-- it is empty; orescout_in_region() treats an empty table as "gate disabled"
-- (returns true) so local dev works before the ETL has run — see 02_classifier.sql.
CREATE TABLE IF NOT EXISTS public.supported_region (
    state_code text PRIMARY KEY,
    geom       geometry(MultiPolygon, 4326) NOT NULL
);
CREATE INDEX IF NOT EXISTS supported_region_geom_idx
    ON public.supported_region USING GIST (geom);

-- ---- data_sources: per-source freshness registry (docs/DATA_REFRESH_PLAN.md) --
-- One row per data source: vintage, when we last refreshed it, how old is too old
-- (NULL = static source), and the last refresh-gate outcome. Written by the ETL
-- jobs (scripts/etl/refresh_lib.sh stamp_source); read by GET /api/v1/meta and
-- the UI freshness badges. Backfill for pre-registry DBs: scripts/etl/backfill_data_sources.sql.
CREATE TABLE IF NOT EXISTS public.data_sources (
    source_key       text PRIMARY KEY,
    role             text,          -- base | confirm_open | claims | reference (§6.13 vocabulary)
    vintage          text,
    refreshed_at     timestamptz,
    max_age_days     int,           -- NULL = static, never stale
    last_gate_status text,
    upstream_ref     text,
    upstream_watermark text,     -- last observed upstream version marker (check_upstream.sh)
    updated_at       timestamptz NOT NULL DEFAULT now()
);
