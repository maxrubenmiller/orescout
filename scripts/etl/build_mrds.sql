-- ============================================================================
-- OreScout — MRDS gold overlay build (Tier A; PROJECT_PLAN §6.13 `reference` role).
-- Promotes staging.mrds_gold (USGS MRDS, gold-filtered) into the served tiles.mrds
-- table, ENRICHED with the MRDS related tables (Commodity / Materials / Names;
-- staged by pull_mrds_details.sh). REFERENCE-ONLY: display tiles, it never feeds
-- orescout_base_verdict / the assessment engine (mineral occurrences aren't a
-- legality input). Upholds the §6.13 invariant — adding it touches zero engine code.
--
-- Clipped to the 8 supported states (staging.us_states8) so envelope-slivers of
-- WY/MT/TX are dropped and every point is tagged with its state. `is_producer` flags
-- (past) producers — the stronger prospecting signal, and the §5.3 Signal-3 anchor.
-- Static source — USGS stopped updating MRDS in 2011; the UI labels it historical.
--
-- ATOMIC SWAP: builds tiles.mrds_new (indexes/GRANT included); scripts/etl/build_mrds.sh
-- then runs the refresh_lib gates (assert_schema/count_gate) and atomic_swap so the live
-- tiles.mrds is never dropped mid-read (the one downstream reader, build_prospectivity.sql,
-- and pg_tileserv keep serving the old table until the swap commits).
--
-- ADDITIVE ENRICHMENT (never drop/rename an existing column): five compact text columns
-- aggregated from the related tables, capped at 300 chars each (stated bound; keeps tiles
-- lean — every property ships to every client):
--   commodities_major  — full names of Primary commodities   (e.g. "Gold, Silver")
--   commodities_minor  — full names of Secondary/Tertiary     (e.g. "Lead, Copper")
--   ore_minerals       — Materials with role Ore              (e.g. "Gold, Galena, Pyrite")
--   gangue_minerals    — Materials with role Gangue           (e.g. "Quartz")
--   alt_names          — Names other than the displayed site_name
-- Related-table join key = dep_id (schema.ini "Record ID"); resolved empirically, see
-- pull_mrds_details.sh. Sites with no related rows keep NULL enrichment (popup falls back
-- to the raw CODE_LIST) — coverage is reported by build_mrds.sh, no silent gaps.
-- ============================================================================

DROP TABLE IF EXISTS tiles.mrds_new;

CREATE TABLE tiles.mrds_new (
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
    source_key    text,      -- registry provenance (§6.13): 'mrds'
    -- additive popup-enrichment columns (from the MRDS related tables) --------
    commodities_major text,  -- Primary commodities, full names, comma-joined (≤300 chars)
    commodities_minor text,  -- Secondary+Tertiary commodities, full names (≤300 chars)
    ore_minerals      text,  -- Materials role=Ore, comma-joined (≤300 chars)
    gangue_minerals   text,  -- Materials role=Gangue, comma-joined (≤300 chars)
    alt_names         text   -- Names other than the displayed site_name (≤300 chars)
);

-- One row per dep_id per related table. DISTINCT collapses duplicate commodity/mineral/name
-- rows; ordering keys (line/rec) keep the list in the source's stated order; the 300-char cap
-- (left(...)) bounds pathological multi-page lists so tiles stay lean.
WITH comm AS (
    SELECT dep_id,
           left(string_agg(commod, ', ' ORDER BY ord) FILTER (WHERE import = 'Primary'), 300)                       AS majors,
           left(string_agg(commod, ', ' ORDER BY ord) FILTER (WHERE import IN ('Secondary','Tertiary')), 300)       AS minors
    FROM (
        SELECT dep_id, commod, import, min(line) AS ord
        FROM staging.mrds_commodity
        WHERE commod IS NOT NULL AND commod <> ''
        GROUP BY dep_id, commod, import
    ) c
    GROUP BY dep_id
),
mat AS (
    SELECT dep_id,
           left(string_agg(material, ', ' ORDER BY ord) FILTER (WHERE ore_gangue = 'Ore'), 300)    AS ore,
           left(string_agg(material, ', ' ORDER BY ord) FILTER (WHERE ore_gangue = 'Gangue'), 300) AS gangue
    FROM (
        SELECT dep_id, material, ore_gangue, min(rec) AS ord
        FROM staging.mrds_materials
        WHERE material IS NOT NULL AND material <> ''
        GROUP BY dep_id, material, ore_gangue
    ) m
    GROUP BY dep_id
),
nam AS (
    SELECT n.dep_id, left(string_agg(n.name, ', ' ORDER BY n.ord), 300) AS alt
    FROM (
        SELECT dep_id, name, min(line) AS ord
        FROM staging.mrds_names
        WHERE name IS NOT NULL AND name <> ''
        GROUP BY dep_id, name
    ) n
    GROUP BY n.dep_id
)
INSERT INTO tiles.mrds_new
    (geom, site_name, dev_stat, commodities, grade, url, dep_id, is_producer, state_nm,
     data_vintage, source_key, commodities_major, commodities_minor, ore_minerals, gangue_minerals, alt_names)
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
    'mrds',
    NULLIF(comm.majors, ''),
    NULLIF(comm.minors, ''),
    NULLIF(mat.ore, ''),
    NULLIF(mat.gangue, ''),
    -- drop the displayed site_name from the alt-name list; NULL when nothing distinct remains
    NULLIF(NULLIF(
        (SELECT string_agg(x, ', ') FROM regexp_split_to_table(nam.alt, ', ') AS x
         WHERE x <> COALESCE(s.site_name, '')), ''), '')
FROM staging.mrds_gold s
JOIN staging.us_states8 st ON ST_Contains(st.geom, s.geom)
LEFT JOIN comm ON comm.dep_id = NULLIF(s.dep_id::text, '')
LEFT JOIN mat  ON mat.dep_id  = NULLIF(s.dep_id::text, '')
LEFT JOIN nam  ON nam.dep_id  = NULLIF(s.dep_id::text, '')
WHERE s.geom IS NOT NULL AND NOT ST_IsEmpty(s.geom);

-- Indexes carry the _new infix so they don't collide with the live table's; refresh_lib's
-- atomic_swap strips "_new" after the rename (mrds_new_geom_idx -> mrds_geom_idx, etc.).
CREATE INDEX mrds_new_geom_idx  ON tiles.mrds_new USING GIST (geom);
CREATE INDEX mrds_new_state_idx ON tiles.mrds_new (state_nm);
-- geography index used by build_prospectivity.sql's Signal-3 producer-proximity join; recreate
-- it here so the atomic swap never leaves the prospectivity build without it.
CREATE INDEX mrds_new_geog_idx  ON tiles.mrds_new USING GIST ((geom::geography));

-- pg_tileserv's low-priv role must be able to read it (§6.8). GRANT survives the rename.
GRANT SELECT ON tiles.mrds_new TO tileserv_ro;
