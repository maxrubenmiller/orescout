# OreScout

A decision-support tool for amateur miners, prospectors, and rockhounds that answers one
question: **"Can I legally collect rocks / pan for gold / prospect *here*?"** — backed by public
land-management and mining-claim data, shown on a map with color-coded legality overlays.

> **Source of truth:** the full engineering plan lives in [`PROJECT_PLAN.md`](PROJECT_PLAN.md)
> (vision, scope, data sources, architecture, rules engine, schema, ETL, decisions log). This
> README covers getting started and **deferred / future enhancements** that are intentionally out
> of scope for the POC.

## Status

**Phase 1 backend skeleton is up and verified** (data-independent parts). Done:
- Docker Postgres+PostGIS (+ pg_tileserv), schemas/role/meta/`supported_region` via `db/01_init.sql`.
- **Half-1 rules-engine classifier** (`db/02_classifier.sql`) — **Tier-A fixtures 15/15 green**.
- ASP.NET Core API (`src/OreScout.Api`): `health`, `meta`, `geocode` (live Nominatim proxy),
  `assessment` (Stage-0 gate + honest `dataGaps` until the ETL runs), `pins` CRUD + GPX export,
  `X-Api-Key` auth, CORS. EF Core migration created the `pins` table (geom column, GIST/GIN
  indexes, updated_at trigger). All endpoints smoke-tested end-to-end.

**ETL — all 8 states loaded** (the Half-2 spatial unify, real data):
- Pulled **74,870 real PAD-US features** across NV/CA/AZ/CO/UT/NM/OR/ID from the Phase-0-verified
  live FeatureServer (`scripts/etl/pull_states_padus.sh`), loaded to `staging.padus_staging`.
- §6.6.1.1 inspection **at scale** confirmed the classifier domains across all 8 states and added 9
  manager codes that appear in CA/CO/OR but not NV (`RWD/JNT/UNK/OTHF/BOEM/ARS/NOAA/BPA/OTHR` →
  YELLOW). Result: **0** features with an unmapped verdict. Tier-A fixtures 20/20.
- `scripts/etl/unify.sql` bakes the verdict into `tiles.legality_polygons` (`ST_MakeValid` repairs
  invalid rings). Result: **12,469 RED / 58,994 YELLOW / 3,407 GREEN** polygons.
- Verified end-to-end: every NP (Yosemite/Grand Canyon/Rocky Mtn/Zion/Crater Lake/Carlsbad) → RED,
  Sawtooth Wilderness (ID) → RED, open BLM → GREEN, downtown Denver → no-data UNKNOWN (private).
  Overlays render across all states (tile bounds now span the full 8-state region).
- *Source is the live PAD-US v3.0 layer; data-currency upgrade to PAD-US 4.2 is a documented
  follow-up (TODO.md / ScienceBase item 65294599d34e44db0e2ed7cf).*

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

**Still to do (data/integration):** SMA cross-check (the slice used PAD-US `Mang_Name` alone);
the **v4 download + all-8-states** run (re-confirm literals). Then: the web frontend (plan §6.12),
which can now render the overlay tiles and call the fully-working assessment API.

### Reproduce the NV slice
```bash
docker compose up -d postgres
./scripts/etl/pull_nv_padus.sh data/nv                              # pull real PAD-US (NV)
PG="PG:host=localhost port=5432 dbname=miningapp user=postgres password=postgres"
ogr2ogr -f PostgreSQL "$PG" data/nv/padus_0.geojson -nln staging.padus_staging \
  -nlt PROMOTE_TO_MULTI -lco GEOMETRY_NAME=geom -t_srs EPSG:4326 -overwrite
for p in 1 2; do ogr2ogr -f PostgreSQL "$PG" data/nv/padus_${p}.geojson \
  -nln staging.padus_staging -nlt PROMOTE_TO_MULTI -append; done
docker compose exec -T postgres psql -U postgres -d miningapp -f /dev/stdin < scripts/etl/unify.sql
```

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

# 4. Run the API  (http://localhost:5000)
dotnet run --project src/OreScout.Api

# Smoke test (default dev key in appsettings.json):
curl localhost:5000/api/v1/health
curl -H "X-Api-Key: dev-local-key-change-me" "localhost:5000/api/v1/assessment?lat=39.5&lng=-117.0"
```

Tile server (optional until overlays exist): `docker compose up -d pg_tileserv`. Full bootstrap
order and the production path are in [`PROJECT_PLAN.md`](PROJECT_PLAN.md) §6.8 / §6.11.

---

## Deferred / future enhancements

These are designed but **not built in the POC**, captured here so the intent isn't lost.

### Future: KML export (Google Earth)

The POC exports pins as **GPX only** (`GET /api/v1/pins/{id}/export?format=gpx`) — GPX covers Gaia
and handheld GPS units, and the Google Maps / Gaia deep-links (plan §6.9) cover "open in app." The
export endpoint already takes a `format` param, so KML is an additive change, not a redesign: add a
`kml` branch that emits a `<Placemark>` with the pin's name/description/coordinates, and list KML
in the §4.2 export options. Worth doing when Google Earth handoff is requested.

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
