-- ============================================================================
-- OreScout — waterways overlay build (PROJECT_PLAN.md §6.13 `reference` role).
-- Promotes staging.ca_streams (raw CDFW "California Streams") into the served
-- tiles.waterways table. REFERENCE-ONLY: this table is display tiles, it never
-- feeds orescout_base_verdict / the assessment engine (streams aren't a legality
-- input). Upholds the §6.13 invariant — adding it touched zero engine code.
--
-- Carries the network attributes (not just geometry) per the "data first,
-- intelligence later" decision so it can later become the prospecting substrate:
-- down_name/down_id (downstream connectivity), the WBD watershed locators, and the
-- GNIS / NHD ids that join back to NHD for perennial vs intermittent + stream order.
-- Idempotent: drops and rebuilds.
-- ============================================================================

DROP TABLE IF EXISTS tiles.waterways;

CREATE TABLE tiles.waterways (
    ogc_fid               bigserial PRIMARY KEY,
    geom                  geometry(MultiLineString, 4326),
    name                  text,
    down_name             text,   -- what this stream flows into (network topology)
    down_id               integer,
    gnis_id               text,
    nhd_id                text,   -- NHD_Permanent_Identifier → join to NHD for stream type/order
    hydrologic_subregion  text,   -- USGS WBD locators (→ §5.3 watershed grouping)
    hydrologic_subbasin   text,   -- HUC8
    state_nm              text,
    data_vintage          text,
    source_key            text    -- registry provenance (§6.13): 'ca_streams'
);

INSERT INTO tiles.waterways
    (geom, name, down_name, down_id, gnis_id, nhd_id,
     hydrologic_subregion, hydrologic_subbasin, state_nm, data_vintage, source_key)
SELECT
    ST_Multi(s.geom),
    NULLIF(s.name, ''),
    NULLIF(s.down_name, ''),
    s.down_id,
    NULLIF(s.gnis_id, ''),
    NULLIF(s.nhd_permanent_identifier, ''),
    NULLIF(s.hydrologic_subregion, ''),
    NULLIF(s.hydrologic_subbasin, ''),
    'California',
    'CDFW California Streams (NHD-derived, static ~2020)',
    'ca_streams'
FROM staging.ca_streams s
WHERE s.geom IS NOT NULL
  AND NOT ST_IsEmpty(s.geom);

CREATE INDEX waterways_geom_idx  ON tiles.waterways USING GIST (geom);
CREATE INDEX waterways_state_idx ON tiles.waterways (state_nm);

-- pg_tileserv's low-priv role must be able to read it (§6.8).
GRANT SELECT ON tiles.waterways TO tileserv_ro;

SELECT state_nm, count(*) AS lines, count(name) AS named FROM tiles.waterways GROUP BY state_nm;
