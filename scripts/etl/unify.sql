-- ============================================================================
-- OreScout — Half-2 spatial unify (docs/planning/PROJECT_PLAN.md §6.6.1).
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
--
-- TARGET TABLE (review PP-8): the table name is the psql variable :legality_tbl, defaulting to
-- the live tiles.legality_polygons so a standalone run behaves as before. rebuild_legality.sh
-- passes tiles.legality_polygons_new so the whole unify -> confirm-open sequence builds off to
-- the side and reaches the live table only via refresh_lib.sh's atomic_swap, AFTER its gates.
-- Building in place is what left a GREEN-reverted serving window between the DROP here and each
-- confirm-open commit, persisting indefinitely if a later step failed.
-- ============================================================================

\if :{?legality_tbl}
\else
  \set legality_tbl tiles.legality_polygons
\endif

DROP TABLE IF EXISTS :legality_tbl;

CREATE TABLE :legality_tbl (
    ogc_fid           bigserial PRIMARY KEY,
    geom              geometry(MultiPolygon, 4326),
    verdict           text CHECK (verdict IN ('RED','YELLOW','GREEN')),
    reason            text,
    land_manager      text,
    unit_nm           text,
    protection_status text,
    state_nm          text,
    data_vintage      text,
    source_key        text         -- registry provenance (§6.13): 'padus' base; 'calfire_ca' confirm_open; ...
);

INSERT INTO :legality_tbl
    (geom, verdict, reason, land_manager, unit_nm, protection_status, state_nm, data_vintage, source_key)
SELECT
    ST_Multi(ST_CollectionExtract(ST_MakeValid(s.geom), 3)),
    bv.verdict,
    bv.reason,
    s.mang_name,
    s.unit_nm,
    'GAP ' || s.gap_sts || COALESCE(' / ' || s.des_tp, ''),
    s.state_nm,
    'PAD-US 4.1 (ScienceBase State GDB, 8-state 2026-07-01)',
    'padus'
FROM staging.padus_staging s
CROSS JOIN LATERAL orescout_base_verdict(s.des_tp, s.own_type, s.gap_sts, s.mang_name) bv
WHERE bv.verdict IS NOT NULL
  AND s.geom IS NOT NULL
  AND NOT ST_IsEmpty(ST_CollectionExtract(ST_MakeValid(s.geom), 3));

-- Index names are left to Postgres (<table>_<col>_idx) rather than hardcoded: when the rebuild
-- targets tiles.legality_polygons_new, fixed names would collide with the live table's. The
-- '_new' infix is stripped by refresh_lib.sh's atomic_swap after the rename. Nothing references
-- these by name.
CREATE INDEX ON :legality_tbl USING GIST (geom);
CREATE INDEX ON :legality_tbl (verdict);
CREATE INDEX ON :legality_tbl (state_nm);

-- pg_tileserv's low-priv role must be able to read it (§6.8). Grants follow the table through
-- the rename, so granting on _new is enough.
GRANT SELECT ON :legality_tbl TO tileserv_ro;

-- Stamp the data vintage into meta so /meta + the panel report the shipping version (#35).
UPDATE public.meta SET value = 'PAD-US 4.1'                    WHERE key = 'padus_version';
UPDATE public.meta SET value = '2024 (ScienceBase State GDB)'  WHERE key = 'padus_date';

SELECT verdict, count(*) AS polygons FROM :legality_tbl GROUP BY verdict ORDER BY verdict;
