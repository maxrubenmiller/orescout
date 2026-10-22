-- CA Confirm-Open cross-check: how accurate is PAD-US "open" (GREEN) for CA, measured
-- against the authoritative CA public-ownership layer (CAL FIRE, staging.calfire_ownership)?
-- PROJECT_PLAN §6.4.1 (Confirm-Open) / docs/research/DATA_SOURCE_INVESTIGATION.md.
--
-- Prereq: ./scripts/etl/pull_calfire.sh  (loads + indexes staging.calfire_ownership; this script
-- also ST_MakeValid-repairs it). Run: docker compose exec -T postgres psql -U postgres -d miningapp -f /…/calfire_crosscheck.sql
--
-- TWO PITFALLS this query avoids (learned 2026-06-22):
--  (1) Sample by FINAL (most-restrictive) verdict, not "in any GREEN polygon" — ~half of GREEN-
--      polygon area is overlapped by a more-restrictive Wilderness/ACEC and is really RED/YELLOW.
--  (2) Use a ~100m buffer for the CAL FIRE "absent" test — the two datasets generalize differently,
--      so an exact point test flags boundary slivers as false over-claims.

SET client_min_messages TO WARNING;
UPDATE staging.calfire_ownership SET geom = ST_MakeValid(geom) WHERE NOT ST_IsValid(geom);

WITH green AS (SELECT ST_Union(geom) AS g FROM tiles.legality_polygons WHERE state_nm='CA' AND verdict='GREEN'),
pts AS (SELECT (ST_Dump(ST_GeneratePoints((SELECT g FROM green), 3000))).geom AS p),
final_green AS (   -- only points whose most-restrictive verdict is actually GREEN
  SELECT pts.p FROM pts CROSS JOIN LATERAL (
    SELECT verdict FROM tiles.legality_polygons WHERE ST_Contains(geom, pts.p)
    ORDER BY orescout_rank(verdict) DESC LIMIT 1) lr
  WHERE lr.verdict='GREEN'
),
c AS (SELECT p, EXISTS(SELECT 1 FROM staging.calfire_ownership cf WHERE ST_DWithin(cf.geom, p, 0.001)) AS near_public FROM final_green)
SELECT count(*) AS final_green_pts,
  count(*) FILTER (WHERE near_public)      AS confirmed_public_within_100m,
  count(*) FILTER (WHERE NOT near_public)  AS genuine_overclaim_candidates,
  round(100.0*count(*) FILTER (WHERE NOT near_public)/NULLIF(count(*),0),2) AS pct_overclaim
FROM c;

-- Result 2026-06-22 (3000-pt sample): 1487 final-GREEN, 1482 confirmed (99.66%), 5 over-claim (0.34%).
-- The over-claims are all within ~1km of public land (BLM/NF checkerboard) — ambiguous between
-- genuine private inholdings and CAL FIRE coverage/boundary gaps.
