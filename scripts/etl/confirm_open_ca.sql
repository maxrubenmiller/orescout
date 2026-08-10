-- Confirm-Open step for CA (PROJECT_PLAN §6.4.1 / §6.13, decision #30/#31).
-- "GREEN must be earned": where PAD-US says open (GREEN) but the authoritative CA public-ownership
-- layer (CAL FIRE, staging.calfire_ownership) shows NO public land within ~100m, the open status is
-- unconfirmed -> insert a YELLOW "unconfirmed / possibly-private" polygon. The existing
-- most-restrictive lookup then makes both the verdict AND the map render YELLOW there (no divergence).
--
-- Generic confirm_open per §6.13 (here hard-wired to the CA/CAL FIRE registry entry):
--   public_predicate = own_level IS NOT NULL   (any CAL FIRE public; tighten to ='Federal' later)
--   buffer_m = 100   (absorbs PAD-US/CAL FIRE boundary-generalization mismatch -> only flags land
--                     genuinely >100m from any public; small holes near public are left GREEN)
-- Idempotent: deletes prior calfire_ca rows first. Prereq: staging.calfire_ownership loaded + valid
-- (pull_calfire.sh); legality_polygons built with source_key (unify.sql).
--
-- TARGET TABLE (review PP-8): reads and writes go to the psql variable :legality_tbl, defaulting
-- to the live tiles.legality_polygons. rebuild_legality.sh passes tiles.legality_polygons_new so
-- the whole sequence builds off to the side and reaches live only via atomic_swap after gating.
SET client_min_messages TO WARNING;

\if :{?legality_tbl}
\else
  \set legality_tbl tiles.legality_polygons
\endif

-- idempotency
DELETE FROM :legality_tbl WHERE source_key = 'calfire_ca';

-- pre-buffer CAL FIRE public by 100m in CA Albers (EPSG:3310) once
DROP TABLE IF EXISTS staging.calfire_buf;
CREATE TABLE staging.calfire_buf AS
  SELECT ST_Transform(ST_Buffer(ST_Transform(geom, 3310), 100), 4326) AS geom
  FROM staging.calfire_ownership
  WHERE own_level IS NOT NULL;          -- public_predicate
CREATE INDEX calfire_buf_gix ON staging.calfire_buf USING GIST (geom);

-- per CA GREEN (PAD-US) polygon: subtract local buffered CAL FIRE -> unconfirmed-open YELLOW rows
INSERT INTO :legality_tbl
  (geom, verdict, reason, land_manager, unit_nm, protection_status, state_nm, data_vintage, source_key)
SELECT ST_Multi(d.geom), 'YELLOW',
  'Open status not confirmed by CA public-ownership data (CAL FIRE) — possibly private; verify before collecting.',
  NULL, NULL, 'unconfirmed-open', 'CA', 'CAL FIRE 2024 (confirm-open vs PAD-US)', 'calfire_ca'
FROM (
  SELECT (ST_Dump(
            ST_CollectionExtract(
              ST_MakeValid(ST_Difference(g.geom,
                COALESCE(b.buf, ST_GeomFromText('MULTIPOLYGON EMPTY', 4326)))), 3))).geom AS geom
  -- ST_Subdivide the (sometimes very large) GREEN polygons into ≤256-vertex pieces so each piece
  -- only matches a handful of local CAL FIRE buffers. Without this, a big BLM desert GREEN polygon
  -- ST_DWithin-matches most of the 57k buffers and the per-polygon ST_Union blows up (v4.1 exposed
  -- this — a whole-polygon run hung >12 min). The dumped difference pieces are identical either way.
  FROM (SELECT ST_Subdivide(geom, 256) AS geom FROM :legality_tbl
        WHERE state_nm='CA' AND verdict='GREEN' AND source_key='padus') g
  LEFT JOIN LATERAL (
    SELECT ST_Union(cb.geom) AS buf FROM staging.calfire_buf cb WHERE ST_DWithin(cb.geom, g.geom, 0.003)
  ) b ON true
) d
WHERE d.geom IS NOT NULL AND NOT ST_IsEmpty(d.geom) AND ST_Area(d.geom::geography) > 2000;

SELECT count(*) AS unconfirmed_polys, round((sum(ST_Area(geom::geography))/1e6)::numeric, 2) AS km2
FROM :legality_tbl WHERE source_key = 'calfire_ca';
