-- Confirm-Open step for UT (PROJECT_PLAN §6.4.1 / §6.13, decisions #30/#31; IMP-01).
-- "GREEN must be earned": where PAD-US says open (GREEN) but the authoritative UT ownership
-- layer (SGID/SITLA, staging.ugrc_ownership) shows NO public land within ~100m, the open status
-- is unconfirmed -> insert a YELLOW "unconfirmed / possibly-private" polygon. The existing
-- most-restrictive lookup then makes both the verdict AND the map render YELLOW there.
--
-- This closes the Alta false-GREEN (review finding F-1): PAD-US over-maps USFS/ski-area over the
-- private Alta townsite; SGID maps those parcels owner='Private', so the difference step flags them.
--
-- Generic confirm_open per §6.13 (here hard-wired to the UT/SGID registry entry):
--   public_predicate = owner IN ('Federal','State')   (Tribal/Private/NULL do NOT confirm open;
--                      the 4 null-owner slivers statewide are treated as not-confirmed, like
--                      CAL FIRE's own_level IS NULL)
--   buffer_m = 100   (absorbs PAD-US/SGID boundary-generalization mismatch, same as CA)
--   MINUS affirmative-private: unlike CAL FIRE (public-only layer), SGID also maps Private/
--   Tribal parcels. The 100m buffer exists only to absorb boundary mismatch — it must never
--   blanket a parcel the state authority affirmatively maps as Private (validation showed the
--   plain buffer forgave private inholdings adjacent to USFS near Alta, e.g. a 2.5 ha Grizzly
--   Gulch parcel). So: confirmed = buffer(public, 100m) − (Private ∪ Tribal ∪ NULL-owner).
-- Sliver threshold 500 m² (not CA's 2000): SGID is cadastral-grade, so real residential-lot
-- inholdings (500–1500 m²) are meaningful; only sub-500 m² artifacts are dropped.
-- Metric buffer in EPSG:26912 (NAD83 / UTM 12N — Utah-appropriate; CA uses 3310).
-- Idempotent: deletes prior ugrc_ut rows first. Prereq: staging.ugrc_ownership loaded
-- (pull_ugrc.sh); legality_polygons built with source_key (unify.sql).
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
DELETE FROM :legality_tbl WHERE source_key = 'ugrc_ut';

-- not-public parcels (affirmative private/tribal + the null-owner slivers)
DROP TABLE IF EXISTS staging.ugrc_notpub;
CREATE TABLE staging.ugrc_notpub AS
  SELECT ST_MakeValid(geom) AS geom FROM staging.ugrc_ownership
  WHERE owner IS NULL OR owner NOT IN ('Federal','State');
CREATE INDEX ugrc_notpub_gix ON staging.ugrc_notpub USING GIST (geom);

-- pre-buffer SGID public by 100m in UTM 12N, then carve affirmative-not-public back OUT
DROP TABLE IF EXISTS staging.ugrc_buf;
CREATE TABLE staging.ugrc_buf AS
  SELECT ST_CollectionExtract(ST_MakeValid(ST_Difference(b.geom,
           COALESCE(np.geom, ST_GeomFromText('MULTIPOLYGON EMPTY', 4326)))), 3) AS geom
  FROM (SELECT ST_Transform(ST_Buffer(ST_Transform(geom, 26912), 100), 4326) AS geom
        FROM staging.ugrc_ownership
        WHERE owner IN ('Federal','State')) b          -- public_predicate
  LEFT JOIN LATERAL (
    SELECT ST_Union(n.geom) AS geom FROM staging.ugrc_notpub n WHERE ST_Intersects(n.geom, b.geom)
  ) np ON true;
CREATE INDEX ugrc_buf_gix ON staging.ugrc_buf USING GIST (geom);

-- per UT GREEN (PAD-US) polygon: subtract local buffered SGID public -> unconfirmed-open YELLOW rows
INSERT INTO :legality_tbl
  (geom, verdict, reason, land_manager, unit_nm, protection_status, state_nm, data_vintage, source_key)
SELECT ST_Multi(d.geom), 'YELLOW',
  'Open status not confirmed by UT public-ownership data (Utah SGID/SITLA) — possibly private; verify before collecting.',
  NULL, NULL, 'unconfirmed-open', 'UT', 'Utah SGID land ownership 2026 (confirm-open vs PAD-US)', 'ugrc_ut'
FROM (
  SELECT (ST_Dump(
            ST_CollectionExtract(
              ST_MakeValid(ST_Difference(g.geom,
                COALESCE(b.buf, ST_GeomFromText('MULTIPOLYGON EMPTY', 4326)))), 3))).geom AS geom
  -- ST_Subdivide the (sometimes very large) GREEN polygons into ≤256-vertex pieces so each piece
  -- only matches a handful of local SGID buffers (same large-vs-many-small pattern as CA, #35).
  FROM (SELECT ST_Subdivide(geom, 256) AS geom FROM :legality_tbl
        WHERE state_nm='UT' AND verdict='GREEN' AND source_key='padus') g
  LEFT JOIN LATERAL (
    SELECT ST_Union(cb.geom) AS buf FROM staging.ugrc_buf cb WHERE ST_DWithin(cb.geom, g.geom, 0.003)
  ) b ON true
) d
-- SLIVER FILTER (review findings PP-1 / PP-18) — same correction as the generated states, applied
-- to UT's cadastral-grade 500 m² threshold. Applied to raw ST_Dump fragments the threshold erases
-- real private ground: the 100 m buffer erodes a parcel from every edge and the ST_Subdivide
-- chunk lines cut the remainder, so a large private block can survive only as sub-threshold
-- crumbs. A fragment overlapping affirmatively-not-public ground is signal, not noise, and is kept
-- down to the project's documented 400 m² "meaningful parcel" floor (PROJECT_PLAN.md:2374).
WHERE d.geom IS NOT NULL AND NOT ST_IsEmpty(d.geom)
  AND (
    ST_Area(d.geom::geography) > 500
    OR COALESCE((
         SELECT ST_Area(ST_Intersection(d.geom, ST_Union(n.geom))::geography)
         FROM staging.ugrc_notpub n
         WHERE ST_Intersects(n.geom, d.geom)
       ), 0) > 400
  );

SELECT count(*) AS unconfirmed_polys, round((sum(ST_Area(geom::geography))/1e6)::numeric, 2) AS km2
FROM :legality_tbl WHERE source_key = 'ugrc_ut';
