-- ============================================================================
-- OreScout — waterways overlay build (docs/planning/PROJECT_PLAN.md §6.13 `reference` role).
-- Promotes staging.nhdplus_hr_flowlines (USGS NHDPlus HR NHDFlowline: FType=460 streams
-- + FCode=55800 artificial paths, loaded by scripts/etl/pull_nhdplus_hr.sh) into tiles.waterways.
-- Replaces the former CDFW `ca_streams` build (docs/WATERWAYS_NHDPLUS_HR_PLAN.md).
--
-- REFERENCE-ONLY: display tiles; never feeds orescout_base_verdict / the assessment
-- engine (streams aren't a legality input). Upholds the §6.13 invariant.
--
-- Derives the two attributes the overlay features need from NHD:
--   flow_class : FCode 46006 (perennial) + 55800 (artificial path = the always-wet centerline
--                through wide rivers/lakes) -> 'perennial'; everything else (46003 intermittent,
--                46007 ephemeral, 46000 unspecified) -> 'intermittent' (owner decision:
--                ephemeral + unspecified collapse into intermittent; dashed on the map).
--   flow_dir   : FlowDir (1 = WithDigitized -> draw chevron; 0 = Uninitialized -> none).
-- Geometry vertex order (= downstream) is preserved from the loader -> chevrons follow it.
-- Clipped to the 8-state boundary (public.supported_region): keep whole lines that
-- intersect an in-scope state (the out-of-scope mask hides any neighbor-state overdraw).
-- Idempotent: drops and rebuilds.
-- ============================================================================

-- Speeds up the in-scope intersect on a multi-million-row staging table (no-op if present).
CREATE INDEX IF NOT EXISTS nhdplus_hr_flowlines_geom_idx
    ON staging.nhdplus_hr_flowlines USING GIST (geom);

DROP TABLE IF EXISTS tiles.waterways;

CREATE TABLE tiles.waterways (
    ogc_fid       bigserial PRIMARY KEY,
    geom          geometry(MultiLineString, 4326),
    name          text,        -- GNIS_Name
    flow_class    text,        -- 'perennial' | 'intermittent'
    flow_dir      smallint,    -- FlowDir: 1 = draw chevron, 0 = direction not established
    permanent_id  text,        -- NHD Permanent_Identifier (stable key)
    reachcode     text,        -- left 8 = HUC8 (join to WBD / §5.3)
    state_nm      text,        -- dominant in-scope state (display provenance; not queried by app)
    data_vintage  text,
    source_key    text         -- registry provenance (§6.13)
);

-- Dissolved 8-state boundary for the in-scope filter (built once).
DROP TABLE IF EXISTS _region8;
CREATE TEMP TABLE _region8 AS SELECT ST_Union(geom) AS geom FROM public.supported_region;
CREATE INDEX ON _region8 USING GIST (geom);

INSERT INTO tiles.waterways
    (geom, name, flow_class, flow_dir, permanent_id, reachcode, state_nm, data_vintage, source_key)
SELECT
    ST_Multi(s.geom),
    NULLIF(s.gnis_name, ''),
    CASE WHEN s.fcode IN (46006, 55800) THEN 'perennial' ELSE 'intermittent' END,
    s.flowdir::smallint,
    s.permanent_identifier,
    NULLIF(s.reachcode, ''),
    (SELECT r.state_code FROM public.supported_region r
        WHERE ST_Intersects(ST_StartPoint(ST_GeometryN(s.geom, 1)), r.geom) LIMIT 1),
    'USGS NHDPlus HR (per-HU4 VPU/Current — dev ingest; prod upgrades to NR2)',
    'nhdplus_hr_waterways'
FROM staging.nhdplus_hr_flowlines s
JOIN _region8 r ON ST_Intersects(s.geom, r.geom)
WHERE s.geom IS NOT NULL AND NOT ST_IsEmpty(s.geom);

CREATE INDEX waterways_geom_idx  ON tiles.waterways USING GIST (geom);
CREATE INDEX waterways_state_idx ON tiles.waterways (state_nm);
CREATE INDEX waterways_class_idx ON tiles.waterways (flow_class);

-- pg_tileserv's low-priv role must be able to read it (§6.8).
GRANT SELECT ON tiles.waterways TO tileserv_ro;

-- Validation readout.
SELECT flow_class, count(*) AS lines, count(name) AS named FROM tiles.waterways GROUP BY flow_class ORDER BY flow_class;
SELECT count(*) FILTER (WHERE flow_dir = 1) AS directional, count(*) AS total FROM tiles.waterways;
SELECT state_nm, count(*) FROM tiles.waterways GROUP BY state_nm ORDER BY 2 DESC;
