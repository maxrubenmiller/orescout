-- ============================================================================
-- OreScout — generalized low-zoom legality layer (IMP-07; review finding F-3).
--
-- The full-resolution tiles.legality_polygons (95k detailed, heavily OVERLAPPING polygons —
-- PAD-US stacks designation/ownership features) produced 1-3 MB vector tiles at z5-6 that took
-- 3-9 s each and blew pg_tileserv's 10 s statement timeout under a normal 6-tile concurrent
-- viewport fetch -> HTTP 500 -> RED/YELLOW land silently rendered blank at state-wide zooms.
--
-- This builds tiles.legality_lowzoom, served for z < 9 (split in web/src/map/style.ts
-- LOWZOOM_SPLIT). Three steps, all display-only (the verdict engine never reads this table):
--   1. DISSOLVE by (verdict, state): ST_Union removes the overlap multiplication — the dominant
--      cost — and drops per-feature identity the low-zoom map doesn't need. Per-state batches
--      keep memory bounded (a whole-region operation OOM-crashed the dev container).
--   2. SIMPLIFY: plain ST_Simplify(0.002°) + ST_MakeValid (~200 m; sub-half-pixel at z8's
--      ~470 m/px. Topology-preserving simplify isn't needed post-dissolve and is far heavier).
--   3. SUBDIVIDE(512) + drop pieces < 0.2 km² (~1 px² at z8): small tile-friendly pieces so
--      ST_AsMVT clips little geometry per tile.
-- Run AFTER unify + confirm_open steps (rebuild_legality.sh orders this) so confirm-open YELLOW
-- is baked in. Most-restrictive rendering is preserved by draw order (RED drawn last/on top)
-- exactly as the detail layers already do it.
-- Idempotent: drops and rebuilds.
-- ============================================================================
SET client_min_messages TO WARNING;

-- TARGET TABLE (review finding PP-31): the target is the psql variable :lowzoom_tbl, defaulting to
-- the live table so a standalone run behaves as before. rebuild_legality.sh passes
-- tiles.legality_lowzoom_new so this builds off to the side and reaches live via atomic_swap.
-- Building in place is DROP-then-INSERT against a serving table: when the GREEN clip below hit a
-- GEOS TopologyException on 2026-08-18 the DROP had already committed, so the z<9 map had NO
-- legality data until the rebuild was re-run. Same non-atomic pattern PP-8 fixed for
-- legality_polygons; it failed safe (blank is not an affirmative claim of open) but the window is
-- real and only the PP-6 generation stamps flagged it.
\if :{?lowzoom_tbl}
\else
  \set lowzoom_tbl tiles.legality_lowzoom
\endif

DROP TABLE IF EXISTS :lowzoom_tbl;

CREATE TABLE :lowzoom_tbl (
    ogc_fid  bigserial PRIMARY KEY,
    verdict  text CHECK (verdict IN ('RED','YELLOW','GREEN')),
    geom     geometry(MultiPolygon, 4326)
);

-- GREEN-CLIP GUARD (review finding PP-7) ------------------------------------------------------
-- The >0.2 km² drops below are a tile-weight measure, and applying them to the RED/YELLOW INPUTS
-- is not symmetric with applying them to GREEN. Dropping a small RED/YELLOW polygon does not make
-- that ground blank — the large GREEN polygon overlapping it survives, and the display partition
-- (build_legality_display.sql) then computes GREEN minus only the SURVIVING red/yellow, so the
-- z<=8 "Confirmed open" fill paints straight across private inholdings and patented-claim
-- mosaics. Measured before the fix: 7,909 engine-RED polygons totalling 409.7 km² were absent
-- from this table, green-over-engine-RED clusters reached 0.33 km² and green-over-engine-YELLOW
-- clusters 5.84 km² around Ouray/Telluride.
-- Dropping GREEN is safe (blank land is not an affirmative claim of open); dropping RED/YELLOW is
-- not. So GREEN is clipped here against the FULL-RESOLUTION red/yellow union, unfiltered, before
-- it is written. Small red/yellow parcels still do not RENDER at low zoom — they become holes in
-- the green instead, which is exactly the conservative-by-blankness behaviour the design already
-- relies on everywhere else.
DROP TABLE IF EXISTS _lz_protect;
CREATE TEMP TABLE _lz_protect AS
SELECT (ST_Dump(ST_Subdivide(ST_MakeValid(geom), 256))).geom AS geom
FROM tiles.legality_polygons
WHERE verdict IN ('RED','YELLOW') AND geom IS NOT NULL AND NOT ST_IsEmpty(geom);
DELETE FROM _lz_protect WHERE ST_GeometryType(geom) NOT IN ('ST_Polygon','ST_MultiPolygon');
CREATE INDEX ON _lz_protect USING GIST (geom);

INSERT INTO :lowzoom_tbl (verdict, geom)
SELECT c.verdict, ST_Multi(c.geom)
FROM (
    SELECT p.verdict,
           CASE WHEN p.verdict <> 'GREEN' THEN p.geom
                -- gridSize 1e-7 deg (~1 cm): ST_Difference on these dissolved, simplified shapes
                -- hits GEOS robustness failures without snap-rounding — observed as
                -- "TopologyException: unable to assign free hole to a shell" at
                -- -122.2597,41.1517 on the first run. The grid is four orders of magnitude finer
                -- than the 0.002 deg (~200 m) simplify tolerance already applied above, so it
                -- costs nothing this layer has not already given up. ST_MakeValid on BOTH sides:
                -- the union of many subdivided pieces is not guaranteed valid either.
                ELSE ST_CollectionExtract(ST_MakeValid(ST_Difference(
                       ST_MakeValid(p.geom),
                       COALESCE(ST_MakeValid(pr.protect), ST_GeomFromText('MULTIPOLYGON EMPTY', 4326)),
                       0.0000001)), 3)
           END AS geom
    FROM (
        SELECT d.verdict, ST_CollectionExtract(sub.piece, 3) AS geom
        FROM (
            SELECT verdict, state_nm, ST_Union(ST_MakeValid(geom)) AS geom
            FROM tiles.legality_polygons
            WHERE ST_Area(geom::geography) > 200000   -- sub-pixel at z8; detail layer owns z >= 9
            GROUP BY verdict, state_nm                -- per-state batches bound the union's memory
        ) d
        CROSS JOIN LATERAL (
            SELECT ST_Subdivide(
                     ST_CollectionExtract(ST_MakeValid(ST_Simplify(d.geom, 0.002)), 3), 512) AS piece
        ) sub
        WHERE NOT ST_IsEmpty(sub.piece)
          AND ST_Area(sub.piece::geography) > 200000
    ) p
    -- Only GREEN pays for this join; the subdivided _lz_protect keeps each union local and
    -- bounded, the same memory discipline the confirm-open carve uses.
    LEFT JOIN LATERAL (
        SELECT ST_Union(x.geom) AS protect
        FROM _lz_protect x
        WHERE p.verdict = 'GREEN' AND ST_Intersects(x.geom, p.geom)
    ) pr ON true
) c
WHERE c.geom IS NOT NULL AND NOT ST_IsEmpty(c.geom) AND ST_Dimension(c.geom) = 2;

-- Index name left to Postgres so a _new build cannot collide with the live table's; atomic_swap
-- strips the '_new' infix after the rename.
CREATE INDEX ON :lowzoom_tbl USING GIST (geom);
GRANT SELECT ON :lowzoom_tbl TO tileserv_ro;

SELECT verdict, count(*) AS polys,
       round(sum(ST_NPoints(geom))/1000.0) AS kvertices
FROM :lowzoom_tbl GROUP BY verdict ORDER BY verdict;
