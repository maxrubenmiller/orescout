-- ============================================================================
-- OreScout — access & trails overlay build (docs/planning/PROJECT_PLAN.md §5.4 / §6.13 `reference` role).
-- Promotes the four staged federal sources (loaded by scripts/etl/pull_access.sh):
--   staging.access_mvum_roads   USFS MVUM Roads   (per-vehicle-class open flags)
--   staging.access_mvum_trails  USFS MVUM Trails  (same flag vocabulary)
--   staging.access_nfs_trails   USFS NFS Trails   (per-mode managed-use date windows)
--   staging.access_gtlf         BLM GTLF Public Display (8 pre-classified layers)
-- into ONE display table `tiles.access`, each segment classified into the unified
--   travel_mode ∈ {drive, off_road, hike_in}   (most-accessible wins: drive → off_road → hike_in)
--
-- REFERENCE-ONLY: display tiles; never feeds orescout_base_verdict / the assessment engine
-- (how you reach a spot is not a legality input). Upholds the §6.13 invariant.
--
-- The shipped column→bucket mapping (docs/briefs/FABLE_MVUM_BRIEF.md "Mode-enum spec"; deviations documented):
--   MVUM Roads/Trails: flag value 'open' (lowercase in EDW) per vehicle class.
--     drive    = passengervehicle open AND operationalmaintlevel 3–5 (suitable for passenger
--                cars). DEVIATION (the brief's own parenthetical alternative): 97.6% of staged
--                MVUM roads are legally passenger-open, but 96k of 114k are maint-level 2
--                "HIGH CLEARANCE VEHICLES" native-surface roads — the legal flag alone smears
--                ~everything into `drive` and answers the wrong question ("may a sedan" vs
--                "would a sedan"). ML 3–5 restores the practical drive/off-road split
--                (~18k drive / ~96k off_road). MVUM Trails carry no maint level and 15k of 28k
--                are legally "open to all vehicles" — an unmaintained two-track, not a sedan
--                road: ALL MVUM trails classify off_road (second documented deviation; `drive`
--                stays "roads you can reach in a standard vehicle").
--     off_road = any other motorized class open (high-clearance, truck, bus, motorhome,
--                4WD/2WD>50", tracked/other OHV >50" or <50", ATV, motorcycle, other wheeled
--                OHV, e-bike class 1–3) while passenger/ML doesn't qualify for drive.
--     no flag open (closed/administrative rows) → DROPPED, logged (an MVUM row with no open
--     designation is not an access affordance; it is not bucketed).
--   NFS Trails: TERRA trails only (SNOW/WATER dropped + logged — winter/water routes are not
--     prospecting access). Motorized (terra_motorized='Y' or a motorized *_managed window:
--     motorcycle/atv/fourwd) → off_road; everything else → hike_in (per brief: a non-motorized
--     NFS trail is the hike-in backbone even where the foot/pack columns are null).
--     Trails whose trail_cn also appears in MVUM Trails *and* are motorized are DROPPED as
--     duplicates (MVUM carries the authoritative vehicle-class detail), logged.
--   BLM GTLF (display layer id `gtlf_layer` is part of the signal):
--     layers 0/1 (roads, public/limited motorized):
--       OBSRVE_ROUTE_USE_CLASS 2WD* → drive; 4WD*/ATV*/UTV*/Motorized Single Track → off_road;
--       else PLAN_ASSET_CLASS *Primitive Road* → off_road; *Road* → drive;
--       unknown grade → off_road (don't overpromise passenger access on BLM dirt).
--     layers 2/3 (motorized trails) → off_road.  layers 4/5 (non-motorized/non-mechanized)
--       → hike_in.  layer 7 (managed-for-public trails): PLAN_MODE_TRNSPRT Motorized →
--       off_road (2WD* → drive); Non-* → hike_in; null → hike_in (public trail, mode unknown —
--       least-accessible bucket), logged.
--     layer 6 (Trails NOT Assessed for public use) → DROPPED, logged (no public designation).
--     Cross-layer duplicates (same GlobalID in >1 display layer) deduped to the lowest layer.
--   Seasonal windows (`*_datesopen` / managed windows / PLAN_SEASON_RSTRCT_CODE) are carried as
--   ADVISORY FREE TEXT for the popup — never parsed or styled (routing-engine concern, deferred).
--
-- Clipped to the 8-state boundary (public.supported_region): keep whole lines that intersect an
-- in-scope state (waterways rule). All filters are LOGGED with kept/dropped counts (no silent caps).
-- Idempotent: drops and rebuilds.
-- ============================================================================

CREATE INDEX IF NOT EXISTS access_mvum_roads_geom_idx  ON staging.access_mvum_roads  USING GIST (geom);
CREATE INDEX IF NOT EXISTS access_mvum_trails_geom_idx ON staging.access_mvum_trails USING GIST (geom);
CREATE INDEX IF NOT EXISTS access_nfs_trails_geom_idx  ON staging.access_nfs_trails  USING GIST (geom);
CREATE INDEX IF NOT EXISTS access_gtlf_geom_idx        ON staging.access_gtlf        USING GIST (geom);

DROP TABLE IF EXISTS tiles.access;

CREATE TABLE tiles.access (
    ogc_fid      bigserial PRIMARY KEY,
    geom         geometry(MultiLineString, 4326),
    name         text,        -- route/trail name (GNIS-style display name; may be null)
    travel_mode  text,        -- 'drive' | 'off_road' | 'hike_in' (the derived display bucket)
    is_road      boolean,     -- road vs trail — drives the roads-higher zoom gate (lock #4)
    surface      text,        -- source surface type (popup)
    seasonal     text,        -- ADVISORY free-text open window / seasonal-restriction note
    mode_detail  text,        -- raw source classification summary (popup/debug; the brief's
                              -- "keep the raw source classification on the row")
    route_id     text,        -- source route identifier (MVUM id / NFS trail_no / GTLF FAMS_ID)
    src          text,        -- usfs_mvum_roads | usfs_mvum_trails | usfs_nfs_trails | blm_gtlf
    agency       text,        -- 'USDA Forest Service' | 'BLM' (popup attribution)
    state_nm     text,        -- dominant in-scope state (display provenance; not queried by app)
    data_vintage text,
    source_key   text         -- registry provenance (§6.13) = 'access'
);

-- Dissolved 8-state boundary for the in-scope filter (waterways idiom).
DROP TABLE IF EXISTS _region8;
CREATE TEMP TABLE _region8 AS SELECT ST_Union(geom) AS geom FROM public.supported_region;
CREATE INDEX ON _region8 USING GIST (geom);

-- ---------------------------------------------------------------------------
-- 1/4 — USFS MVUM Roads
-- ---------------------------------------------------------------------------
INSERT INTO tiles.access
    (geom, name, travel_mode, is_road, surface, seasonal, mode_detail, route_id, src, agency,
     state_nm, data_vintage, source_key)
SELECT
    ST_Multi(s.geom),
    NULLIF(s.name, ''),
    CASE
      WHEN lower(s.passengervehicle) = 'open'
       AND left(s.operationalmaintlevel, 1) IN ('3', '4', '5') THEN 'drive'
      ELSE 'off_road'   -- reached only when some motorized class is open (WHERE below)
    END,
    true,
    NULLIF(s.surfacetype, ''),
    COALESCE(
      CASE WHEN lower(s.passengervehicle) = 'open' THEN NULLIF(s.passengervehicle_datesopen, '') END,
      NULLIF(s.highclearancevehicle_datesopen, ''), NULLIF(s.fourwd_gt50_datesopen, ''),
      NULLIF(s.atv_datesopen, ''), NULLIF(s.motorcycle_datesopen, ''),
      NULLIF(s.truck_datesopen, ''), NULLIF(s.seasonal, '')),
    NULLIF(concat_ws(' · ', NULLIF(s.mvum_symbol_name, ''), NULLIF(s.operationalmaintlevel, '')), ''),
    NULLIF(s.id, ''),
    'usfs_mvum_roads',
    'USDA Forest Service',
    (SELECT r.state_code FROM public.supported_region r
        WHERE ST_Intersects(ST_StartPoint(ST_GeometryN(s.geom, 1)), r.geom) LIMIT 1),
    'USFS MVUM Roads (EDW File GDB, pub 2026-07-09)',
    'access'
FROM staging.access_mvum_roads s
JOIN _region8 r ON ST_Intersects(s.geom, r.geom)
WHERE s.geom IS NOT NULL AND NOT ST_IsEmpty(s.geom)
  AND (lower(s.passengervehicle) = 'open'
    OR 'open' IN (lower(s.highclearancevehicle), lower(s.truck), lower(s.bus),
                  lower(s.motorhome), lower(s.fourwd_gt50inches), lower(s.twowd_gt50inches),
                  lower(s.tracked_ohv_gt50inches), lower(s.other_ohv_gt50inches), lower(s.atv),
                  lower(s.motorcycle), lower(s.otherwheeled_ohv), lower(s.tracked_ohv_lt50inches),
                  lower(s.other_ohv_lt50inches), lower(s.e_bike_class1), lower(s.e_bike_class2),
                  lower(s.e_bike_class3)));

-- ---------------------------------------------------------------------------
-- 2/4 — USFS MVUM Trails (same flag vocabulary; no surfacetype/maint level on trails)
-- ---------------------------------------------------------------------------
INSERT INTO tiles.access
    (geom, name, travel_mode, is_road, surface, seasonal, mode_detail, route_id, src, agency,
     state_nm, data_vintage, source_key)
SELECT
    ST_Multi(s.geom),
    NULLIF(s.name, ''),
    -- ALL MVUM trails are off_road (documented deviation in the header): no maint level exists
    -- on trails, and a "trail open to all vehicles" is a two-track, not a passenger-car drive.
    'off_road',
    false,
    NULL,
    COALESCE(
      CASE WHEN lower(s.passengervehicle) = 'open' THEN NULLIF(s.passengervehicle_datesopen, '') END,
      NULLIF(s.highclearancevehicle_datesopen, ''), NULLIF(s.fourwd_gt50_datesopen, ''),
      NULLIF(s.atv_datesopen, ''), NULLIF(s.motorcycle_datesopen, ''),
      NULLIF(s.truck_datesopen, ''), NULLIF(s.seasonal, '')),
    NULLIF(s.mvum_symbol_name, ''),
    NULLIF(s.id, ''),
    'usfs_mvum_trails',
    'USDA Forest Service',
    (SELECT r.state_code FROM public.supported_region r
        WHERE ST_Intersects(ST_StartPoint(ST_GeometryN(s.geom, 1)), r.geom) LIMIT 1),
    'USFS MVUM Trails (EDW File GDB, pub 2026-07-09)',
    'access'
FROM staging.access_mvum_trails s
JOIN _region8 r ON ST_Intersects(s.geom, r.geom)
WHERE s.geom IS NOT NULL AND NOT ST_IsEmpty(s.geom)
  AND (lower(s.passengervehicle) = 'open'
    OR 'open' IN (lower(s.highclearancevehicle), lower(s.truck), lower(s.bus),
                  lower(s.motorhome), lower(s.fourwd_gt50inches), lower(s.twowd_gt50inches),
                  lower(s.tracked_ohv_gt50inches), lower(s.other_ohv_gt50inches), lower(s.atv),
                  lower(s.motorcycle), lower(s.otherwheeled_ohv), lower(s.tracked_ohv_lt50inches),
                  lower(s.other_ohv_lt50inches), lower(s.e_bike_class1), lower(s.e_bike_class2),
                  lower(s.e_bike_class3)));

-- ---------------------------------------------------------------------------
-- 3/4 — USFS NFS Trails (the non-motorized backbone; TERRA only, MVUM-dup motorized dropped)
-- ---------------------------------------------------------------------------
INSERT INTO tiles.access
    (geom, name, travel_mode, is_road, surface, seasonal, mode_detail, route_id, src, agency,
     state_nm, data_vintage, source_key)
SELECT
    ST_Multi(s.geom),
    NULLIF(s.trail_name, ''),
    CASE
      WHEN s.terra_motorized = 'Y'
        OR s.motorcycle_managed IS NOT NULL OR s.atv_managed IS NOT NULL
        OR s.fourwd_managed IS NOT NULL
      THEN 'off_road'
      ELSE 'hike_in'
    END,
    false,
    NULLIF(s.trail_surface, ''),
    COALESCE(NULLIF(s.hiker_pedestrian_managed, ''), NULLIF(s.pack_saddle_managed, ''),
             NULLIF(s.bicycle_managed, ''), NULLIF(s.motorcycle_managed, ''),
             NULLIF(s.atv_managed, ''), NULLIF(s.fourwd_managed, '')),
    NULLIF(concat_ws('; ',
      'hiker '        || NULLIF(s.hiker_pedestrian_managed, ''),
      'pack/saddle '  || NULLIF(s.pack_saddle_managed, ''),
      'bicycle '      || NULLIF(s.bicycle_managed, ''),
      'motorcycle '   || NULLIF(s.motorcycle_managed, ''),
      'ATV '          || NULLIF(s.atv_managed, ''),
      '4WD '          || NULLIF(s.fourwd_managed, '')), ''),
    NULLIF(s.trail_no, ''),
    'usfs_nfs_trails',
    'USDA Forest Service',
    (SELECT r.state_code FROM public.supported_region r
        WHERE ST_Intersects(ST_StartPoint(ST_GeometryN(s.geom, 1)), r.geom) LIMIT 1),
    'USFS NFS Trails (EDW File GDB, pub 2026-07-09)',
    'access'
FROM staging.access_nfs_trails s
JOIN _region8 r ON ST_Intersects(s.geom, r.geom)
WHERE s.geom IS NOT NULL AND NOT ST_IsEmpty(s.geom)
  AND s.trail_type = 'TERRA'
  -- motorized NFS trails that MVUM Trails also carries: MVUM wins (vehicle-class detail)
  AND NOT (
    (s.terra_motorized = 'Y' OR s.motorcycle_managed IS NOT NULL
      OR s.atv_managed IS NOT NULL OR s.fourwd_managed IS NOT NULL)
    AND s.trail_cn IN (SELECT m.rte_cn FROM staging.access_mvum_trails m WHERE m.rte_cn IS NOT NULL)
  );

-- ---------------------------------------------------------------------------
-- 4/4 — BLM GTLF (Public Display layers; cross-layer GlobalID dedupe to the lowest layer)
-- ---------------------------------------------------------------------------
WITH dedup AS (
    -- layer 6 ("Trails Not Assessed") is excluded BEFORE the dedupe so a feature listed in both
    -- 6 and a real class keeps its classified representation. Layers 6/7 carry NO GlobalID
    -- (verified 2026-07-14) — null ids must stay unique, not collapse into one row.
    SELECT DISTINCT ON (COALESCE(s.globalid, 'nogid:' || s.ogc_fid::text)) s.*
    FROM staging.access_gtlf s
    WHERE s.gtlf_layer <> 6
    ORDER BY COALESCE(s.globalid, 'nogid:' || s.ogc_fid::text), s.gtlf_layer
)
INSERT INTO tiles.access
    (geom, name, travel_mode, is_road, surface, seasonal, mode_detail, route_id, src, agency,
     state_nm, data_vintage, source_key)
SELECT
    ST_Multi(s.geom),
    NULLIF(s.route_prmry_nm, ''),
    CASE
      WHEN s.gtlf_layer IN (0, 1) THEN
        CASE
          WHEN s.obsrve_route_use_class ILIKE '2WD%' THEN 'drive'
          WHEN s.obsrve_route_use_class ILIKE '4WD%' OR s.obsrve_route_use_class ILIKE 'ATV%'
            OR s.obsrve_route_use_class ILIKE 'UTV%' OR s.obsrve_route_use_class ILIKE '%single track%'
            THEN 'off_road'
          WHEN s.plan_asset_class ILIKE '%primitive road%' THEN 'off_road'
          WHEN s.plan_asset_class ILIKE '%road%' THEN 'drive'
          ELSE 'off_road'
        END
      WHEN s.gtlf_layer IN (2, 3) THEN 'off_road'
      WHEN s.gtlf_layer IN (4, 5) THEN 'hike_in'
      WHEN s.gtlf_layer = 7 THEN
        CASE
          WHEN s.plan_mode_trnsprt ILIKE 'motorized' THEN
            CASE WHEN s.obsrve_route_use_class ILIKE '2WD%' THEN 'drive' ELSE 'off_road' END
          ELSE 'hike_in'   -- Non-Motorized / Non-Mechanized / shared / unknown mode
        END
    END,
    s.gtlf_layer IN (0, 1),
    NULLIF(s.obsrve_srfce_type, ''),
    -- PLAN_SEASON_RSTRCT_CODE is YES/NO/Unknown/N-A vocabulary (mixed case) — only an
    -- affirmative YES is worth an advisory line; Unknown/N/A/null say nothing.
    CASE WHEN upper(s.plan_season_rstrct_code) IN ('YES', 'Y')
         THEN 'seasonal restrictions apply' END,
    NULLIF(concat_ws(' · ',
      NULLIF(s.plan_asset_class, ''),
      NULLIF(NULLIF(s.obsrve_route_use_class, 'Unknown'), ''),
      NULLIF(s.plan_mode_trnsprt, ''),
      'OHV: ' || NULLIF(s.plan_ohv_route_dsgntn, '')), ''),
    NULLIF(s.fams_id, ''),
    'blm_gtlf',
    'BLM',
    (SELECT r.state_code FROM public.supported_region r
        WHERE ST_Intersects(ST_StartPoint(ST_GeometryN(s.geom, 1)), r.geom) LIMIT 1),
    'BLM Natl GTLF Public Display (REST harvest 2026-07-14)',
    'access'
FROM dedup s
JOIN _region8 r ON ST_Intersects(s.geom, r.geom)
WHERE s.geom IS NOT NULL AND NOT ST_IsEmpty(s.geom);

CREATE INDEX access_geom_idx  ON tiles.access USING GIST (geom);
CREATE INDEX access_mode_idx  ON tiles.access (travel_mode);
CREATE INDEX access_road_idx  ON tiles.access (is_road);

-- pg_tileserv's low-priv role must be able to read it (§6.8).
GRANT SELECT ON tiles.access TO tileserv_ro;

-- ---------------------------------------------------------------------------
-- Transparency readouts (no silent caps — every filter's kept/dropped, §ETL transparency)
-- ---------------------------------------------------------------------------
-- Region clip + unclassifiable drops, per source:
SELECT 'mvum_roads'  AS src, count(*) AS staged,
       count(*) FILTER (WHERE NOT (lower(passengervehicle) = 'open'
         OR 'open' IN (lower(highclearancevehicle), lower(truck), lower(bus), lower(motorhome),
                       lower(fourwd_gt50inches), lower(twowd_gt50inches), lower(tracked_ohv_gt50inches),
                       lower(other_ohv_gt50inches), lower(atv), lower(motorcycle), lower(otherwheeled_ohv),
                       lower(tracked_ohv_lt50inches), lower(other_ohv_lt50inches), lower(e_bike_class1),
                       lower(e_bike_class2), lower(e_bike_class3)))) AS dropped_no_open_flag
FROM staging.access_mvum_roads
UNION ALL
SELECT 'mvum_trails', count(*),
       count(*) FILTER (WHERE NOT (lower(passengervehicle) = 'open'
         OR 'open' IN (lower(highclearancevehicle), lower(truck), lower(bus), lower(motorhome),
                       lower(fourwd_gt50inches), lower(twowd_gt50inches), lower(tracked_ohv_gt50inches),
                       lower(other_ohv_gt50inches), lower(atv), lower(motorcycle), lower(otherwheeled_ohv),
                       lower(tracked_ohv_lt50inches), lower(other_ohv_lt50inches), lower(e_bike_class1),
                       lower(e_bike_class2), lower(e_bike_class3))))
FROM staging.access_mvum_trails;

SELECT count(*) AS nfs_staged,
       count(*) FILTER (WHERE trail_type <> 'TERRA') AS dropped_snow_water,
       count(*) FILTER (WHERE trail_type = 'TERRA'
         AND (terra_motorized = 'Y' OR motorcycle_managed IS NOT NULL
              OR atv_managed IS NOT NULL OR fourwd_managed IS NOT NULL)
         AND trail_cn IN (SELECT rte_cn FROM staging.access_mvum_trails WHERE rte_cn IS NOT NULL))
         AS dropped_mvum_dup
FROM staging.access_nfs_trails;

SELECT count(*) AS gtlf_staged,
       count(*) FILTER (WHERE gtlf_layer <> 6)
         - count(DISTINCT COALESCE(globalid, 'nogid:' || ogc_fid::text)) FILTER (WHERE gtlf_layer <> 6)
         AS crosslayer_dups_deduped,
       count(*) FILTER (WHERE gtlf_layer = 6) AS dropped_not_assessed,
       count(*) FILTER (WHERE gtlf_layer = 7 AND plan_mode_trnsprt IS NULL) AS layer7_null_mode_as_hike_in
FROM staging.access_gtlf;

-- The source × travel_mode reality table (acceptance criterion — must not be a one-bucket smear):
SELECT src, travel_mode, count(*) AS segments
FROM tiles.access GROUP BY src, travel_mode ORDER BY src, travel_mode;

SELECT travel_mode, is_road, count(*) FROM tiles.access GROUP BY 1, 2 ORDER BY 1, 2;
SELECT state_nm, count(*) FROM tiles.access GROUP BY state_nm ORDER BY 2 DESC;
SELECT count(*) AS total, count(name) AS named, count(seasonal) AS with_seasonal,
       count(surface) AS with_surface FROM tiles.access;
