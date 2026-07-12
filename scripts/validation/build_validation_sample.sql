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

DROP TABLE IF EXISTS staging.validation_frame;
CREATE TABLE staging.validation_frame AS
WITH fed AS (
  SELECT geom FROM tiles.legality_polygons
  WHERE land_manager IN ('BLM','USFS')
),
priv AS (
  SELECT p.parcel_id, p.state, p.source_key,
         ST_PointOnSurface(p.geom) AS pt,
         ST_Area(p.geom::geography) AS area_m2
  FROM staging.parcels p
  WHERE p.owner_class = 'private'
    AND ST_IsValid(p.geom)
)
SELECT pr.parcel_id, pr.state, pr.source_key, pr.pt, pr.area_m2,
       CASE WHEN pr.area_m2 < 5000 THEN 'small'
            WHEN pr.area_m2 < 50000 THEN 'medium'
            ELSE 'large' END AS bucket
FROM priv pr
WHERE EXISTS (
  SELECT 1 FROM fed f WHERE ST_DWithin(f.geom::geography, pr.pt::geography, 2000)
);
CREATE INDEX validation_frame_strata ON staging.validation_frame (state, bucket);

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
