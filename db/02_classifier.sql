-- ============================================================================
-- OreScout — Rules Engine, Stage-1 classifier (docs/planning/PROJECT_PLAN.md §6.4 / §6.6.1 "Half 1")
--
-- The SINGLE source of truth for the base-verdict rules. Pure functions, no
-- geometry — runnable and unit-testable now with no data loaded (Tier-A fixtures,
-- db/fixtures/). The spatial unify ("Half 2", §6.6.1.1) consumes these once real
-- PAD-US/SMA data is in `staging`; the MapLibre styles and the API both read the
-- resulting `verdict`, never the raw codes.
--
-- Literals CONFIRMED against live PAD-US data across ALL 8 states (§6.6.1.1) on 2026-06-18
-- (74,870 features). The manager classifier covers the full Mang_Name domain incl. special-
-- district / other-federal / unknown codes (RWD/JNT/UNK/OTHF/BOEM/ARS/NOAA/BPA/OTHR → YELLOW)
-- that appear in CA/CO/OR but not NV. NV-only baseline kept below for reference:
--   Des_Tp domain    : ACEC AGRE CONE FOTH HCA IRA LCA LHCA LOTH LP LREC MIL NCA NF
--                      NM NP NRA NWR OTHE PCON PPRK PUB REC RECE RMA RNA SCA SDA SHCA
--                      SOTH SP SREC SRMA TRIBL UNKE WA WSA WSR
--   Own_Type domain  : DESG DIST FED JNT LOC NGO PVT STAT TRIB UNK   (private = PVT, tribal = TRIB)
--   GAP_Sts          : '1'..'4' (text)
--   Mang_Name domain : BLM CITY CNTY DOD DOE FWS NGO NPS NRCS OTHS PVT REG SDC SDNR
--                      SDOL SFW SLB SPR TRIB UNKL USACE USBR USFS
-- The manager classifier accepts BOTH PAD-US Mang_Name and SMA ADMIN_AGENCY_CODE vocabularies
-- (they overlap on the common agencies; no code collides). Re-confirm on the v4 / 8-state run.
--
-- PAD-US 4.1 reconciliation (2026-07-01, decision #35): re-confirmed against v4.1 (86,913 feats,
-- 8 states) — 0 no-signal, 0 unmapped managers. 21 new Des_Tp codes appeared; 15 already resolved
-- via manager/own_type. New designation mappings added ("GREEN must be earned", #30):
--   SW (State Wilderness) -> RED;  NSBV (Natl Scenic/Botanical/Volcanic), REA (Research/Educational),
--   RANE (Ranch Easement), HCAE (Historic/Cultural Area) -> YELLOW.
--   NG (National Grassland) and NT (Natl Scenic/Historic Trail) intentionally left GREEN — the
--   underlying USFS land is open; the trail/grassland designation does not close casual collecting.
--
-- IMP-08 tightening (2026-07-02, decision #36, "GREEN must be earned"): designation codes that
-- previously fell through to manager-GREEN now contribute YELLOW —
--   REC (permitted-use recreation areas: ski resorts incl. Alta/Snowbird, campgrounds, summer-home
--        tracts — third-party rights), SDA (special designations: geological/geothermal areas, often
--        designated BECAUSE collecting is restricted), HCA/LHCA/SHCA (archaeological/historical —
--        ARPA territory), RMA (mineral reserve areas), SCA (state conservation), UNKE (unknown
--        easement). own_type UNK/LOC (unknown/local ownership) likewise no longer earns GREEN.
-- IRA (Inventoried Roadless) deliberately stays GREEN: roadless restricts mechanized travel, not
-- casual hand-tool collecting; the underlying NF is open (same reasoning as NG/NT in #35).
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
        WHEN upper(des_tp) IN ('NP','WA','WSA','NWR','SP','MIL','RNA','TRIBL','SW')      THEN 'RED'
        WHEN upper(coalesce(own_type,'')) IN ('PVT','TRIB')                        THEN 'RED'
        WHEN upper(des_tp) IN ('NM','ACEC','NCA','NRA','SWA','CONE','WSR','NSBV','REA','RANE','HCAE',
                               'REC','SDA','HCA','LHCA','SHCA','RMA','SCA','UNKE')  THEN 'YELLOW'
        WHEN upper(coalesce(own_type,'')) IN ('UNK','LOC')                          THEN 'YELLOW'
        WHEN gap_sts IN ('1','2')                                                  THEN 'YELLOW'
        ELSE NULL
      END,
      CASE
        WHEN upper(des_tp) IN ('NP','WA','WSA','NWR','SP','MIL','RNA','TRIBL','SW')
          THEN 'Protected designation: ' || des_tp
        WHEN upper(coalesce(own_type,'')) IN ('PVT','TRIB')
          THEN CASE WHEN upper(own_type)='TRIB' THEN 'Tribal land' ELSE 'Private land' END
        WHEN upper(des_tp) IN ('NM','ACEC','NCA','NRA','SWA','CONE','WSR','NSBV','REA','RANE','HCAE',
                               'REC','SDA','HCA','LHCA','SHCA','RMA','SCA','UNKE')
          THEN 'Ambiguous designation: ' || des_tp
        WHEN upper(coalesce(own_type,'')) IN ('UNK','LOC')
          THEN 'Ownership unknown/local — not confirmed open'
        WHEN gap_sts IN ('1','2') THEN 'GAP status ' || gap_sts || ' (strict protection)'
        ELSE NULL
      END;
$$;

-- ---- Classify the SMA surface-management agency code -----------------------
-- Accepts BOTH PAD-US Mang_Name and SMA ADMIN_AGENCY_CODE vocabularies (§6.6.1.1).
CREATE OR REPLACE FUNCTION orescout_classify_sma(agency text)
  RETURNS TABLE(verdict text, reason text) LANGUAGE sql IMMUTABLE AS $$
    SELECT
      CASE
        WHEN upper(agency) IN ('NPS','FWS','BIA','TRIB','ARMY','NAVY','USAF','USMC',
                               'USACE','DOD','DOE','NTVALL','NTVPIC','PVT')          THEN 'RED'
        WHEN upper(agency) IN ('ST','LG','USBR','OTHFE','OTHF','UND','UNK','CITY','CNTY',
                               'REG','RWD','SDC','SDNR','SDOL','SFW','SLB','SPR','NGO',
                               'NRCS','OTHS','OTHR','UNKL','JNT','BOEM','ARS','NOAA','BPA') THEN 'YELLOW'
        WHEN upper(agency) IN ('BLM','USFS')                                        THEN 'GREEN'
        ELSE NULL
      END,
      CASE
        WHEN upper(agency) IN ('NPS','FWS','BIA','TRIB','ARMY','NAVY','USAF','USMC',
                               'USACE','DOD','DOE','NTVALL','NTVPIC','PVT')
          THEN 'Managing agency ' || agency || ' — closed to casual collecting'
        WHEN upper(agency) IN ('ST','LG','USBR','OTHFE','OTHF','UND','UNK','CITY','CNTY',
                               'REG','RWD','SDC','SDNR','SDOL','SFW','SLB','SPR','NGO',
                               'NRCS','OTHS','OTHR','UNKL','JNT','BOEM','ARS','NOAA','BPA')
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
      -- ST_Covers, not ST_Contains (review finding PP-16): supported_region holds one MultiPolygon
      -- per state, so a shared state line is each polygon's BOUNDARY. ST_Contains excludes
      -- boundaries, so a GPS point exactly on e.g. the NV/CA line — interior to the supported
      -- region, both states supported — was contained by neither row and returned OUT_OF_REGION.
      -- Stage 1 already uses ST_Covers for exactly this reason (AssessmentService.cs:193-199);
      -- this makes Stage 0 agree. Fails safe either way (it denies rather than granting GREEN),
      -- which is why it was MEDIUM, but it is a correctness bug on real border coordinates.
      ELSE EXISTS (
        SELECT 1 FROM public.supported_region
        WHERE ST_Covers(geom, ST_SetSRID(ST_MakePoint(lng, lat), 4326)))
    END;
$$;
