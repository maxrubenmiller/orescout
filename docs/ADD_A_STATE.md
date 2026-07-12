# Adding a state (the §6.13 runbook)

OreScout is designed so onboarding a state is a **data change, not a code change**. The 🔒 invariant
(PROJECT_PLAN §6.13): **adding a state = one entry in [`etl/sources.json`](../etl/sources.json)** (+ a
small classifier mapping only if the new source uses owner/manager codes the classifier hasn't seen).
The assessment engine, tile layer, and frontend never change. If you find yourself editing any of
those, the abstraction has been violated — fix the abstraction, not the engine.

This runbook is split into the **mechanical spine** (scriptable, low-risk) and the **judgment core**
(needs a human/capable model + verification). The judgment core is where the real work is.

---

## TL;DR checklist

1. [ ] Add a `base` coverage: the new state must be in PAD-US's `states[]` (it already lists all; a
       new state just gets added to that array) and have a PAD-US State GDB available.
2. [ ] **Judgment:** find the state's authoritative public-ownership layer, confirm its license.
3. [ ] **Judgment:** derive the `public_predicate` from that layer's owner-code domain.
4. [ ] Add a `confirm_open` entry to `etl/sources.json` (access + confirm block + provenance).
5. [ ] Add the state to `SupportedStates` in `src/OreScout.Api/appsettings.json`.
6. [ ] **Judgment:** run `classifier-auditor` — triage any new PAD-US/SMA codes into
       `db/02_classifier.sql` (default unknowns to YELLOW, never GREEN).
7. [ ] Pull + build: `./scripts/etl/pull_sma.sh <st>` → `./scripts/etl/gen_confirm_open.sh <st>` →
       run it (or `./scripts/etl/refresh_confirm_open.sh <st>`).
8. [ ] **Verify:** `registry_roundtrip.sh`, `supported_states_sync.sh`, `run-fixtures.sh` (Tier-A),
       `run-tier-b.sh`, and the confirm-open ±40% row-count band.
9. [ ] Add ≥2 Tier-B golden points for the new state.
10. [ ] Update provenance: `./scripts/etl/run.sh provenance | psql …`.

`./scripts/etl/run.sh --state <XX>` prints the full per-state pipeline (dry-run) at any point.

---

## The mechanical spine (scriptable)

Everything the registry drives. Once the `sources.json` entry exists, these need no per-state code:

- **Pull** — `pull_sma.sh <st>` reads `access.{url,fields,page}` from the registry (5 BLM/ODF/IDL
  states ride the same ArcGIS adapter). Bespoke loaders (`pull_ugrc.sh`, `pull_calfire.sh`) are named
  in the entry's `loader`.
- **Confirm-open SQL** — `gen_confirm_open.sh <st>` reads `confirm.{staging,public_predicate,crs,
  buffer_m,sliver_min_m2}` + attribution/vintage and writes the committed `confirm_open_<st>.sql`
  from the one canonical template (OOM-safe `ST_SubDivide`, parcel-grade carve). Bespoke states set
  `sql` to a committed path instead of `"generated"`.
- **Refresh + gates** — `refresh_confirm_open.sh <st>` reads staging/schema_cols/loader/sql/vintage/
  upstream_ref/max_age_days and runs pull → confirm SQL (one transaction) → row-count band →
  fixtures → Tier-B → freshness stamp.
- **State lists** — `load_padus_gdb.sh`, `refresh_claims.sh`, `load_supported_region.sh`,
  `pull_ngdb.sh`, `pull_wbd.sh` all derive the state list from the registry (`registry_lib.sh`).
- **Provenance** — `run.sh provenance` emits the `data_sources` UPSERT from the registry.

## The judgment core (needs a person / capable model + verification)

A registry can *hold* these but cannot *author* them. This is the actual work of adding a state:

1. **Source discovery + license.** Find the best free authoritative public-ownership layer for the
   state (BLM state SMA, a state GIS portal, etc.). Confirm the license permits ingest **and**
   display. Record `url`, `fields`, `license`, `attribution`, `upstream_ref`.
2. **The `public_predicate`** — *the* deliverable. Every state's layer uses a different owner/manager
   column and vocabulary (`abbr`, `category`, `adm_code`, `own`, `landmanager`, `mgmt_agncy`, …).
   Inspect the live layer's distinct code values and decide which count as PUBLIC. Policy: public-but-
   closed classes (DOD/DOE/MIL) **do** count as public for the buffer (closure is the classifier's
   job); everything not matching — affirmative private, tribal, water, null — is carved back out.
3. **New classifier codes.** If the state's PAD-US/SMA data carries owner/manager codes the
   classifier's `IN (...)` lists don't recognize, they fall through to no verdict. Triage each into
   `db/02_classifier.sql` — **default unknown/ambiguous codes to YELLOW, never GREEN** (GREEN must be
   earned). This is the invariant's sanctioned "small classifier mapping." Use the `classifier-auditor`
   agent; the invariant to enforce is *zero unmapped verdicts*.
4. **CRS / sliver / buffer.** `crs` = 5070 (CONUS Albers) for interior states; a coastal/edge state
   may need a state-plane/UTM CRS. `sliver_min_m2` tracks source resolution (cadastral 500, GCDB/PLSS
   1000, generalized 2000). Tune if the reality check shows noise.

## Verification gates (all must pass before the state is "live")

| Gate | Command | Catches |
|---|---|---|
| Registry faithful | `./scripts/test/registry_roundtrip.sh` | typos in the new entry |
| ETL/API in sync | `./scripts/test/supported_states_sync.sh` | forgot `appsettings.SupportedStates` |
| Tier-A fixtures | `./scripts/run-fixtures.sh` | classifier regressions |
| Tier-B goldens | `./scripts/run-tier-b.sh <api>` | end-to-end verdict regressions (needs API up) |
| Confirm-open band | (built into `refresh_confirm_open.sh`) | YELLOW row count outside ±40% of prior |
| Zero unmapped | `classifier-auditor` agent | owner/manager codes with no verdict |

The confirm-open band and the zero-false-GREEN private validation exist because SMA sources are
GCDB/PLSS-grade and can miss parcel-sized private inholdings — the Tier-1 validation once caught 9
real false-GREENs in CO/NM cabin/ranch country. Do not skip the gates for a legality product.

## Why two files, not one (the `appsettings` caveat)

Adding a state touches `etl/sources.json` **and** `src/OreScout.Api/appsettings.json` (`SupportedStates`).
The API deliberately doesn't parse the ETL registry at runtime (keeps them decoupled), so the two are
kept honest by `supported_states_sync.sh`, which fails if they drift. Everything else — loaders, tiles,
the frontend mask (via `/meta`), provenance — derives from the single registry.
