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

-- PREDICATE (review finding PP-2, CA half). The public predicate was `own_level IS NOT NULL`,
-- which counted EVERY ownership class CAL FIRE maps as confirming that PAD-US's GREEN is open:
-- State 12,412 km², Non Profit 4,096 km², Special District 3,304 km², City 2,878 km²,
-- Tribal 2,651 km², County 1,523 km² — 26,865 km² in total, including tribal land, which is
-- never open for collecting. Only Federal (194,700 km²) confirms open now.
--
-- Tribal and Non Profit are affirmatively NOT public-open, so they become a real carve layer.
-- CA has never had one (registry carve_private was null) because CAL FIRE maps public ownership
-- only — private land is simply absent rather than labelled. This does not close that gap, but
-- it does mean tribal and land-trust parcels are no longer blanketed by the federal buffer.
-- ST_SubDivide(512) like every generated state: CA tribal/land-trust parcels reach 370 km² and
-- 7,284 vertices, and feeding those whole into the per-buffer-row LATERAL union below is the
-- un-subdivided carve union that OOM-crashed this container on 2026-07-12
-- (gen_confirm_open.sh:58-60). Small pieces keep each union local and bounded.
DROP TABLE IF EXISTS staging.calfire_notpub;
CREATE TABLE staging.calfire_notpub AS
  SELECT ST_SubDivide(ST_MakeValid(geom), 512) AS geom FROM staging.calfire_ownership
  WHERE own_level IN ('Tribal','Non Profit');
CREATE INDEX calfire_notpub_gix ON staging.calfire_notpub USING GIST (geom);

-- Public but NOT open: state, city, county and special-district land. Permit or closure likely.
DROP TABLE IF EXISTS staging.calfire_nonopen;
CREATE TABLE staging.calfire_nonopen AS
  SELECT ST_SubDivide(ST_MakeValid(geom), 512) AS geom FROM staging.calfire_ownership
  WHERE own_level IN ('State','City','County','Special District');
CREATE INDEX calfire_nonopen_gix ON staging.calfire_nonopen USING GIST (geom);

-- pre-buffer CAL FIRE FEDERAL public by 100m in CA Albers (EPSG:3310) once, then carve the
-- affirmatively-not-public parcels back out so adjacency never blankets tribal/trust ground
-- (the same shape as every other state's carve).
DROP TABLE IF EXISTS staging.calfire_buf;
CREATE TABLE staging.calfire_buf AS
  SELECT ST_CollectionExtract(ST_MakeValid(ST_Difference(b.geom,
           COALESCE(np.geom, ST_GeomFromText('MULTIPOLYGON EMPTY', 4326)))), 3) AS geom
  -- Subdivide the buffer source too (generator pattern): un-subdivided this was fine when the
  -- step was a plain buffer, but it now feeds a per-row LATERAL difference.
  FROM (SELECT ST_Transform(ST_Buffer(ST_Transform(ST_SubDivide(ST_MakeValid(geom), 512), 3310), 100), 4326) AS geom
        FROM staging.calfire_ownership
        WHERE own_level = 'Federal') b          -- public_predicate (PP-2: was own_level IS NOT NULL)
  LEFT JOIN LATERAL (
    SELECT ST_Union(n.geom) AS geom FROM staging.calfire_notpub n WHERE ST_Intersects(n.geom, b.geom)
  ) np ON true;
CREATE INDEX calfire_buf_gix ON staging.calfire_buf USING GIST (geom);

-- per CA GREEN (PAD-US) polygon: subtract local buffered CAL FIRE -> unconfirmed-open YELLOW rows
INSERT INTO :legality_tbl
  (geom, verdict, reason, land_manager, unit_nm, protection_status, state_nm, data_vintage, source_key)
SELECT ST_Multi(d.geom), 'YELLOW',
  CASE WHEN d.nonopen_m2 > 400
    THEN 'State trust / state park / military land per CA ownership data (CAL FIRE) — permit or closure likely; ownership sources conflict. Verify before collecting.'
    ELSE 'Open status not confirmed by CA public-ownership data (CAL FIRE) — possibly private; verify before collecting.'
  END,
  NULL, NULL, 'unconfirmed-open', 'CA', 'CAL FIRE 2024 (confirm-open vs PAD-US)', 'calfire_ca'
FROM (
  SELECT frag.geom,
         COALESCE((SELECT ST_Area(ST_Intersection(frag.geom, ST_Union(n.geom))::geography)
                   FROM staging.calfire_notpub n WHERE ST_Intersects(n.geom, frag.geom)), 0) AS notpub_m2,
         COALESCE((SELECT ST_Area(ST_Intersection(frag.geom, ST_Union(no.geom))::geography)
                   FROM staging.calfire_nonopen no WHERE ST_Intersects(no.geom, frag.geom)), 0) AS nonopen_m2
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
  ) frag
  WHERE frag.geom IS NOT NULL AND NOT ST_IsEmpty(frag.geom)
) d
-- Sliver filter, same correction as every other state (PP-1/PP-18): the 2000 m² threshold is for
-- registration noise, but a fragment overlapping affirmatively-not-public or not-open ground is
-- signal and is kept down to the documented 400 m² floor (PROJECT_PLAN.md:2374).
WHERE ST_Area(d.geom::geography) > 2000
   OR d.notpub_m2  > 400
   OR d.nonopen_m2 > 400;

-- ============================================================================
-- PASS 2 — WIDTH-AWARE CARVE (review finding PP-3)
--
-- The 100 m buffer above is ONE-SIDED: it grows CAL FIRE public land outward and subtracts the
-- result. CAL FIRE maps public ownership only, so unlike every other state there is no
-- affirmative-private layer to carve back out of that buffer (registry carve_private is null).
-- Consequence: any private corridor narrower than ~200 m flanked by national forest is wholly
-- inside the forgiveness band and is exempted no matter how large it is. Mt Baldy Village sits
-- in a 361,956 m² contiguous piece with NO CAL FIRE public ownership anywhere inside it and
-- returned "Managing agency USFS — generally open"; Forest Falls, Fawnskin and the Sierra County
-- mining towns (Alleghany, Downieville, Sierra City) are the same shape.
--
-- This pass asks a question the buffer cannot: is the un-mapped-public residue WIDE, rather than
-- merely far from public land? Eroding each residual component by 25 m in EPSG:3310 leaves a core
-- only where the component is wider than ~50 m. That distinguishes a village from a boundary
-- strip by shape instead of by size — measured on this data, a 34,841 m² thin registration strip
-- erodes to nothing (correctly ignored) while Mt Baldy's 361,956 m² village keeps a 282,630 m²
-- core. A plain area threshold would have flagged both.
--
-- Anything the buffer pass already demoted is subtracted first, so this only adds new ground.
-- This does NOT make CA equivalent to the other states: without an affirmative-private layer,
-- narrow private strips under ~50 m wide remain unprotected. Closing that needs CA parcel data.
-- ============================================================================
INSERT INTO :legality_tbl
  (geom, verdict, reason, land_manager, unit_nm, protection_status, state_nm, data_vintage, source_key)
SELECT ST_Multi(d.geom), 'YELLOW',
  'Open status not confirmed by CA public-ownership data (CAL FIRE) — possibly private; verify before collecting.',
  NULL, NULL, 'unconfirmed-open', 'CA', 'CAL FIRE 2024 (confirm-open vs PAD-US)', 'calfire_ca'
FROM (
  SELECT (ST_Dump(ST_CollectionExtract(ST_MakeValid(ST_Difference(w.geom,
            COALESCE(y.already, ST_GeomFromText('MULTIPOLYGON EMPTY', 4326)))), 3))).geom AS geom
  FROM (
    -- residual GREEN with no CAL FIRE public ownership inside it, wide enough to have a core
    SELECT r.geom
    FROM (
      SELECT (ST_Dump(ST_CollectionExtract(ST_MakeValid(ST_Difference(g.geom,
                COALESCE(p.pub, ST_GeomFromText('MULTIPOLYGON EMPTY', 4326)))), 3))).geom AS geom
      FROM (SELECT ST_Subdivide(geom, 256) AS geom FROM :legality_tbl
            WHERE state_nm='CA' AND verdict='GREEN' AND source_key='padus') g
      LEFT JOIN LATERAL (
        SELECT ST_Union(c.geom) AS pub FROM staging.calfire_ownership c
        WHERE c.own_level IS NOT NULL AND ST_DWithin(c.geom, g.geom, 0.003)
      ) p ON true
    ) r
    -- The 4,000 m² pre-filter is a cost guard, not a policy threshold, and it is provably lossless
    -- against the core test below: the circle is the most area-efficient shape, and a circle needs
    -- ~4,140 m² before a 25 m erosion leaves a 400 m² core (r=36.3 m, core = pi*(11.3)^2 = 401 m²).
    -- Anything under 4,000 m² therefore cannot pass the core test in any shape, so skipping the
    -- erosion for those components changes no result — it only avoids running ST_Buffer over tens
    -- of thousands of small boundary fragments, which is what makes this pass affordable.
    WHERE r.geom IS NOT NULL AND NOT ST_IsEmpty(r.geom)
      AND ST_Area(r.geom::geography) > 4000
      AND NOT ST_IsEmpty(ST_Buffer(ST_Transform(r.geom, 3310), -25))
      AND ST_Area(ST_Buffer(ST_Transform(r.geom, 3310), -25)) > 400
  ) w
  LEFT JOIN LATERAL (
    SELECT ST_Union(l.geom) AS already FROM :legality_tbl l
    WHERE l.source_key = 'calfire_ca' AND ST_Intersects(l.geom, w.geom)
  ) y ON true
) d
WHERE d.geom IS NOT NULL AND NOT ST_IsEmpty(d.geom) AND ST_Area(d.geom::geography) > 400;

SELECT count(*) AS unconfirmed_polys, round((sum(ST_Area(geom::geography))/1e6)::numeric, 2) AS km2
FROM :legality_tbl WHERE source_key = 'calfire_ca';
