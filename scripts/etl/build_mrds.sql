-- ============================================================================
-- OreScout — MRDS gold overlay build (Tier A; PROJECT_PLAN §6.13 `reference` role).
-- Promotes staging.mrds_gold (USGS MRDS, gold-filtered) into the served tiles.mrds
-- table. REFERENCE-ONLY: display tiles, it never feeds orescout_base_verdict / the
-- assessment engine (mineral occurrences aren't a legality input). Upholds the §6.13
-- invariant — adding it touches zero engine code.
--
-- Clipped to the 8 supported states (staging.us_states8) so envelope-slivers of
-- WY/MT/TX are dropped and every point is tagged with its state. `is_producer` flags
-- (past) producers — the stronger prospecting signal, and the §5.3 Signal-3 anchor.
-- Static source — USGS stopped updating MRDS in 2011; the UI labels it historical.
-- Idempotent: drops and rebuilds.
-- ============================================================================

DROP TABLE IF EXISTS tiles.mrds;

CREATE TABLE tiles.mrds (
    ogc_fid       bigserial PRIMARY KEY,
    geom          geometry(Point, 4326),
    site_name     text,
    dev_stat      text,      -- Occurrence / Prospect / Producer / Past Producer
    commodities   text,      -- raw CODE_LIST (space-delimited commodity codes; always incl. AU)
    grade         text,      -- MRDS deposit grade/size class code (raw)
    url           text,      -- deep link to the full USGS MRDS record (show-mrds.php?dep_id=…)
    dep_id        bigint,    -- MRDS deposit id (stable key; also the id in `url`)
    is_producer   boolean,   -- DEV_STAT is a (past) producer → stronger signal (§5.3 Signal 3)
    state_nm      text,
    data_vintage  text,
    source_key    text       -- registry provenance (§6.13): 'mrds'
);

INSERT INTO tiles.mrds
    (geom, site_name, dev_stat, commodities, grade, url, dep_id, is_producer, state_nm, data_vintage, source_key)
SELECT
    s.geom,
    NULLIF(s.site_name, ''),
    NULLIF(s.dev_stat, ''),
    NULLIF(trim(s.code_list), ''),
    NULLIF(s.grade, ''),
    NULLIF(s.url, ''),
    NULLIF(s.dep_id::text, '')::bigint,
    s.dev_stat ILIKE '%producer%',
    st.name,
    'USGS MRDS (static — USGS stopped updates 2011)',
    'mrds'
FROM staging.mrds_gold s
JOIN staging.us_states8 st ON ST_Contains(st.geom, s.geom)
WHERE s.geom IS NOT NULL AND NOT ST_IsEmpty(s.geom);

CREATE INDEX mrds_geom_idx  ON tiles.mrds USING GIST (geom);
CREATE INDEX mrds_state_idx ON tiles.mrds (state_nm);

-- pg_tileserv's low-priv role must be able to read it (§6.8).
GRANT SELECT ON tiles.mrds TO tileserv_ro;

SELECT state_nm, count(*) AS gold_sites, count(*) FILTER (WHERE is_producer) AS producers
FROM tiles.mrds GROUP BY state_nm ORDER BY state_nm;
