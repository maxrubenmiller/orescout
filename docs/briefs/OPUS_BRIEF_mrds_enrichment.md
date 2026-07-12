# Opus Brief — MRDS related-tables popup enrichment (BACKLOG · Prospecting Intelligence)

**Task type:** reference-role ETL + popup · **Effort:** M · **Branch:** one branch, one commit
(or two: ETL then frontend); owner merges.
**Invariant (non-negotiable):** `tiles.mrds` is a `reference`-role layer (§6.13) — it must never
touch the verdict engine, and this task keeps it that way. Note `tiles.mrds` has one downstream
READER besides the map: `build_prospectivity.sql` consumes `geom` + `is_producer` (Signal 3).
Your change must be **additive** — never drop/rename existing columns, and rebuild via the
atomic-swap pattern so the table never disappears mid-read.

## The goal (from BACKLOG.md, "Enrich the gold popup")
The tiled layer carries only site/status/commodity-codes/grade/URL. The MRDS service exposes three
**related tables** keyed by `Record_ID` with much richer detail:
- **Commodity** — full commodity names with major-vs-minor `Importance` (far better than the raw
  space-delimited `CODE_LIST` we render now)
- **Materials** — ore / gangue / host-rock minerals (`Material_role`, `Material`)
- **Names** — alternate site names
Popup gains: full commodity list (majors emphasized), ore/gangue minerals, alt names — richer
detail *in-app*, with the existing "Full USGS record →" link unchanged.

## Known trap (resolve FIRST, before writing the ETL)
The related tables key on **`Record_ID`, NOT `DEP_ID`** — the join key must be resolved
empirically before anything else. Probe the FeatureServer's related-table endpoints
(`.../FeatureServer/0?f=json` lists relationships; `queryRelatedRecords` or the related layers
directly), determine how `Record_ID` maps to our stored `dep_id`, and REPORT the mapping with
evidence. If they genuinely can't be joined for a subset, count it and show the coverage rate —
no silent gaps (repo invariant: stated bounds, kept/dropped counts).

## How (mirror the repo's established patterns)
1. `scripts/etl/pull_mrds_details.sh`: paginated pull of the three related tables (gold-relevant
   records only — filter by the Record_IDs present in `staging.mrds_gold` / `tiles.mrds`) →
   `staging.mrds_commodity` etc. Follow `pull_mrds.sh` conventions (OID paging, UA, fail-fast).
2. Extend `scripts/etl/build_mrds.sql`: aggregate the details into **additive columns** on
   `tiles.mrds` (e.g. `commodities_major text`, `commodities_minor text`, `ore_minerals text`,
   `gangue_minerals text`, `alt_names text` — compact comma-joined strings; tiles carry every
   property to every client, keep them lean, cap pathological lengths with a stated bound).
   Rebuild into `tiles.mrds_new` + swap via `source scripts/etl/refresh_lib.sh` →
   `assert_schema` / `count_gate` / `atomic_swap` (the library exists for exactly this), then
   `stamp_source mrds reference ... - <ref> ok` to refresh the registry row.
3. Popup (`web/src/components/MapView.tsx`, mrds branch): show major commodities prominently,
   minors + minerals + alt names as compact secondary lines; keep max-width ~260-280px and the
   historic-record note. Keep `commodities` (raw CODE_LIST) rendering as fallback when the new
   fields are null.
4. `web/diag_mrds.mjs`: extend with assertions that a known enriched site's popup shows a full
   commodity name and a minerals line (pick a stable famous site and pin it; report which).

## Acceptance
- Join-key evidence + enrichment coverage rate (n sites enriched / 55,512, with the shortfall
  explained).
- `tiles.mrds` rebuild: additive columns only; existing columns byte-identical for a sample of
  100 dep_ids (show the check); `count_gate` ±10 passed; registry stamped.
- Prospectivity untouched: `./scripts/test/check_prospectivity_fixtures.sh` 3/3 AND
  `SELECT count(*) FROM tiles.prospectivity` unchanged (its build is NOT rerun by this task).
- Legality untouched: `./scripts/run-fixtures.sh` + `./scripts/run-tier-b.sh` green.
- `node web/diag_mrds.mjs` extended and green; tile budget: an MRDS-dense z9 tile stays < 500 KB
  (`curl -sq -o /dev/null -w '%{size_download}'` on a Grass Valley tile before/after — report both).
- tsc/eslint clean.

## Coordination & gotchas
Fable is concurrently building confirm-open expansion + parcel validation: do NOT touch
`scripts/etl/pull_ugrc.sh`, `pull_calfire.sh`, `confirm_open_*.sql`, `build_prospectivity.*`,
`db/fixtures/{verdicts,prospectivity}.json`, or anything under `staging.parcels*` /
`staging.*_ownership`. Machine gotchas: `~/.curlrc` adds retries (`curl -q` for evidence);
`COMPOSE_PROJECT_NAME=miningapp` needed only outside the main checkout; ScienceBase/ArcGIS
services flake — retry, don't conclude.
