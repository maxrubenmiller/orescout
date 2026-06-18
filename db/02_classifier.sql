-- ============================================================================
-- OreScout — Rules Engine, Stage-1 classifier (PROJECT_PLAN.md §6.4 / §6.6.1 "Half 1")
--
-- The SINGLE source of truth for the base-verdict rules. Pure functions, no
-- geometry — runnable and unit-testable now with no data loaded (Tier-A fixtures,
-- db/fixtures/). The spatial unify ("Half 2", §6.6.1.1) consumes these once real
-- PAD-US/SMA data is in `staging`; the MapLibre styles and the API both read the
-- resulting `verdict`, never the raw codes.
--
-- ⚠ Provisional constants to confirm against real data in Half 2 (§6.6.1.1):
--   (1) private own_type values ('PVT'/'PRIVATE'/'PVL' is a guess)
--   (2) exact SMA agency-code spellings
--   (3) gap_sts type — compared here as text; ogr2ogr may load it as integer.
-- The LOGIC is locked; only these literals/types are provisional.
--
-- Idempotent: every function is CREATE OR REPLACE.
-- ============================================================================

-- ---- Verdict ranking: RED=3 > YELLOW=2 > GREEN=1 > 0 (no signal) ------------
-- "Most restrictive wins" reduces to MAX(rank) across contributors, which cleanly
-- subsumes the plan's "escalate only if not already higher" caveats.
CREATE OR REPLACE FUNCTION orescout_rank(verdict text) RETURNS int
  LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE verdict WHEN 'RED' THEN 3 WHEN 'YELLOW' THEN 2
                        WHEN 'GREEN' THEN 1 ELSE 0 END;
$$;

CREATE OR REPLACE FUNCTION orescout_rank_verdict(rank int) RETURNS text
  LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE rank WHEN 3 THEN 'RED' WHEN 2 THEN 'YELLOW'
                     WHEN 1 THEN 'GREEN' ELSE NULL END;
$$;

-- ---- Classify ONE PAD-US feature -------------------------------------------
-- From its designation / ownership / GAP attributes. Returns (NULL, NULL) when the
-- feature carries no recognized signal (contributes rank 0).
CREATE OR REPLACE FUNCTION orescout_classify_padus(
    des_tp text, own_type text, gap_sts text)
  RETURNS TABLE(verdict text, reason text) LANGUAGE sql IMMUTABLE AS $$
    SELECT
      CASE
        WHEN upper(des_tp) IN ('NP','WA','WSA','NWR','NWRA','SP','MIL','WIL','RNA') THEN 'RED'
        WHEN upper(coalesce(own_type,'')) IN ('PVT','PRIVATE','PVL')               THEN 'RED'
        WHEN upper(des_tp) IN ('NM','ACEC','NCA','NRA','SWA','CONE')               THEN 'YELLOW'
        WHEN gap_sts IN ('1','2')                                                  THEN 'YELLOW'
        ELSE NULL
      END,
      CASE
        WHEN upper(des_tp) IN ('NP','WA','WSA','NWR','NWRA','SP','MIL','WIL','RNA')
          THEN 'Protected designation: ' || des_tp
        WHEN upper(coalesce(own_type,'')) IN ('PVT','PRIVATE','PVL') THEN 'Private land'
        WHEN upper(des_tp) IN ('NM','ACEC','NCA','NRA','SWA','CONE')
          THEN 'Ambiguous designation: ' || des_tp
        WHEN gap_sts IN ('1','2') THEN 'GAP status ' || gap_sts || ' (strict protection)'
        ELSE NULL
      END;
$$;

-- ---- Classify the SMA surface-management agency code -----------------------
CREATE OR REPLACE FUNCTION orescout_classify_sma(agency text)
  RETURNS TABLE(verdict text, reason text) LANGUAGE sql IMMUTABLE AS $$
    SELECT
      CASE
        WHEN upper(agency) IN ('NPS','FWS','BIA','ARMY','NAVY','USAF','USMC',
                               'USACE','DOD','NTVALL','NTVPIC','PVT')  THEN 'RED'
        WHEN upper(agency) IN ('ST','LG','USBR','OTHFE','UND')         THEN 'YELLOW'
        WHEN upper(agency) IN ('BLM','USFS')                          THEN 'GREEN'
        ELSE NULL
      END,
      CASE
        WHEN upper(agency) IN ('NPS','FWS','BIA','ARMY','NAVY','USAF','USMC',
                               'USACE','DOD','NTVALL','NTVPIC','PVT')
          THEN 'Managing agency ' || agency || ' — closed to casual collecting'
        WHEN upper(agency) IN ('ST','LG','USBR','OTHFE','UND')
          THEN 'Managing agency ' || agency || ' — permit / varies'
        WHEN upper(agency) IN ('BLM','USFS')
          THEN 'Managing agency ' || agency || ' — generally open'
        ELSE NULL
      END;
$$;

-- ---- Combine one PAD-US feature + the SMA agency into a base verdict --------
-- Final base verdict = the verdict at GREATEST(rank(padus), rank(sma)). NULL when
-- neither contributes a signal (rank 0) → no legality polygon → the request-time
-- no-data/UNKNOWN path (§6.4). This is the unit the Tier-A fixtures exercise.
-- (Half 2 first takes MAX rank across ALL overlapping PAD-US features, then combines
--  with the SMA feature — the same max-rank logic, extended over a feature set.)
CREATE OR REPLACE FUNCTION orescout_base_verdict(
    des_tp text, own_type text, gap_sts text, agency text)
  RETURNS TABLE(verdict text, reason text) LANGUAGE sql IMMUTABLE AS $$
    WITH p AS (SELECT * FROM orescout_classify_padus(des_tp, own_type, gap_sts)),
         s AS (SELECT * FROM orescout_classify_sma(agency))
    SELECT
      orescout_rank_verdict(
        GREATEST(orescout_rank((SELECT verdict FROM p)),
                 orescout_rank((SELECT verdict FROM s)))),
      CASE
        WHEN GREATEST(orescout_rank((SELECT verdict FROM p)),
                      orescout_rank((SELECT verdict FROM s))) = 0 THEN NULL
        WHEN orescout_rank((SELECT verdict FROM s))
             > orescout_rank((SELECT verdict FROM p)) THEN (SELECT reason FROM s)
        ELSE (SELECT reason FROM p)
      END;
$$;

-- ---- Stage-0 in-region gate (§6.4) -----------------------------------------
-- True if the point is inside the 8 supported states. While supported_region is
-- empty (before the ETL loads boundaries) the gate is DISABLED (returns true) so
-- local dev is not blocked; once populated it enforces OUT_OF_REGION.
CREATE OR REPLACE FUNCTION orescout_in_region(lat double precision, lng double precision)
  RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT CASE
      WHEN NOT EXISTS (SELECT 1 FROM public.supported_region) THEN true
      ELSE EXISTS (
        SELECT 1 FROM public.supported_region
        WHERE ST_Contains(geom, ST_SetSRID(ST_MakePoint(lng, lat), 4326)))
    END;
$$;
