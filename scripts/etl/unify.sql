-- ============================================================================
-- OreScout — Half-2 spatial unify (PROJECT_PLAN.md §6.6.1).
-- Builds tiles.legality_polygons from staging by baking in the Stage-1 verdict
-- (orescout_base_verdict) per feature. The assessment engine and the map tiles
-- both read the resulting `verdict`.
--
-- NV validation slice: source is staging.padus_staging (PAD-US Mang_Name feeds the
-- manager classifier; Des_Tp/Own_Type/GAP_Sts feed the designation rules). The
-- production / 8-state run cross-checks SMA per §5.1; here PAD-US alone suffices.
--
-- Geometry: ST_MakeValid repairs the ~3% invalid rings/nested shells found in the
-- raw data; ST_CollectionExtract(...,3) keeps only polygonal parts after repair.
-- Idempotent: drops and rebuilds the table.
-- ============================================================================

DROP TABLE IF EXISTS tiles.legality_polygons;

CREATE TABLE tiles.legality_polygons (
    ogc_fid           bigserial PRIMARY KEY,
    geom              geometry(MultiPolygon, 4326),
    verdict           text CHECK (verdict IN ('RED','YELLOW','GREEN')),
    reason            text,
    land_manager      text,
    unit_nm           text,
    protection_status text,
    state_nm          text,
    data_vintage      text
);

INSERT INTO tiles.legality_polygons
    (geom, verdict, reason, land_manager, unit_nm, protection_status, state_nm, data_vintage)
SELECT
    ST_Multi(ST_CollectionExtract(ST_MakeValid(s.geom), 3)),
    bv.verdict,
    bv.reason,
    s.mang_name,
    s.unit_nm,
    'GAP ' || s.gap_sts || COALESCE(' / ' || s.des_tp, ''),
    s.state_nm,
    'PAD-US v3.0 (live layer, NV slice 2026-06-18)'
FROM staging.padus_staging s
CROSS JOIN LATERAL orescout_base_verdict(s.des_tp, s.own_type, s.gap_sts, s.mang_name) bv
WHERE bv.verdict IS NOT NULL
  AND s.geom IS NOT NULL
  AND NOT ST_IsEmpty(ST_CollectionExtract(ST_MakeValid(s.geom), 3));

CREATE INDEX legality_geom_idx    ON tiles.legality_polygons USING GIST (geom);
CREATE INDEX legality_verdict_idx ON tiles.legality_polygons (verdict);
CREATE INDEX legality_state_idx   ON tiles.legality_polygons (state_nm);

-- pg_tileserv's low-priv role must be able to read it (§6.8).
GRANT SELECT ON tiles.legality_polygons TO tileserv_ro;

SELECT verdict, count(*) AS polygons FROM tiles.legality_polygons GROUP BY verdict ORDER BY verdict;
