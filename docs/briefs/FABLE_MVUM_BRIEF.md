# Access & Trails Overlay (MVUM ingest + display) — Fable Build Brief

**For:** Claude Fable 5 · **Repo:** OreScout (build off `main`) · **Task type:** build (not review) ·
**Date:** 2026-07-14

This is a **goal + constraints + acceptance** brief, not a step-by-step script. You are the capable
builder — design the implementation. What's *locked* below is locked (owner's product calls);
everything technical inside those constraints is yours to decide. When a genuine product/UX ambiguity
appears that the locks don't cover, **ask the owner** — a short question beats a wrong rebuild.

> **Scope guardrail — this is the "(a) ingest + display" half of the access-routing feature, NOT the
> routing engine.** The research doc splits the feature into (a) ingest + display of MVUM/trail layers
> and (b) the drive/off-road/hike-in **routing engine** (pgRouting shortest-path). **(b) is explicitly
> out of scope here** — do not build routing topology, `pgr_*` calls, or shortest-path. This build
> produces a *reference display overlay* (styled lines + toggle + popup), exactly like the waterways
> and MRDS overlays. See *Explicitly out of scope* at the bottom.

## Mission
Build OreScout's **access & trails overlay**: a display-only map layer that shows the motorized/
non-motorized route network across the 8 states, colored by travel mode, so a user eyeballing a
prospect can see *"is there a road/trail to get near here, and would I drive in, need an off-road
rig, or hike in?"* It is a `reference`-role overlay that **never touches the legality verdict engine**
— same contract as `tiles.waterways`, `tiles.mrds`, `tiles.prospectivity`.

## Read first (ground yourself — don't re-derive what's settled)
- **`docs/research/DATA_SOURCE_INVESTIGATION_MVUM_TRAILS.md`** — this is your validated data foundation: source
  tables, endpoints, per-mode attribute names, the 8-state coverage matrix, license notes, the
  host-vs-live decision, and the open-questions/spikes list. Trust it; verify specifics as you load.
  Where this brief and that doc conflict, **the brief wins** (the doc predates the scope lock — e.g.
  it surveys state layers + OSM + routing topology that are all deferred here).
- **`docs/planning/PROJECT_PLAN.md` §6.13** (per-state source registry + the 🔒 invariant), **§5.x** (the
  data-source/overlay sections — your new overlay gets a new **§5.4**).
- **`etl/sources.json`** + **`etl/sources.schema.md`** — the registry is now a real JSON file (it did
  not exist when earlier overlays were built). Your new source is **one entry here**. Read by
  `scripts/etl/registry_lib.sh` via `jq`.
- **Your build templates already in the repo — mirror these, don't invent a new pattern:**
  - Waterways overlay: `scripts/etl/pull_nhdplus_hr.sh` (registry-aware per-HU4 streaming loader),
    `scripts/etl/build_waterways.sql` (staging→`tiles.waterways`, clip to `public.supported_region`
    via the `_region8` union, per-row `state_code` point-in-polygon), the master+sub-toggle UI in
    `web/src/store.ts` (`waterways` / `waterwaysPerennial` / `waterwaysIntermittent`), the styling in
    `web/src/map/style.ts`, and the headless proof `web/scripts/diag/diag_waterways.mjs`.
  - MRDS overlay: `scripts/etl/pull_mrds.sh`, `scripts/etl/build_mrds.sql`, `tiles.mrds`,
    `web/scripts/diag/diag_mrds.mjs` — the `reference`-role ETL→tiles→toggle→popup pattern.
- **`docs/ADD_A_STATE.md`** — the registry-driven ETL runbook conventions.

## Locked product decisions (non-negotiable — owner's calls, resolved 2026-07-14)
1. **v1 ingest = federal backbone only.** Four national sources, all public-domain, each a single
   ETL run clipped to the 8-state envelope:
   - **USFS MVUM Roads** (`EDW_MVUM_01/MapServer/1`) — per-vehicle-class open/closed.
   - **USFS MVUM Trails** (`EDW_MVUM_01/MapServer/2`) — motorized trails.
   - **USFS NFS Trails / `Trail_NFS_Publish`** (`EDW_TrailNFSPublish_01/MapServer/0`) — per-mode
     managed use (the non-motorized backbone).
   - **BLM GTLF** (`BLM_Natl_GTLF/MapServer/0`) — `PLAN_ASSET_CLASS` / `PLAN_MODE_TRNSPRT` /
     `OBSRVE_ROUTE_USE_CLASS`.

   **State trail layers, USGS NTD, NPS trails, and OSM are all DEFERRED** — not in this build. (OSM in
   particular is ODbL and needs counsel review; do not touch it.) The federal rows alone give full
   8-state coverage (research matrix: USFS ●● all 8, BLM GTLF ●● 7 / ● CA).
2. **Display classification = three travel-mode classes: `drive` / `off_road` / `hike_in`.** These
   preview the routing feature's own vocabulary. Per segment, classify to the **most-accessible**
   mode (see *Mode-enum spec* — precedence drive → off_road → hike_in). Not 2-way, not 4–5-way.
3. **Toggle = one "Access & trails" master + a per-class sub-toggle**, mirroring the waterways
   `perennial`/`intermittent` nesting you already shipped. Each class shows only when the master AND
   its sub-flag are on. (Owner's default sub-toggle states are yours to propose — mirror waterways:
   sub-flags default on, master default off.)
4. **Include roads, zoom-gated.** Ingest MVUM Roads + BLM GTLF road-class geometry (roads are the
   "drive in" backbone). Gate road density by zoom the way claims (z9) and waterways (z10) do — roads
   from a higher minzoom than trails so low zooms don't drown in forest-road spaghetti. Exact cutoffs
   tunable; propose and document them.

## The data (from the research doc — verify specifics as you load)
- **Access type:** prefer the **File-GDB `download`** for each federal source over `arcgis_rest`
  paging (paging millions of GTLF features at `maxRecordCount=2000` is slow and truncates silently if
  you forget pagination). The GDB is the right harvest for a full network. REST is the fallback.
- **Versioned download URLs** — the FSGeodata clearinghouse zip filenames are **versioned per refresh**
  (last MVUM refresh 2026-07-02). **Resolve the exact filename from the landing page at ETL time — do
  not hardcode it.** Landing pages:
  `https://data.fs.usda.gov/geodata/edw/datasets.php?dsetCategory=transportation` and
  `...?xmlKeyword=trails`. BLM GTLF bulk-GDB item lives on the BLM GeoSpatial Business Platform
  (`gbp-blm-egis`) — **its exact download-item URL is unverified in the research doc; locate it, or
  fall back to a one-time paged REST harvest of `BLM_Natl_GTLF/MapServer/0`.**
- **CRS:** USFS EDW REST reports **NAD83 / EPSG:4269** → reproject to **4326** on load (same
  `ST_Transform` discipline as WBD). Confirm the GDB's native SRID and reproject accordingly.
- **Coverage / clip:** national datasets; filter to the 8 states by **spatial clip to
  `public.supported_region`** (reuse the `_region8` union + per-row `state_code` point-in-polygon
  pattern from `build_waterways.sql`) — not by `forestname` string matching. Keep whole line
  features that intersect the region (mirror the waterways "keep whole lines that intersect" rule).
- **The routing attributes (per-mode signal, the point of the layer):**
  - MVUM Roads/Trails: ~15 per-vehicle-class open flags (`passengervehicle`, `highclearancevehicle`,
    `truck`, `fourwd_gt50inches`, `atv`, `motorcycle`, `e_bike_class1/2/3`, …), each paired with a
    `*_datesopen` free-text seasonal window; plus `operationalmaintlevel`, `surfacetype`.
  - NFS Trails: per-mode managed-use columns (`hiker_pedestrian`, `pack_saddle`, `bicycle`,
    `motorcycle`, `atv`, `fourwd`, `snowmobile`, `e_bike_*`) + `trail_class`, `trail_surface`.
  - BLM GTLF: `PLAN_ASSET_CLASS` (Road / Primitive Road / Trail), `PLAN_MODE_TRNSPRT`
    (Motorized / Non-Motorized / Non-Mechanized), `OBSRVE_ROUTE_USE_CLASS` (2WD Low, 4WD Low, ATV,
    Motorized Single Track), `PLAN_OHV_ROUTE_DSGNTN`, `OBSRVE_SRFCE_TYPE`.
- **License:** US-government work → public domain for all four; ingest + cache + display OK with
  "USDA Forest Service" / "BLM" attribution + no-warranty disclaimer. Verify the exact USFS
  use-constraint string on the clearinghouse metadata before you consider it shipped (research
  open-question — flag if it's anything other than public domain).
- **Authority-lag disclaimer (required):** feature data is "designed to be consistent with" the
  legally authoritative per-forest **MVUM PDF**, refreshed unit-by-unit → short lag possible. Every
  popup must carry a "confirm against the official MVUM before you go" line (a normal popup line, not
  a banner — mirror the MRDS "historic record" note tone).

## The build (the WHAT — you design the HOW)
1. **Ingest** the four federal sources into `staging.*` (mirror `scripts/etl/pull_nhdplus_hr.sh`:
   registry-aware — read access params from `etl/sources.json`, no hardcoded URLs/fields in the
   script body). Stream/`-append` into PostGIS; record source vintage/snapshot for provenance.
2. **Build** a `tiles.access` table (drop-and-rebuild SQL like `build_waterways.sql`): union the four
   staged sources, compute the unified **`travel_mode`** enum (*Mode-enum spec* below), clip to
   `public.supported_region`, stamp `state_nm`/`state_code` per row, keep provenance columns.
3. **Serve** `tiles.access` via pg_tileserv as a new **`reference`-role registry entry** in
   `etl/sources.json` (one entry — the 🔒 §6.13 invariant). `serve.table = "tiles.access"`,
   `geom = "MultiLineString"`.
4. **Frontend** — a master "Access & trails" toggle + three sub-toggles (Drive / Off-road / Hike-in)
   in `web/src/store.ts` + the left panel, mirroring the waterways nesting; styled line layers in
   `web/src/map/style.ts` (three visually distinct classes, roads zoom-gated per lock #4); a
   click-popup showing the route name (`GNIS_Name`/trail name), travel mode, surface, the seasonal
   `*_datesopen` window as advisory free text, source agency, and the MVUM-authority disclaimer line.
   Reuse the waterways hover/click affordance.
5. **Uphold the invariant** — the assessment engine, legality tiles, and the verdict path are
   **untouched**. This layer is absent from the assessment pipeline; it can never change a
   RED/YELLOW/GREEN verdict.

## Mode-enum spec (defaults — technical, adjustable; document any deviation)
Unify the three source vocabularies into a single **`travel_mode ∈ {drive, off_road, hike_in}`**,
one value per served segment = its **most-accessible** mode:
- **`drive`** — open to standard/passenger highway vehicles. USFS: `passengervehicle` open (or
  `operationalmaintlevel` ≥ passenger-car grade). BLM: `OBSRVE_ROUTE_USE_CLASS` = '2WD Low' (or
  `PLAN_ASSET_CLASS` = Road with 2WD use).
- **`off_road`** — motorized but requires high-clearance / 4WD / ATV / OHV / motorcycle (i.e.
  motorized but **not** passenger-open). USFS: any of `highclearancevehicle`/`fourwd_gt50inches`/
  `atv`/`motorcycle` open while `passengervehicle` is not. BLM: '4WD Low' / 'ATV' / 'Motorized
  Single Track', or `PLAN_MODE_TRNSPRT` = Motorized on a Primitive Road / Trail.
- **`hike_in`** — non-motorized only. NFS Trails with motorized columns all closed (foot/pack/bike).
  BLM: `PLAN_MODE_TRNSPRT` = Non-Motorized / Non-Mechanized.
- **Precedence** (a segment open to several modes takes the most-accessible): `drive` → `off_road` →
  `hike_in`. Keep the raw source classification columns on the row for the popup/debugging; the
  served `travel_mode` is the derived display bucket. **This precedence + the exact column→bucket
  mapping is yours to finalize against the real data — document the mapping you ship.**
- **Seasonal windows are advisory only in v1.** `*_datesopen` is free-text (date ranges / "yearlong")
  — carry the string to the popup; **do not** parse it into structured open/closed or style by
  season. (Normalization is a routing-engine concern, deferred.)
- **Unclassifiable segments:** if a segment's mode can't be derived (all mode fields null), decide
  whether to drop it or bucket it conservatively — and **say which** in the ETL log (no silent caps).

## Registry entry (the §6.13 shape — one entry, mirror `nhdplus_hr_waterways`)
Add a `reference`-role source keyed `access` (or similar) with: `states` (all 8), `access` block
(`type: download`, the resolved landing/GDB URLs, `loader`, `layer`(s), `fields`, and whatever
per-source list the loader iterates), `serve: { table: "tiles.access", geom: "MultiLineString" }`,
`license`, `attribution`, `vintage` (USFS MVUM refresh date + BLM GTLF snapshot — dev ingest; note
any prod upgrade path the way the waterways entry notes NR2), `upstream_ref`, `max_age_days`. Follow
`etl/sources.schema.md`.

## Frontend specifics (mirror waterways)
- `store.ts`: extend the `layers` object with `access` (master) + `accessDrive` / `accessOffRoad` /
  `accessHikeIn` sub-flags; extend `toggleLayer`'s key union; default the master off, sub-flags on
  (waterways parity).
- `map/style.ts`: three line layers filtered on `travel_mode`, visually distinct (propose the
  palette — motorized vs non-motorized should read at a glance; don't collide with the blue waterways
  or the claims/legality colors). Roads zoom-gated per lock #4. Legend labels all three classes.
- Popup: name · travel mode · surface · seasonal window (advisory) · source agency · MVUM-authority
  disclaimer line.

## Invariants — do NOT "fix" or cross these
- The overlay never feeds or alters the legality verdict (it's `reference`-role, absent from the
  assessment pipeline).
- Adding this source is **one `etl/sources.json` entry** — do not special-case it in the engine,
  the legality tiles, or the verdict path.
- No OSM, no state layers, no routing topology in this build (deferred/legal).
- No silent caps/sampling — every filter (region clip, unclassifiable-segment handling, any density
  cap) is logged with kept/dropped counts.
- Don't overstate authority — the MVUM PDF is the legal source; the disclaimer line is mandatory.

## Boundaries & permission gates
This feature is **green-lane by nature** — additive, `reference`-only, never touches the verdict
engine — so **build it autonomously on a branch.** **Merge to `main` is the review checkpoint** (open
a branch; the owner reviews before merge). **Red lines — stop and ask:** anything that would touch the
legality/verdict engine, the `legality_polygons` / legality-tile schema, auth, OSM ingestion, or
destructive ops. This overlay should need *none* of these; if you believe it does, you've found a
design problem — surface it, don't route around it.

## Risks & pre-flight checks (know these going in)
- **Ingest volume + memory:** USFS Roads GDB ≈113 MB + Trails ≈35 MB + NFS Trails ≈118 MB + national
  GTLF (large). The dev Postgres container has **OOM-killed a whole-region geometry job before** —
  batch heavy steps (per source, or per state) rather than one monolithic statement; expect minutes,
  not seconds. Check Docker free disk before pulling GTLF national.
- **Tile weight:** a dense road+trail line layer can recreate the low-zoom tile-timeout problem the
  legality layer hit. The zoom gates (roads especially) are the mitigation — verify with a
  size/latency check and budget **< 500 KB per tile** at each layer's minzoom.
- **Versioned URLs / unverified BLM item:** resolve USFS zip filenames at ETL time; the BLM GTLF
  bulk-GDB download-item URL is unverified — locate it or fall back to paged REST (pagination
  mandatory, `maxRecordCount=2000`).
- **Attribute quality (the research doc's spike #1):** NV is BLM-heavy with no state layer, so it
  stress-tests the federal backbone. As you load, eyeball that the per-vehicle-class / GTLF mode
  fields are actually populated (not mostly null) before trusting the `travel_mode` derivation — if
  they're sparse, flag it rather than shipping an empty enum.

## Acceptance criteria (prove it works)
- Data ingested + `tiles.access` built; a **headless diag** (model it on `web/scripts/diag/diag_waterways.mjs`)
  proving:
  - the master toggle renders lines; each sub-toggle (Drive / Off-road / Hike-in) independently
    shows/hides its class; roads appear only at/after their gated minzoom.
  - a click-popup shows name + travel mode + surface + seasonal advisory + agency + the MVUM
    disclaimer line, over a known motorized area (e.g. a Humboldt-Toiyabe NF / NV BLM viewport) and a
    non-motorized trail viewport.
  - **the legality engine is untouched:** Tier-A and Tier-B fixture suites still green; the
    `/assessment` response at a coordinate is **byte-identical** with the layer on vs off; the
    pg_tileserv catalog gains **only** the new `tiles.access` layer.
- **Reality check on real data:** a **source × travel_mode count table** (rows per USFS-Roads /
  USFS-Trails / NFS-Trails / GTLF × drive/off_road/hike_in) — the mix must be sane (NFS Trails
  skew hike_in; MVUM Roads skew drive/off_road; GTLF spread), not a single-bucket smear. If one
  bucket swallows everything, the mode mapping is wrong — investigate before shipping.
- **ETL transparency:** kept/dropped counts for the region clip and for unclassifiable segments;
  the resolved download URLs + vintages recorded.

## Deliverables & working style
- The working overlay on a branch, merge-ready.
- **Docs to the project's conventions:** a decision-log entry in `docs/planning/PROJECT_PLAN.md` §9 (**next free
  number — verify at write time; #45 is the current highest, so likely #46**), a new **§5.4** for the
  access & trails overlay, the `etl/sources.json` entry, a `docs/planning/BACKLOG.md` update (mark the
  MVUM/access-routing item as ingest+display done, routing engine still open), and a note in
  `docs/research/DATA_SOURCE_INVESTIGATION_MVUM_TRAILS.md` recording what you actually ingested (sources, vintages,
  counts, the `travel_mode` mapping you shipped, and any surprises — esp. the NV attribute-quality
  read).
- A regression diag (`web/scripts/diag/diag_access.mjs` or similar) + the source×mode reality table.
- **Report honestly:** what's verified vs assumed (the USFS license string and the BLM GTLF GDB URL
  are the two flagged unknowns), any data surprises, what you deferred and why.

## Explicitly out of scope (do NOT build these — they are the next phase)
- **The routing engine** (feature half (b)): pgRouting topology (`pgr_createTopology`/
  `pgr_nodeNetwork`), shortest-path, road→trailhead→trail connectivity, the drive/off-road/hike-in
  *route computation*. This build only *displays* the classified network.
- **Seasonal parsing** of `*_datesopen` into structured open/closed windows (routing concern).
- **State trail layers, USGS NTD, NPS trails** (deferred density fillers).
- **OSM ingestion** (ODbL — needs counsel review; segregated-table pattern is a later decision).
- **Recreation.gov RIDB** trailhead/permit enrichment (live-call enrichment, not this layer).
- The research doc's **spikes #4 (OSM overlap) and #5 (routing-topology PoC)** — skip entirely.
  Spikes #1–#3 (attribute quality, `*_datesopen` formats, endpoint verification) happen *naturally*
  as you ingest here — fold their findings into the docs note; don't run them as separate throwaways.

## Clarifying-questions protocol
The four product calls above were **asked and answered by the owner 2026-07-14** (v1 = federal
backbone, 3-class drive/off-road/hike-in, master+sub-toggles, roads zoom-gated) — build to them,
don't re-ask. The protocol still stands for anything new: ask the owner before deciding any
**product/UX call the locks don't cover** — e.g. if the real data makes the 3-way mode split produce
a bad/empty map, or a popup needs wording not specified here, or roads are so dense that the zoom
gate isn't enough. Batch questions. Everything **technical inside the locked design** (schema, SQL,
tile config, ingest mechanics, the exact column→bucket mapping, palette, zoom cutoffs) is yours.
