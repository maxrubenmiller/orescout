-- ============================================================================
-- OreScout — Tier-A classifier fixtures, runnable form (docs/planning/PROJECT_PLAN.md §6.4.2)
--
-- Exercises orescout_base_verdict() against known attribute tuples. No data load
-- required. Run with ON_ERROR_STOP=1 so any mismatch makes psql exit non-zero
-- (see db/run-fixtures.sh). Keep in sync with db/fixtures/classifier.json.
-- ============================================================================
DO $$
DECLARE
  r      record;
  actual text;
  fails  int := 0;
  total  int := 0;
BEGIN
  FOR r IN
    SELECT * FROM (VALUES
      -- des_tp,  own_type,   gap_sts, agency,  expected
      ('NP'::text,  NULL::text, NULL::text, 'NPS'::text, 'RED'::text),
      ('WA',    NULL,   '1',  'USFS', 'RED'),
      ('WSA',   NULL,   NULL, 'BLM',  'RED'),
      ('TRIBL', NULL,   NULL, 'BLM',  'RED'),    -- tribal designation (confirmed code)
      (NULL,    'PVT',  NULL, 'PVT',  'RED'),    -- private ownership (confirmed: PVT)
      (NULL,    'TRIB', NULL, 'USFS', 'RED'),    -- tribal ownership overrides open manager
      (NULL,    NULL,   NULL, 'BIA',  'RED'),
      (NULL,    NULL,   NULL, 'TRIB', 'RED'),    -- tribal manager (PAD-US Mang_Name)
      (NULL,    NULL,   NULL, 'DOE',  'RED'),    -- DOE land, e.g. NV Test Site (confirmed code)
      (NULL,    NULL,   NULL, 'ARMY', 'RED'),
      ('WA',    NULL,   NULL, NULL,   'RED'),
      (NULL,    NULL,   NULL, 'BLM',  'GREEN'),
      (NULL,    NULL,   '3',  'BLM',  'GREEN'),
      ('NM',    NULL,   NULL, 'BLM',  'YELLOW'),
      ('ACEC',  NULL,   NULL, 'BLM',  'YELLOW'),
      ('WSR',   NULL,   NULL, 'BLM',  'YELLOW'), -- Wild & Scenic River (confirmed code)
      (NULL,    NULL,   NULL, 'ST',   'YELLOW'),
      (NULL,    NULL,   NULL, 'SPR',  'YELLOW'), -- state park/rec manager (PAD-US Mang_Name)
      (NULL,    NULL,   '2',  'BLM',  'YELLOW'),
      -- PAD-US 4.1 reconciliation (#35): new Des_Tp codes
      ('SW',    NULL,   NULL, 'USFS', 'RED'),    -- State Wilderness overrides an open manager
      ('NSBV',  NULL,   NULL, 'BLM',  'YELLOW'), -- Natl Scenic/Botanical/Volcanic Area
      ('REA',   NULL,   NULL, 'USFS', 'YELLOW'), -- Research/Educational Area
      ('RANE',  NULL,   NULL, 'BLM',  'YELLOW'), -- Ranch Easement (designation signal, not PVT own)
      ('HCAE',  NULL,   NULL, 'BLM',  'YELLOW'), -- Historic/Cultural Area
      ('NG',    NULL,   NULL, 'USFS', 'GREEN'),  -- National Grassland: open like National Forest
      ('NT',    NULL,   NULL, 'USFS', 'GREEN'),  -- Natl Scenic/Historic Trail: underlying land open
      -- IMP-08 tightening (#36): weak-affirmative tuples no longer earn GREEN
      ('REC',   'DESG', '4',  'USFS', 'YELLOW'), -- permitted-use rec area (ski resorts, e.g. Alta)
      ('SDA',   'DESG', '3',  'USFS', 'YELLOW'), -- special designation (geological/geothermal)
      ('HCA',   'DESG', '4',  'USFS', 'YELLOW'), -- archaeological/historical area (ARPA)
      ('RMA',   'DESG', '3',  'USFS', 'YELLOW'), -- mineral reserve area
      ('SCA',   'FED',  '3',  'USFS', 'YELLOW'), -- state conservation area designation
      ('UNKE',  'UNK',  '4',  'BLM',  'YELLOW'), -- unknown easement + unknown owner
      (NULL,    'LOC',  '4',  'USFS', 'YELLOW'), -- local-government-owned under USFS mgmt
      (NULL,    'UNK',  NULL, 'BLM',  'YELLOW'), -- unknown ownership never earns GREEN
      ('IRA',   'DESG', '3',  'USFS', 'GREEN'),  -- roadless stays GREEN (locked intentional, #36)
      (NULL,    NULL,   NULL, NULL,   NULL)
    ) AS t(des_tp, own_type, gap_sts, agency, expected)
  LOOP
    total := total + 1;
    SELECT verdict INTO actual
      FROM orescout_base_verdict(r.des_tp, r.own_type, r.gap_sts, r.agency);
    IF actual IS DISTINCT FROM r.expected THEN
      fails := fails + 1;
      RAISE WARNING 'FAIL  des_tp=%  own_type=%  gap_sts=%  agency=%  => got %  expected %',
        coalesce(r.des_tp,'—'), coalesce(r.own_type,'—'), coalesce(r.gap_sts,'—'),
        coalesce(r.agency,'—'), coalesce(actual,'NULL'), coalesce(r.expected,'NULL');
    END IF;
  END LOOP;

  RAISE NOTICE 'Tier-A classifier fixtures: % passed, % failed (of % total)',
    total - fails, fails, total;
  IF fails > 0 THEN
    RAISE EXCEPTION '% Tier-A fixture(s) FAILED', fails;
  END IF;
END
$$;
