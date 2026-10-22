# OreScout — developer notes

Build history, data runbooks and deferred enhancements. This was the project README during
development; the current overview is the [project README](../README.md).

> **Source of truth:** the full engineering plan lives in [`docs/planning/PROJECT_PLAN.md`](planning/PROJECT_PLAN.md)
> (vision, scope, data sources, architecture, rules engine, schema, ETL, decisions log).

## Status

**Phase 1 backend skeleton is up and verified** (data-independent parts). Done:
- Docker Postgres+PostGIS (+ pg_tileserv), schemas/role/meta/`supported_region` via `db/01_init.sql`.
- **Half-1 rules-engine classifier** (`db/02_classifier.sql`) — **Tier-A fixtures 15/15 green**.
- ASP.NET Core API (`src/OreScout.Api`): `health`, `meta`, `geocode` (live Nominatim proxy),
  `assessment` (Stage-0 gate + honest `dataGaps` until the ETL runs), `pins` CRUD + GPX export,
  `X-Api-Key` auth, CORS. EF Core migration created the `pins` table (geom column, GIST/GIN
  indexes, updated_at trigger). All endpoints smoke-tested end-to-end.

**ETL — all 8 states loaded** (the Half-2 spatial unify, real data):
- **86,913 PAD-US 4.1 features** across NV/CA/AZ/CO/UT/NM/OR/ID, ingested from the ScienceBase
  **State GDB downloads** via `scripts/etl/load_padus_gdb.sh` → `staging.padus_staging`. (The earlier
  live-REST pull, `pull_states_padus.sh`, was retired — the AGOL query API rate-limits bulk pulls;
  see PROJECT_PLAN §6.6.1 / decision #35.)
- §6.6.1.1 inspection **at scale** confirmed the classifier domains across all 8 states and added 9
  manager codes that appear in CA/CO/OR but not NV (`RWD/JNT/UNK/OTHF/BOEM/ARS/NOAA/BPA/OTHR` →
  YELLOW). Result: **0** features with an unmapped verdict. Tier-A fixtures 20/20.
- `scripts/etl/unify.sql` bakes the verdict into `tiles.legality_polygons` (`ST_MakeValid` repairs
  invalid rings). Result: **12,469 RED / 58,994 YELLOW / 3,407 GREEN** polygons.
- Verified end-to-end: every NP (Yosemite/Grand Canyon/Rocky Mtn/Zion/Crater Lake/Carlsbad) → RED,
  Sawtooth Wilderness (ID) → RED, open BLM → GREEN, downtown Denver → no-data UNKNOWN (private).
  Overlays render across all states (tile bounds now span the full 8-state region).
- *Source is the live PAD-US v3.0 layer; data-currency upgrade to PAD-US 4.2 is a documented
  follow-up (docs/planning/TODO.md / ScienceBase item 65294599d34e44db0e2ed7cf).*

**Overlay tiles + region gate are live:**
- pg_tileserv publishes **only** `tiles.legality_polygons` (verified: `public.pins` is not exposed)
  at `http://localhost:7800/tiles.legality_polygons/{z}/{x}/{y}.pbf` — real MVT tiles served over NV.
- `public.supported_region` populated (8-state boundaries, `scripts/etl/load_supported_region.sh`),
  so the Stage-0 gate now returns **OUT_OF_REGION** outside NV/CA/AZ/CO/UT/NM/OR/ID (verified:
  Texas → OUT_OF_REGION, NV → real verdict). `web/public/assets/us-states.geojson` is the
  all-states asset for the frontend out-of-scope mask.

**Live mining-claims check is implemented** (`MlrsClaimsService`, plan §5.1/§6.4 Stage 2):
- Live BLM MLRS 100m-buffer query; any not-closed claim escalates the verdict up to YELLOW
  (never RED) with a disposition-accurate warning + per-claim MLRS deep-links, and resolves a
  no-data `UNKNOWN` into `KNOWN` (a claim proves federal mineral estate). Verified at Round
  Mountain (active claim) and open BLM (filed claims). 10s timeout; on failure the land verdict
  is still returned with `activeClaims:null` + a `dataGap` (§6.3 partial-failure, verified).

**Mining claims overlay (nightly tiles):** `scripts/etl/refresh_claims.sh` ingests all not-closed
BLM MLRS claims for the 8 states into `tiles.claims_polygons` (**487,842 claims**), served as
vector tiles; the frontend "Active mining claims" layer renders them orange (minzoom 9). The
per-point live MLRS check in `/assessment` is unchanged. (Still to automate: a nightly schedule.)

**Still to do:** PAD-US 4.2 data-currency upgrade; PostGIS→503 edge case; frontend polish. The
SMA cross-check was evaluated and dropped (decision #28 — LimitedScale too coarse). See `docs/planning/TODO.md`.

### Rebuild the legality layer (PAD-US 4.1)
```bash
docker compose up -d postgres
./scripts/etl/load_padus_gdb.sh          # downloads missing state zips automatically (decision #43,
                                         # supersedes #35's manual step) + ogr2ogr -> staging
./scripts/etl/padus_reconcile_gate.sh    # release-bump gate: fails loud on unmapped codes (#35 lesson)
./scripts/etl/rebuild_legality.sh        # unify + ALL confirm-open steps + Tier-A/B gates
```

> **Do not run `unify.sql` by hand.** It drops and rebuilds `tiles.legality_polygons` with PAD-US
> rows only — the confirm-open YELLOW rows (CA CAL FIRE, …) come from the separate
> `confirm_open_*.sql` scripts, so a bare unify silently reverts them to GREEN.
> `rebuild_legality.sh` runs the full sequence, asserts each confirm-open step inserted rows, and
> gates on the Tier-A + Tier-B fixtures (which include confirm-open golden points).

### Per-state source registry (§6.13) — adding a state

Every per-state parameter lives in **[`etl/sources.json`](../etl/sources.json)** (the single source of
truth; field spec in [`etl/sources.schema.md`](../etl/sources.schema.md), read via
`scripts/etl/registry_lib.sh`). The 🔒 invariant: **adding a state = one registry entry** (+ a small
classifier mapping only for a new attribute vocabulary) — the engine, tiles, and frontend never change.

```bash
./scripts/etl/run.sh --state NV          # dry-run: print a state's full role-ordered pipeline
./scripts/etl/run.sh provenance          # emit the registry-derived data_sources UPSERT
./scripts/test/registry_roundtrip.sh     # prove the registry matches what the scripts expect
./scripts/test/supported_states_sync.sh  # assert etl/sources.json ⇄ appsettings.SupportedStates
```

**Full runbook (mechanical spine + judgment core + verification gates):
[`docs/ADD_A_STATE.md`](ADD_A_STATE.md).**

## Quick start

Prereqs: Docker, .NET 10 SDK. (`dotnet-ef` via `dotnet tool install --global dotnet-ef`; on
Homebrew dotnet you may need `export DOTNET_ROOT="$(brew --prefix dotnet)/libexec"`.)

```bash
# 1. Infrastructure (applies db/01_init.sql + db/02_classifier.sql on first boot)
docker compose up -d postgres

# 2. Prove the rules engine (no app/data needed)
./scripts/run-fixtures.sh            # -> "Tier-A classifier fixtures: 15 passed, 0 failed"

# 3. Create the pins table
cd src/OreScout.Api && dotnet ef database update && cd ../..

# 4. Run the API  (http://localhost:5167 — NOT 5000; macOS AirPlay Receiver squats port 5000)
dotnet run --project src/OreScout.Api

# Smoke test (default dev key in appsettings.json):
curl localhost:5167/api/v1/health
curl -H "X-Api-Key: dev-local-key-change-me" "localhost:5167/api/v1/assessment?lat=39.5&lng=-117.0"
```

Tile server (optional until overlays exist): `docker compose up -d pg_tileserv`. Full bootstrap
order and the production path are in [`docs/planning/PROJECT_PLAN.md`](planning/PROJECT_PLAN.md) §6.8 / §6.11.

---

## Prospecting intelligence: how the "Prospecting potential" overlay works

The map's **"Prospecting potential (gold)"** layer answers *"where is it genuinely worth
checking?"* — not "where do gold atoms exist" (trace gold is everywhere). It is a **display-only
reference overlay**: it never feeds the RED/YELLOW/GREEN legality verdict, and a marker says
nothing about whether collecting is *legal* there — click the spot to get the legality assessment
separately.

### The reasoning

Raw gold assays can't drive this map, for a reason worth understanding: in the USGS geochemistry
database, most stream-sediment samples were analyzed by methods whose **detection floor for gold
sits far above natural background** (0.1–8 ppm floors vs ~0.001–0.005 ppm background). ~89% of
gold determinations are "below detection" — the instrument couldn't see that low. So the score is
**pathfinder-led**: arsenic, antimony, and silver travel with gold in the same ore-forming fluids,
are measurable at trace levels, and are the classic gold-exploration signals (the Carlin-trend
deposits — the biggest US gold source — were *found* by following arsenic). Gold itself only
counts when it was measured by a dedicated low-detection method (fire assay, neutron activation,
HBr-extraction AA, ICP-MS).

### The math behind the tiers

Every scored sample is a **stream-sediment** sample; its chemistry is compared against the other
samples in its **own watershed** (USGS HUC12, ~110 km²; rolled up to the parent HUC10 when a
HUC12 has under 10 samples) — *relative* anomaly, because 5 ppm arsenic means something different
in a quiet basin than in a mineralized belt:

1. **Anomaly (Signal 1):** each indicator element gets a within-watershed percentile.
   Below-detection results stay in the ranking (at the bottom) so percentiles are honest, and an
   element only counts where ≥25% of its watershed pool was actually detected. The sample's
   anomaly is its **best element percentile**.
2. **Pathfinder co-elevation (Signal 2):** a *different* indicator element in the same sample
   above the 75th percentile of detected values in its watershed — independent chemical
   confirmation, guarding against a single spurious assay.
3. **Historic producer (Signal 3):** a recorded USGS MRDS **producer** (an actual historic mine,
   not a mere occurrence) within 2 km — independent economic confirmation.

**Tiers (conservative by design — "worth checking" must be earned, like GREEN):**

| Tier | Requires | Marker |
|---|---|---|
| **High** (producer-anchored) | ≥ p90 anomaly + ≥1 co-elevated pathfinder + producer ≤ 2 km | filled star |
| **High** (chemistry-earned) | ≥ p97 anomaly + ≥2 co-elevated pathfinders (As required) — no producer needed; exists because historic records are incomplete | hollow star |
| **Moderate** | ≥ p75 anomaly + at least one other signal (pathfinder or producer) | small diamond |
| below | **hidden** — no marker at all, deliberately | — |

Co-located samples collapse to one marker showing the location's best tier. Every popup carries
the **upstream caveat**: a stream-sediment signal washed *down* from somewhere above the sample
point — it's a lead for exploring the drainage upstream, not a dig-here.

### Data sources

| Source | What it provides | Vintage / license |
|---|---|---|
| **USGS NGDB** (2026 consolidated release, DOI [10.5066/P1FXE9GK](https://doi.org/10.5066/P1FXE9GK)) | 1.5M geochemical samples (we score the ~320k 8-state stream sediments), As/Sb/Ag/Au determinations | samples 1962–2023 · CC0 |
| **USGS WBD** (national snapshot) | HUC12/HUC10 watershed polygons — the "regional background" unit | pinned snapshot date in `/meta` · public domain |
| **USGS MRDS** (already ingested for the gold-occurrence overlay) | historic producer locations for Signal 3 | static, pre-2011 · public domain |

The engine is **commodity-generic**: pathfinder sets, method filters, thresholds, and popup
wording live in [`config/prospectivity.json`](../config/prospectivity.json) — gold is simply the
first populated entry. Ingest runbook below; scoring details in `docs/planning/PROJECT_PLAN.md` §5.3 and
`docs/briefs/TIER_B_FABLE_BRIEF.md`.

### Runbook: (re)build the prospecting layer

```bash
./scripts/etl/pull_ngdb.sh          # NGDB parquet release (DOI-pinned, ~297 MB) -> staging
./scripts/etl/pull_wbd.sh           # national WBD GDB (~2.6 GB) -> staging (8-state HUC12/HUC10)
./scripts/etl/build_prospectivity.sh # config -> composite -> tiles.prospectivity (+ assertions)
./scripts/test/check_prospectivity_fixtures.sh   # golden-watershed regression gate
```

---

## Deferred / future enhancements

These are designed but **not built in the POC**, captured here so the intent isn't lost.

### Future: schedule the nightly claims refresh (production)

`scripts/etl/refresh_claims.sh` runs **manually** for now: it pulls ~488k claims into a new table
and atomically swaps it into `tiles.claims_polygons` (~7–8 min). **Step 1 (script hardening) below
is now implemented (2026-07-02, IMP-13);** making it a true unattended *nightly* job still needs
containerizing + a trigger (Steps 2–3). Scheduling is a **production concern** — there is
nothing to schedule against until a network-reachable Postgres exists (Azure Database for
PostgreSQL). The local dev DB (`localhost:5432`, Docker) is not reachable by a cloud runner, so
**don't wire a scheduler against local dev** — just run the script by hand there.

**Prerequisite:** the app deployed with a managed Postgres endpoint + the `tiles` schema and
`tileserv_ro` role provisioned (see §6.8/§6.11).

**Step 1 — harden the script — ✅ DONE (2026-07-02, IMP-13).** (Reusable across *any* scheduler;
this was the real work.) The bullets below are now implemented in `refresh_claims.sh`:
- **Decouple from Docker:** replace `docker compose exec -T postgres psql …` with a direct
  connection from an env var — `psql "$DATABASE_URL"` and ogr2ogr `PG:"$PGCONN"`. No `docker
  compose` in the job.
- **Atomic swap** so the live overlay never goes empty mid-refresh and a failed pull can't destroy
  good data. Load into a *new* table, create its indexes + `GRANT`, sanity-check the row count,
  then swap in one transaction:
  ```sql
  -- after loading tiles.claims_polygons_new (+ indexes + GRANT SELECT TO tileserv_ro):
  BEGIN;
    ALTER TABLE IF EXISTS tiles.claims_polygons RENAME TO claims_polygons_old;
    ALTER TABLE tiles.claims_polygons_new          RENAME TO claims_polygons;
  COMMIT;
  DROP TABLE IF EXISTS tiles.claims_polygons_old;
  ```
  If the pull/load fails, abort before the swap — yesterday's data stays live.
- **Sanity gate:** only swap if the new row count is within, say, ±25% of the previous load —
  guards against an upstream outage returning a near-empty set and silently blanking the overlay.
- **Concurrency guard:** `flock` (cron) or the scheduler's single-instance setting so two runs
  never overlap.
- **Exit non-zero on any failure** (pull error, zero rows, load error) so the trigger/alert sees it.

**Step 2 — containerize (the GDAL dependency).** The job needs `ogr2ogr` (GDAL) + `psql` +
`curl`/`python3`; build a small image so it runs anywhere (reused by every scheduler option):
```dockerfile
FROM ghcr.io/osgeo/gdal:alpine-small-latest
RUN apk add --no-cache postgresql-client curl python3 bash
COPY scripts/etl/refresh_claims.sh /app/refresh_claims.sh
ENTRYPOINT ["/app/refresh_claims.sh"]
```
Pass `DATABASE_URL` as a secret/env var.

**Step 3 — pick a trigger** (the only scheduler-specific, ~15-line piece):
- **Azure Container Apps Job — recommended for prod.** Scheduled (cron) job that scales to zero
  between runs, on a private network to the managed Postgres, decoupled from the web tier:
  `az containerapp job create --trigger-type Schedule --cron-expression "0 3 * * *"
  --image <ACR>/claims-refresh --secrets database-url=… --env-vars DATABASE_URL=secretref:database-url`.
- **GitHub Actions scheduled workflow — simplest / interim.** Keeps the schedule in the repo and is
  the natural place to build+push the image to ACR. `on: schedule: [{ cron: "0 3 * * *" }]`, run
  the container, connect to Azure PG over SSL (firewall-allow the runner, or use a self-hosted
  runner on the private network).
- **cron / launchd** — only if you already run an always-on host with GDAL + DB access; no built-in
  retries/alerting and it won't fire on a sleeping machine. Not recommended for PaaS hosting.

**Step 4 — observability & alerting (a *silently stale* claims layer is a safety issue).**
- Log row count + duration each run; the script already stamps `public.meta.claims_as_of`.
- **Alert on:** (a) job failure, and (b) **freshness** — `claims_as_of` older than ~2 days means
  the anti-claim-jumping overlay is stale. Surface the vintage in the UI (`/meta.claimsAsOf`) and
  page someone if it goes stale.

**Cadence:** nightly (~3am). The source updates near-daily (`Modified` was yesterday), so daily
captures it. docs/planning/PROJECT_PLAN.md §6.6.2.

### Pin export: GPX + KML

Pins export as **GPX** (Gaia, handheld GPS) or **KML** (Google Earth) via
`GET /api/v1/pins/{id}/export?format=gpx|kml` (default `gpx`); the "My Pins" list has a button for
each. KML emits a `<Placemark>` with the pin's name/description/coordinates. The Google Maps / Gaia
deep-links (plan §6.9) additionally cover "open in app."

### Future: production-grade private-land validation

The POC ships with a deliberately lightweight private-coverage check (plan §6.4.1): ~50–100
hand-picked points, **zero-tolerance on false-GREEN**. That is enough to trust the layer for a
single expert user, but it is **not** sufficient evidence to put OreScout in front of the public —
a hand-picked sample can't quantify the *rate* of missed private inholdings across the whole
8-state region, and trespass risk scales with users. **Before any production / public release**,
run the rigorous version below.

**Goal.** Move from "we didn't find a false-GREEN in our spot-check" to a *quantified, regionwide*
false-GREEN rate and `UNKNOWN`-coverage rate with known confidence — and a defensible decision on
whether authoritative parcel data is required.

**Method.**

1. **Authoritative ground truth.** Acquire parcel ownership data for the 8 states — county/state
   parcel layers or a commercial aggregator (e.g. Regrid/Loveland). This is the same parcel data
   that would feed the remediation ladder, so the effort does double duty.
2. **Systematic sample, not hand-picked.** Draw a large randomized sample (e.g. 1,000+ points)
   of *known-private* parcels that fall inside or adjacent to BLM/USFS land — the inholding case
   that matters — stratified across all 8 states and across parcel-size buckets (the small-inholding
   tail is where SMA generalization fails, plan §5.1).
3. **Run every point through the classifier** and tabulate RED / YELLOW-KNOWN / YELLOW-UNKNOWN /
   **GREEN**, broken down by state and parcel-size bucket.
4. **Metrics with confidence intervals:**
   - **False-GREEN rate** (private → GREEN) — the release-gating number; target effectively 0 with
     a tight upper confidence bound.
   - **`UNKNOWN` coverage rate** — how often private lands as no-data YELLOW (UX quality, and the
     signal for whether the orange overlay is worth building).
   - Where failures cluster (which states, which parcel sizes) → targeted remediation.
5. **Remediation ladder, driven by the numbers** (cheapest first): per-state detailed BLM SMA
   layers → county/state parcel layers → commercial parcel data. Climb only as far as the metrics
   demand.
6. **Lock it as a regression gate.** Once parcel data is in hand, fold a fixed subset into the
   automated test suite (alongside plan §6.4.2 Tier B) so future ETL runs can't silently regress
   private coverage.

**Why this is deferred, not skipped.** It depends on acquiring parcel data (cost + licensing +
per-county wrangling) that is overkill for a single-user POC but unavoidable for a public product
where a single false-GREEN could send a stranger onto private land. Treat it as a hard
prerequisite on the path to production, not an optional nicety.

### Future: orange "possibly-private" overlay (donut-hole detection)

**Problem.** A point with no land-management feature — a gap between PAD-US and SMA, most often a
small **private inholding inside otherwise-open federal land** (a "donut hole") — currently returns
a cautionary YELLOW (`ambiguityType: "UNKNOWN"`, see plan §4.1.1/§6.4) but renders as *clear* on
the map, because there is no polygon to style. So a possible-private inholding visually looks open
until you click it. This enhancement gives `UNKNOWN` its own map overlay so the map matches the
verdict.

**Visual.** Per the locked convention (plan §4.1: *solid = definitive, hatched = cautionary*), this
is an **orange cross-hatch**, never a solid fill. Orange reads as "closer to red than yellow" —
i.e. *lean stay-out, verify ownership* — which is the correct risk direction for possible-private
land. Distinct hatch angle/color from the grey known-ambiguous hatch so the two YELLOWs are
distinguishable on the map.

**Gating criteria (when to build it).** Only after the POC, and only if the **private-coverage
validation** (plan §6.4.1) shows no-data inholdings are *frequent enough to matter* — i.e. they
show up routinely during normal map browsing, not just in contrived spots. If inholdings are rare,
the assessment-panel `ambiguityType:UNKNOWN` message is sufficient and this overlay is not worth
the complexity. Decision is data-driven, not speculative.

**Implementation outline.**

1. **Compute the complement at ETL time** (after `tiles.legality_polygons` is built, plan §6.6.1):
   the "holes" are areas inside the 8-state boundary not covered by any legality polygon.
   Roughly: `ST_Difference(state_boundary, ST_Union(legality_polygons.geom))`, then split to
   individual hole polygons (`ST_Dump`).
2. **Filter to true inholdings to avoid false oranges.** A raw complement includes the region edge,
   water bodies, and genuinely-public-but-unmapped land — none of which should read as
   possibly-private. Keep a hole only if it is **enclosed by managed (BLM/USFS) land** — e.g. its
   boundary is substantially shared with BLM/USFS polygons, or it is an interior ring of dissolved
   managed land. Subtract water (NHD water bodies) and clip well inside the 8-state mask so the
   data-region edge never produces orange.
3. **Store** the result as `tiles.unknown_holes (geom, …)` in the `tiles` schema (so pg_tileserv
   serves it; plan §6.5/§6.8), with a spatial index. Optionally store an `enclosure_confidence`
   so styling can fade low-confidence holes.
4. **Style** in MapLibre as an orange cross-hatch fill (mirror the grey-hatch sprite approach in
   plan §6.7, different color/angle), as a toggleable layer with an appropriate `minzoom`.
5. **No assessment change needed** — a point in a hole already returns YELLOW + `UNKNOWN`; this
   step only makes the overlay agree with the verdict.
6. **Tune** against the §6.4.1 ground-truth set: measure the enclosure heuristic's false-positive
   rate (orange over land that's actually public) and false-negative rate (missed inholdings).

**Caveats.**
- Orange means **"unknown — verify ownership,"** *not* "confirmed private." The geometry heuristic
  cannot prove ownership; the panel/legend copy must say so.
- The complement computation is expensive on detailed geometry — run it once at ETL, never per
  request.
- Region-edge and water false positives are the main failure mode; the enclosure filter (step 2)
  is what keeps the overlay trustworthy.
