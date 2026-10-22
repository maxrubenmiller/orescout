-- ============================================================================
-- OreScout — Tier-B prospecting-potential composite (PROJECT_PLAN §5.3; decision #42;
-- docs/briefs/TIER_B_FABLE_BRIEF.md scoring spec). REFERENCE-ONLY (§6.13): builds tiles.prospectivity,
-- never touches the verdict engine or legality tiles.
--
-- Driven by staging.prospectivity_config (jsonb from config/prospectivity.json — loaded by
-- build_prospectivity.sh). Generic over commodity: every entry in cfg->'commodities' is scored
-- in one pass; gold is the first populated commodity.
--
-- Scoring semantics (brief "Scoring spec", defaults):
--   * Scored samples = SEDIMENT sites (owner call #3) inside the 8 supported states.
--   * Per (sample, element): detected = qualified_value > 0 (negative = left-censored, the
--     release's canonical encoding); right-censored '>'/'G' values carry a literal +0.111
--     suffix (verified: 5,545 rows) -> stripped, kept as detected-at-floor.
--   * Anomaly percentile = percent_rank within (commodity, element, watershed pool), censored
--     ranked below all detected and kept in the denominator. Pool = HUC12 when it has
--     >= min_samples_per_pool samples AND >= min_detected_fraction detected; else its HUC10
--     (prefix roll-up); else the element is unscored there (hide, don't fabricate).
--   * Sample anomaly = MAX percentile across its scored indicator elements.
--   * Co-elevated pathfinder = a DIFFERENT detected element >= the p75 of DETECTED values in
--     its own pool.
--   * Tiers: High(producer)  = pctl >= high_producer_anomaly_pctl + >=1 pathfinder + producer
--            within proximity_m;
--            High(chemistry) = pctl >= high_chemistry_anomaly_pctl + >=2 pathfinders, the
--            commodity's required_pathfinder among the signal (as anomaly element OR
--            co-elevated) — the owner's Option-A escape hatch;
--            Moderate        = pctl >= moderate_anomaly_pctl + (>=1 pathfinder OR producer).
--            Everything else: NO ROW (locked: hide below Moderate).
--   * Site dedupe (owner call #1): one marker per rounded location (4 dp ~= 11 m), best tier.
--
-- Assertions (fail loud): WBD completeness — every in-boundary scored sample joins a HUC12.
-- Idempotent: drops and rebuilds tiles.prospectivity + its staging intermediates.
-- ============================================================================
SET client_min_messages TO WARNING;

-- ---- 0. config -> relational ------------------------------------------------
DROP TABLE IF EXISTS staging.prosp_cfg;
CREATE TABLE staging.prosp_cfg AS
SELECT c->>'key'                                            AS commodity,
       c->>'required_pathfinder'                            AS required_pathfinder,
       (c->>'proximity_m')::float                           AS proximity_m,
       (c->'thresholds'->>'moderate_anomaly_pctl')::float   AS mod_pctl,
       (c->'thresholds'->>'high_producer_anomaly_pctl')::float AS hi_prod_pctl,
       (c->'thresholds'->>'high_chemistry_anomaly_pctl')::float AS hi_chem_pctl,
       (c->'thresholds'->>'high_chemistry_min_pathfinders')::int AS hi_chem_min_pf,
       (c->'thresholds'->>'pathfinder_pctl')::float         AS pf_pctl,
       (c->'thresholds'->>'min_detected_fraction')::float   AS min_det_frac,
       (c->'thresholds'->>'min_samples_per_pool')::int      AS min_pool_n,
       (c->'producer_source'->>'predicate')                 AS producer_predicate,
       (c->'strings'->>'vintage_note')                      AS vintage_note
FROM staging.prospectivity_config, jsonb_array_elements(cfg->'commodities') AS c;

DROP TABLE IF EXISTS staging.prosp_ind;
CREATE TABLE staging.prosp_ind AS
SELECT c->>'key' AS commodity,
       e.element,
       CASE WHEN c->'method_filters' ? e.element
            THEN ARRAY(SELECT jsonb_array_elements_text(c->'method_filters'->e.element))
            ELSE NULL END AS method_patterns
FROM staging.prospectivity_config,
     jsonb_array_elements(cfg->'commodities') AS c,
     LATERAL (SELECT jsonb_array_elements_text(c->'indicator_elements') AS element) e;

-- ---- 1. scored samples: in-boundary sediment sites -> HUC12 ------------------
DROP TABLE IF EXISTS staging.prosp_samples;
CREATE TABLE staging.prosp_samples AS
SELECT s.lab_id, s.state, s.geom,
       h.huc12,
       left(h.huc12, 10) AS huc10       -- WBD codes are hierarchical (verified vs staging.wbd_huc10)
FROM staging.ngdb_sites s
JOIN staging.us_states8 st ON ST_Contains(st.geom, s.geom)
LEFT JOIN staging.wbd_huc12 h ON ST_Contains(h.geom, s.geom)
WHERE s.primary_class = 'sediment';
CREATE INDEX prosp_samples_labid ON staging.prosp_samples (lab_id);

-- WBD completeness assertion (brief): a sediment sample inside the 8-state boundary that lands
-- in NO HUC12 means the WBD extract is incomplete -> hard fail (0.1% slack for boundary slivers).
DO $$
DECLARE unmatched bigint; total bigint;
BEGIN
  SELECT count(*) FILTER (WHERE huc12 IS NULL), count(*) INTO unmatched, total FROM staging.prosp_samples;
  RAISE NOTICE 'prosp_samples: % in-boundary sediment samples, % unmatched to HUC12', total, unmatched;
  IF unmatched > total / 1000 THEN
    RAISE EXCEPTION 'WBD completeness FAILED: % of % in-boundary samples missing a HUC12 — the WBD extract is incomplete', unmatched, total;
  END IF;
END $$;
DELETE FROM staging.prosp_samples WHERE huc12 IS NULL;

-- ---- 2. per (sample, commodity, element) collapsed values --------------------
DROP TABLE IF EXISTS staging.prosp_vals;
CREATE TABLE staging.prosp_vals AS
SELECT p.lab_id, i.commodity, i.element, p.huc12, p.huc10, p.state, p.geom,
       bool_or(v.val > 0)                        AS detected,
       max(v.val) FILTER (WHERE v.val > 0)       AS det_ppm
FROM staging.ngdb_chem c
JOIN staging.prosp_ind i
  ON i.element = c.species
 AND (i.method_patterns IS NULL
      OR EXISTS (SELECT 1 FROM unnest(i.method_patterns) mp WHERE c.analytic_method ILIKE mp))
JOIN staging.prosp_samples p ON p.lab_id = c.lab_id
CROSS JOIN LATERAL (
  -- right-censored '>'/'G' carry a literal +0.111 suffix -> strip, keep as detected-at-floor
  SELECT CASE WHEN c.qualifier IN ('>','G') THEN c.qualified_value - 0.111
              ELSE c.qualified_value END AS val
) v
WHERE c.units = 'ppm'                             -- verified: 100% of indicator rows are ppm
GROUP BY 1,2,3,4,5,6,7;
CREATE INDEX prosp_vals_pool12 ON staging.prosp_vals (commodity, element, huc12);
CREATE INDEX prosp_vals_pool10 ON staging.prosp_vals (commodity, element, huc10);

-- ---- 3. pools (HUC12 with HUC10 roll-up) + per-element percentiles ------------
DROP TABLE IF EXISTS staging.prosp_pool12;
CREATE TABLE staging.prosp_pool12 AS
SELECT v.commodity, v.element, v.huc12,
       count(*) AS n, count(*) FILTER (WHERE detected) AS n_det,
       percentile_cont(0.75) WITHIN GROUP (ORDER BY det_ppm) FILTER (WHERE detected) AS p75_det
FROM staging.prosp_vals v GROUP BY 1,2,3;

DROP TABLE IF EXISTS staging.prosp_pool10;
CREATE TABLE staging.prosp_pool10 AS
SELECT v.commodity, v.element, v.huc10,
       count(*) AS n, count(*) FILTER (WHERE detected) AS n_det,
       percentile_cont(0.75) WITHIN GROUP (ORDER BY det_ppm) FILTER (WHERE detected) AS p75_det
FROM staging.prosp_vals v GROUP BY 1,2,3;

DROP TABLE IF EXISTS staging.prosp_scored;
CREATE TABLE staging.prosp_scored AS
SELECT v.*,
       CASE WHEN q12.ok THEN 'huc12' WHEN q10.ok THEN 'huc10' END AS pool_level,
       CASE WHEN q12.ok THEN v.pctl12 WHEN q10.ok THEN v.pctl10 END AS pctl,
       CASE WHEN q12.ok THEN p12.p75_det WHEN q10.ok THEN p10.p75_det END AS pool_p75_det
FROM (
  SELECT v.*,
         percent_rank() OVER (PARTITION BY v.commodity, v.element, v.huc12
                              ORDER BY v.detected, v.det_ppm NULLS FIRST) AS pctl12,
         percent_rank() OVER (PARTITION BY v.commodity, v.element, v.huc10
                              ORDER BY v.detected, v.det_ppm NULLS FIRST) AS pctl10
  FROM staging.prosp_vals v
) v
JOIN staging.prosp_cfg  g   USING (commodity)
JOIN staging.prosp_pool12 p12 ON (p12.commodity, p12.element, p12.huc12) = (v.commodity, v.element, v.huc12)
JOIN staging.prosp_pool10 p10 ON (p10.commodity, p10.element, p10.huc10) = (v.commodity, v.element, v.huc10)
CROSS JOIN LATERAL (SELECT p12.n >= g.min_pool_n AND p12.n_det::float / p12.n >= g.min_det_frac AS ok) q12
CROSS JOIN LATERAL (SELECT p10.n >= g.min_pool_n AND p10.n_det::float / p10.n >= g.min_det_frac AS ok) q10;

-- ---- 4. per-sample anomaly + co-elevated pathfinders --------------------------
DROP TABLE IF EXISTS staging.prosp_sample_score;
CREATE TABLE staging.prosp_sample_score AS
WITH anom AS (
  SELECT DISTINCT ON (lab_id, commodity)
         lab_id, commodity, huc12, state, geom,
         element AS anomaly_element, pctl AS anomaly_pctl
  FROM staging.prosp_scored
  WHERE pctl IS NOT NULL
  ORDER BY lab_id, commodity, pctl DESC, detected DESC, det_ppm DESC NULLS LAST
),
pf AS (  -- co-elevation: detected value >= p75 of DETECTED values in its own pool
  SELECT lab_id, commodity, array_agg(element ORDER BY element) AS pf_elements
  FROM staging.prosp_scored
  WHERE detected AND pool_level IS NOT NULL AND det_ppm >= pool_p75_det
  GROUP BY 1,2
)
SELECT a.*,
       COALESCE(array_remove(pf.pf_elements, a.anomaly_element), '{}') AS co_elevated,
       COALESCE(array_length(array_remove(pf.pf_elements, a.anomaly_element), 1), 0) AS pf_count,
       (a.anomaly_element = g.required_pathfinder
        OR g.required_pathfinder = ANY(COALESCE(pf.pf_elements, '{}'))) AS required_pf_ok
FROM anom a
JOIN staging.prosp_cfg g USING (commodity)
LEFT JOIN pf ON (pf.lab_id, pf.commodity) = (a.lab_id, a.commodity);

-- ---- 5. producer proximity (Signal 3) for candidates only ---------------------
-- Functional geography index: ST_DWithin(geography) cannot use the plain geometry GIST index —
-- without this, the candidate LATERAL degenerates to candidates x all-producers full scans
-- (observed: 44+ min and climbing on the first run; minutes with the index).
CREATE INDEX IF NOT EXISTS mrds_geog_idx ON tiles.mrds USING GIST ((geom::geography));
ANALYZE tiles.mrds;

DROP TABLE IF EXISTS staging.prosp_tiered;
CREATE TABLE staging.prosp_tiered AS
SELECT s.*, pr.site_name AS producer_name,
       pr.dist_m::int    AS producer_dist_m,
       CASE
         WHEN s.anomaly_pctl >= g.hi_prod_pctl AND s.pf_count >= 1 AND pr.site_name IS NOT NULL
           THEN 'High'
         WHEN s.anomaly_pctl >= g.hi_chem_pctl AND s.pf_count >= g.hi_chem_min_pf AND s.required_pf_ok
           THEN 'High'
         WHEN s.anomaly_pctl >= g.mod_pctl AND (s.pf_count >= 1 OR pr.site_name IS NOT NULL)
           THEN 'Moderate'
       END AS tier,
       CASE
         WHEN s.anomaly_pctl >= g.hi_prod_pctl AND s.pf_count >= 1 AND pr.site_name IS NOT NULL
           THEN 'producer'
         WHEN s.anomaly_pctl >= g.hi_chem_pctl AND s.pf_count >= g.hi_chem_min_pf AND s.required_pf_ok
           THEN 'chemistry'
       END AS tier_basis
FROM staging.prosp_sample_score s
JOIN staging.prosp_cfg g USING (commodity)
LEFT JOIN LATERAL (
  SELECT m.site_name, ST_Distance(m.geom::geography, s.geom::geography) AS dist_m
  FROM tiles.mrds m
  WHERE m.is_producer                       -- cfg.producer_predicate (gold pull is producer-flagged)
    AND ST_DWithin(m.geom::geography, s.geom::geography, g.proximity_m)
  ORDER BY m.geom <-> s.geom
  LIMIT 1
) pr ON true
WHERE s.anomaly_pctl >= g.mod_pctl;          -- only candidates need the producer lookup

-- ---- 6. site dedupe -> served table -------------------------------------------
DROP TABLE IF EXISTS tiles.prospectivity;
CREATE TABLE tiles.prospectivity (
    ogc_fid          bigserial PRIMARY KEY,
    geom             geometry(Point, 4326),
    tier             text CHECK (tier IN ('High','Moderate')),
    tier_basis       text CHECK (tier_basis IN ('producer','chemistry')),  -- High only, NULL for Moderate
    commodity        text,
    anomaly_element  text,
    anomaly_pctl     numeric(4,3),
    pathfinders      text,          -- co-elevated elements, comma-joined (excludes anomaly element)
    producer_name    text,
    producer_dist_m  int,
    huc12            text,
    n_samples        int,           -- co-located tiered samples collapsed into this marker
    state_nm         text,
    data_vintage     text,
    source_key       text
);

INSERT INTO tiles.prospectivity
    (geom, tier, tier_basis, commodity, anomaly_element, anomaly_pctl, pathfinders,
     producer_name, producer_dist_m, huc12, n_samples, state_nm, data_vintage, source_key)
SELECT (array_agg(t.geom       ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       (array_agg(t.tier       ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       (array_agg(t.tier_basis ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       t.commodity,
       (array_agg(t.anomaly_element ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       round(max(t.anomaly_pctl)::numeric, 3),
       (array_agg(array_to_string(t.co_elevated, ',') ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       (array_agg(t.producer_name   ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       (array_agg(t.producer_dist_m ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       (array_agg(t.huc12 ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       count(*),
       (array_agg(t.state ORDER BY (t.tier='High') DESC, t.anomaly_pctl DESC))[1],
       g.vintage_note,
       'ngdb_prospectivity'
FROM staging.prosp_tiered t
JOIN staging.prosp_cfg g USING (commodity)
WHERE t.tier IS NOT NULL
GROUP BY t.commodity, g.vintage_note,
         round(ST_X(t.geom)::numeric, 4), round(ST_Y(t.geom)::numeric, 4);

CREATE INDEX prospectivity_geom_idx ON tiles.prospectivity USING GIST (geom);
CREATE INDEX prospectivity_tier_idx ON tiles.prospectivity (tier);
GRANT SELECT ON tiles.prospectivity TO tileserv_ro;

-- ---- 7. transparency + reality check (brief acceptance) ------------------------
\echo '=== samples/pools transparency ==='
SELECT 'scored sediment samples (in-boundary, HUC-joined)' AS what, count(DISTINCT lab_id)::text AS n FROM staging.prosp_vals
UNION ALL
SELECT 'HUC12 pools OK / rolled to HUC10 / element-unscored',
       (SELECT count(*) FROM staging.prosp_pool12 p JOIN staging.prosp_cfg g USING (commodity)
        WHERE p.n >= g.min_pool_n AND p.n_det::float/p.n >= g.min_det_frac)::text
       || ' / ' ||
       (SELECT count(*) FROM staging.prosp_scored WHERE pool_level='huc10')::text
       || ' rows / ' ||
       (SELECT count(*) FROM staging.prosp_scored WHERE pool_level IS NULL)::text || ' rows'
;
\echo '=== state x tier (High split by basis) ==='
SELECT state_nm, tier, coalesce(tier_basis,'-') AS basis, count(*)
FROM tiles.prospectivity GROUP BY 1,2,3 ORDER BY 1, 2 DESC, 3;
\echo '=== top-10 HUC12s by High markers ==='
SELECT p.huc12, max(h.name) AS watershed, count(*) AS highs,
       count(*) FILTER (WHERE p.tier_basis='chemistry') AS chem_based
FROM tiles.prospectivity p LEFT JOIN staging.wbd_huc12 h USING (huc12)
WHERE p.tier = 'High'
GROUP BY p.huc12 ORDER BY highs DESC LIMIT 10;
