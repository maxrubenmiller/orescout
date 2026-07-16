-- ============================================================================
-- OreScout — legality DISPLAY overlay (UI_CHANGES.md Changes 1 + 2).
-- Builds a display-only, dissolved, most-restrictive PARTITION of the legality
-- polygons so the map renders uniform color per verdict (no overlap darkening —
-- Change 1) with GREEN absent under YELLOW and YELLOW absent under RED (Change 2).
--
-- REFERENCE/DISPLAY ONLY. The verdict engine (/assessment, QueryMostRestrictiveAsync)
-- keeps querying the SOURCE table (tiles.legality_polygons) — this table never feeds
-- a verdict. The partition here mirrors the engine's precedence exactly:
-- orescout_rank RED(3) > YELLOW(2) > GREEN(1), so what the map paints == what a click reports.
--
-- Args (psql -v):  src=<source table>  tgt=<target table>
--   normal zoom:  -v src=tiles.legality_polygons -v tgt=tiles.legality_display
--   low zoom:     -v src=tiles.legality_lowzoom  -v tgt=tiles.legality_display_lowzoom
--
-- Memory discipline (the confirm-open wall-to-wall-union OOM lesson): subdivide inputs,
-- then grid-batch the union so no single ST_Union ever sees the whole nation. Output is
-- re-subdivided so tiles stay light (no monster single features).
-- ============================================================================
\set ON_ERROR_STOP on
SET statement_timeout = 0;
-- Grid cell size (deg) for the batched union. Finer = lower memory per cell but more
-- cell-boundary vertices (heavier tiles); coarser = fewer boundary vertices + more dissolution
-- (lighter tiles) but larger per-cell unions. Default 0.25° suits the big normal table; the
-- small generalized low-zoom source can afford a coarser grid for lighter z0–8 tiles.
\if :{?cellsize}
\else
  \set cellsize 0.25
\endif

DROP TABLE IF EXISTS :tgt;
CREATE TABLE :tgt (
  gid     bigserial PRIMARY KEY,
  verdict text NOT NULL,
  geom    geometry(MultiPolygon, 4326)
);

-- 1) Subdivide inputs to <=256 pts. Explodes the 195k–783k-pt monsters so per-piece
--    memory is bounded; ST_MakeValid guards against invalid source rings.
DROP TABLE IF EXISTS _lp_sub;
CREATE TEMP TABLE _lp_sub AS
SELECT verdict,
       (ST_Dump(ST_Subdivide(ST_MakeValid(geom), 256))).geom AS geom
FROM :src
WHERE verdict IN ('RED','YELLOW','GREEN') AND geom IS NOT NULL AND NOT ST_IsEmpty(geom);
DELETE FROM _lp_sub WHERE ST_GeometryType(geom) NOT IN ('ST_Polygon','ST_MultiPolygon');
CREATE INDEX ON _lp_sub USING gist (geom);

-- 2) 0.25° grid over the 8-state bbox. Per (verdict, cell), dissolve the cell-CLIPPED
--    pieces: bounded union (no OOM) and cell-clip => no cross-cell overlap.
DROP TABLE IF EXISTS _cells;
CREATE TEMP TABLE _cells AS
SELECT row_number() OVER () AS id, geom AS cell
FROM ST_SquareGrid(:cellsize, ST_MakeEnvelope(-125.0, 31.0, -102.0, 49.1, 4326));
CREATE INDEX ON _cells USING gist (cell);

DROP TABLE IF EXISTS _diss;
CREATE TEMP TABLE _diss AS
SELECT p.verdict, c.id AS cell_id,
       ST_CollectionExtract(ST_Union(ST_Intersection(p.geom, c.cell)), 3) AS geom
FROM _lp_sub p
JOIN _cells c ON p.geom && c.cell AND ST_Intersects(p.geom, c.cell)
GROUP BY p.verdict, c.id;
CREATE INDEX ON _diss (cell_id);

-- 3) Per-cell most-restrictive partition, then re-subdivide for tile weight:
--    RED as-is; YELLOW minus RED; GREEN minus (YELLOW ∪ RED).
INSERT INTO :tgt (verdict, geom)
SELECT verdict,
       ST_Multi((ST_Dump(ST_Subdivide(ST_CollectionExtract(ST_MakeValid(geom), 3), 256))).geom)
FROM (
  SELECT 'RED'::text AS verdict, geom
  FROM _diss WHERE verdict = 'RED'
  UNION ALL
  SELECT 'YELLOW',
         ST_Difference(y.geom, COALESCE(r.geom, ST_GeomFromText('POLYGON EMPTY', 4326)))
  FROM _diss y
  LEFT JOIN _diss r ON r.cell_id = y.cell_id AND r.verdict = 'RED'
  WHERE y.verdict = 'YELLOW'
  UNION ALL
  SELECT 'GREEN',
         ST_Difference(
           ST_Difference(g.geom, COALESCE(y.geom, ST_GeomFromText('POLYGON EMPTY', 4326))),
           COALESCE(r.geom, ST_GeomFromText('POLYGON EMPTY', 4326)))
  FROM _diss g
  LEFT JOIN _diss y ON y.cell_id = g.cell_id AND y.verdict = 'YELLOW'
  LEFT JOIN _diss r ON r.cell_id = g.cell_id AND r.verdict = 'RED'
  WHERE g.verdict = 'GREEN'
) parts
WHERE geom IS NOT NULL AND NOT ST_IsEmpty(geom) AND ST_Dimension(geom) = 2;

CREATE INDEX ON :tgt USING gist (geom);
CREATE INDEX ON :tgt (verdict);
GRANT SELECT ON :tgt TO tileserv_ro;

-- transparency readout
SELECT verdict, count(*) AS pieces, round(avg(ST_NPoints(geom)))::int AS avg_pts,
       max(ST_NPoints(geom)) AS max_pts
FROM :tgt GROUP BY verdict ORDER BY verdict;
