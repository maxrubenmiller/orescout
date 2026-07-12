-- ============================================================================
-- Tier-1 private-land validation — stratified sample builder (Pass-B design;
-- README "Future: production-grade private-land validation"; TODO Track 2).
--
-- INPUT (source-agnostic): staging.parcels — every source adapter loads into this one shape:
--     parcel_id   text            (source's stable id, prefixed by source_key)
--     state       text            (2-letter)
--     geom        geometry(MultiPolygon, 4326)
--     owner_class text            ('private' | 'public' | 'unknown' — the adapter's mapping,
--                                  documented per source; only 'private' rows are sampled)
--     source_key  text
--
-- FRAME: private parcels whose interior point lies within 2 km of federal-managed land
-- (BLM/USFS rows in tiles.legality_polygons) — the inholding/adjacency case where a wrong
-- verdict harms someone; deep-urban private is always no-data YELLOW and uninformative.
--
-- STRATA: state × parcel-size bucket (<0.5 ha / 0.5–5 ha / >5 ha — the small-parcel tail is
-- where over-mapped federal hides). Proportional allocation with a per-stratum floor.
--
-- DETERMINISTIC: ordered by md5(parcel_id) — reproducible without random(); re-running on the
-- same parcel load yields the same sample (the fixture-freeze depends on this).
--
-- OUTPUT: staging.validation_sample (parcel_id, state, bucket, pt geometry(Point,4326))
-- Target size via :sample_n (psql -v sample_n=1500).
-- ============================================================================
SET client_min_messages TO WARNING;

-- ST_DWithin(geography) cannot use the plain geometry GIST index — without this functional
-- index the 1.4M-parcel frame filter degenerates to full scans of the legality table per
-- parcel (the same trap the prospectivity producer join hit: 44 min -> 16 s with the index).
CREATE INDEX IF NOT EXISTS legality_geog_idx ON tiles.legality_polygons USING GIST ((geom::geography));
ANALYZE tiles.legality_polygons;

-- Two passes + parallelism off: the single-statement version (PointOnSurface x 1.44M parcels +
-- parallel hash workers) OOM-crashed the memory-capped dev container (2026-07-12 — the third
-- member of the whole-geometry-OOM family; see also build_lowzoom + the confirm-open carve).
SET max_parallel_workers_per_gather = 0;

-- pass 1: interior points + areas (streaming, per-row GEOS; cheap memory)
DROP TABLE IF EXISTS staging.validation_pts;
CREATE TABLE staging.validation_pts AS
SELECT p.parcel_id, p.state, p.source_key,
       ST_PointOnSurface(p.geom) AS pt,
       ST_Area(p.geom::geography) AS area_m2
FROM staging.parcels p
WHERE p.owner_class = 'private' AND ST_IsValid(p.geom)
  -- Frame floor (stated bound; 2026-07-12 disposition): sub-400 m² fragments are assessor
  -- artifacts (the NM fabric carries 71 m² "ranch parcels" — well pads / easement slivers), not
  -- parcels a person can meaningfully occupy, and they sit deliberately below the confirm-open
  -- carve's own sliver threshold. Real building lots are >=400 m². The three such fragments the
  -- first validation surfaced are recorded in the run log + fixture notes, not silently dropped.
  AND ST_Area(p.geom::geography) >= 400;
CREATE INDEX validation_pts_gix ON staging.validation_pts USING GIST (pt);

-- pass 2a: SUBDIVIDED federal pieces — probing whole field-office multipolygons detoasts
-- hundreds of MB per candidate and OOM'd the container even without parallelism; small pieces
-- make every probe tiny (the same medicine as build_lowzoom / the confirm-open carve).
DROP TABLE IF EXISTS staging.validation_fed;
CREATE TABLE staging.validation_fed AS
SELECT ST_SubDivide(geom, 256) AS geom
FROM tiles.legality_polygons WHERE land_manager IN ('BLM','USFS');
CREATE INDEX validation_fed_gix ON staging.validation_fed USING GIST (geom);
ANALYZE staging.validation_fed;

-- pass 2b: adjacency frame — geometry-space bbox prefilter (index-friendly, ~0.03° ≈ 2.4 km),
-- exact 2 km geography refine on the small pieces only.
DROP TABLE IF EXISTS staging.validation_frame;
CREATE TABLE staging.validation_frame AS
SELECT v.parcel_id, v.state, v.source_key, v.pt, v.area_m2,
       CASE WHEN v.area_m2 < 5000 THEN 'small'
            WHEN v.area_m2 < 50000 THEN 'medium'
            ELSE 'large' END AS bucket
FROM staging.validation_pts v
WHERE EXISTS (
  SELECT 1 FROM staging.validation_fed f
  WHERE f.geom && ST_Expand(v.pt, 0.03)
    AND ST_DWithin(f.geom::geography, v.pt::geography, 2000)
);
CREATE INDEX validation_frame_strata ON staging.validation_frame (state, bucket);
DROP TABLE staging.validation_pts;
DROP TABLE staging.validation_fed;

-- proportional allocation with a floor: each non-empty stratum gets >= LEAST(frame_n, 25);
-- remainder allocated proportionally to frame size. Deterministic order within stratum.
DROP TABLE IF EXISTS staging.validation_sample;
CREATE TABLE staging.validation_sample AS
WITH strata AS (
  SELECT state, bucket, count(*) AS n_frame
  FROM staging.validation_frame GROUP BY 1, 2
),
tot AS (SELECT sum(n_frame)::float AS total FROM strata),
alloc AS (
  SELECT s.state, s.bucket, s.n_frame,
         LEAST(s.n_frame,
               GREATEST(25, ceil(:sample_n * s.n_frame / t.total))::int) AS n_take
  FROM strata s, tot t
),
ranked AS (
  SELECT f.*, row_number() OVER (PARTITION BY f.state, f.bucket ORDER BY md5(f.parcel_id)) AS rn
  FROM staging.validation_frame f
)
SELECT r.parcel_id, r.state, r.bucket, r.source_key, r.area_m2, r.pt
FROM ranked r JOIN alloc a USING (state, bucket)
WHERE r.rn <= a.n_take;
CREATE INDEX validation_sample_pt ON staging.validation_sample USING GIST (pt);

\echo '=== frame & sample by stratum ==='
SELECT f.state, f.bucket,
       count(*) AS frame_n,
       (SELECT count(*) FROM staging.validation_sample s WHERE (s.state, s.bucket) = (f.state, f.bucket)) AS sampled
FROM staging.validation_frame f GROUP BY 1,2 ORDER BY 1,2;
\echo '=== total sampled ==='
SELECT count(*) AS sample_total, count(DISTINCT state) AS states FROM staging.validation_sample;
