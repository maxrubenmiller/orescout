-- ============================================================================
-- OreScout — Tier-A classifier fixtures, runnable form (PROJECT_PLAN.md §6.4.2)
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
      ('WA',   NULL,      '1',  'USFS', 'RED'),
      ('WSA',  NULL,      NULL, 'BLM',  'RED'),
      (NULL,   'PVT',     NULL, 'PVT',  'RED'),
      (NULL,   'PRIVATE', NULL, 'USFS', 'RED'),
      (NULL,   NULL,      NULL, 'BIA',  'RED'),
      (NULL,   NULL,      NULL, 'ARMY', 'RED'),
      ('WA',   NULL,      NULL, NULL,   'RED'),
      (NULL,   NULL,      NULL, 'BLM',  'GREEN'),
      (NULL,   NULL,      '3',  'BLM',  'GREEN'),
      ('NM',   NULL,      NULL, 'BLM',  'YELLOW'),
      ('ACEC', NULL,      NULL, 'BLM',  'YELLOW'),
      (NULL,   NULL,      NULL, 'ST',   'YELLOW'),
      (NULL,   NULL,      '2',  'BLM',  'YELLOW'),
      (NULL,   NULL,      NULL, NULL,   NULL)
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
