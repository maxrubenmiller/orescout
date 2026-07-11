# Tier B — Prospecting-Potential Composite: Fable Build Brief

**For:** Claude Fable 5 · **Repo:** OreScout (build off `main`) · **Task type:** build (not review) ·
**Date:** 2026-07-10

This is a **goal + constraints + acceptance** brief, not a step-by-step script. You are the capable
builder — design the implementation. What's *locked* below is locked (owner's product calls);
everything technical inside those constraints is yours to decide. When a genuine product/UX ambiguity
appears that the locked decisions don't cover, **ask the owner** — a short question beats a wrong rebuild.

> **Revision note — Fable review pass (2026-07-10).** Edited per the owner's improve-the-brief
> instruction; the four locked decisions are untouched (one has a flagged *note*, not a change).
> What changed and why:
> 1. **Four product calls the locks didn't cover are now resolved** (owner answered 2026-07-10):
>    marker granularity/zoom, Tier-B vs MRDS visual identity, sample media, upstream-note wording
>    — see *Owner-resolved product calls*.
> 2. **Added a default scoring spec** — the old brief said "top ~10%" without defining *of what*;
>    with Au censored, the anomaly variable, co-elevation, and censored-percentile math needed
>    pinning to be buildable (and to avoid double-counting one element as both anomaly and
>    pathfinder). Marked as defaults, adjustable within the locked tier framework.
> 3. **Corrected two over/mis-specifications:** closed-basin `tohuc` "handling" (the v1 composite
>    does no flow-routing — only load-tolerance is needed); and §5.3's `/api/prospecting` endpoint
>    (superseded: tiles-only, like MRDS). The docs deliverable now includes updating §5.3.
> 4. **Closed spec gaps:** tbl_chem must be filtered at ingest (a *stated* bound, ~59M rows
>    national); WBD HU2 region-list completeness must be asserted (the spike's "10, 13–18" list
>    likely misses region 11 for eastern CO/NM); Signal-3's "generic over commodity" claim was
>    overstated — the MRDS producer anchor is gold-filtered today, so commodity #2 needs a data
>    pull too, and the acceptance criterion now says so honestly.
> 5. **Tightened acceptance** into falsifiable checks (hide-below-Moderate control area, golden
>    HUC fixtures, state×tier distribution table, tile-size budget, catalog diff) and added a
>    Risks section with verified facts (GDAL 3.13.1 on this machine reads Parquet natively —
>    checked, not assumed) plus the dev-container OOM lesson for big PostGIS jobs.

## Mission
Build OreScout's **prospecting-potential overlay** (`PROJECT_PLAN.md` §5.3): a map layer that answers
*"where is it genuinely worth checking for gold?"* from USGS geochemistry. The whole point is to
surface **where it's worth looking — not where gold atoms happen to exist** (trace gold is
everywhere). It is a display-only overlay that **never touches the legality verdict engine**.

## Read first (ground yourself — don't re-derive what's settled)
- `PROJECT_PLAN.md` **§5.3** (the composite design: the three signals, tier output, upstream caveat,
  the precomputed-static approach), **§6.13** (per-state source registry + the invariant guarantee),
  **§6.4.1** (Confirm-Open ethos — "must be earned").
  ⚠ *Where §5.3 and this brief conflict, the brief wins* — §5.3 predates the spike and the scope
  lock. Known superseded details: Hg as a gold pathfinder (sparse in NGDB → As/Sb/Ag per #41), the
  3-tier display incl. an opt-in "Low/Trace" toggle (locked to 2 tiers, rest hidden), Au-led scoring
  (Au is censored → pathfinder-led), and the `/api/prospecting?bbox` endpoint (superseded — see
  *Architecture clarifications*). Updating §5.3 is part of your docs deliverable.
- `DATA_SOURCE_INVESTIGATION.md` → **"Prospecting-potential research — NGDB & WBD spike"**. This is
  your validated data foundation — access URLs, formats, exact field names, coverage, and the
  gotchas. Trust it; verify specifics as you actually load.
- `BACKLOG.md` → Prospecting Intelligence.
- **Your build templates already in the repo:** the MRDS gold overlay (`scripts/etl/pull_mrds.sh`,
  `scripts/etl/build_mrds.sql`, `tiles.mrds`, `web/diag_mrds.mjs`) and the waterways overlay — same
  `reference`-role, ETL→tiles→toggle→popup pattern you'll follow. Mirror the tolerance-box hover/click.

## Locked product decisions (non-negotiable — the owner's calls)
1. **Conservative, two tiers.** Surface only **High Potential** (strong anomaly — top ~10% within
   its watershed — *and* ≥1 co-elevated pathfinder *and* near a historic producer) and **Moderate**
   (above regional background + at least one other signal). **Hide everything below** — no "trace"
   tier. "Worth checking" must be *earned* (mirror "GREEN must be earned").
2. **Upstream caveat = standard note.** Every marker's popup includes a line that the gold source is
   *upstream* of the sample point (explore the drainage above), as a normal popup line — **not** a
   prominent banner. (Prominence is a Pass-B / legal call; don't escalate it yourself, but don't
   omit the note either.)
3. **Multi-commodity foundation, gold first.** Architect the composite **generic over commodity** —
   pathfinder sets + thresholds live in **config/data, not hard-coded** (the §6.13 registry
   philosophy: adding a commodity later = a config entry, not new code). **Populate GOLD as commodity
   #1** in this build; other commodities are a later config add, *not* part of this deliverable.
4. **Reference-role, zero engine impact.** The overlay serves its own `tiles.<key>` table and is
   **absent from the assessment pipeline** — it can never change a RED/YELLOW/GREEN verdict.

> **Fable notes on the locks (flags, not changes):**
> - *Decision #1 makes High structurally unreachable in watersheds with no recorded MRDS producer* —
>   even a screaming multi-pathfinder anomaly caps at Moderate where USGS never recorded a producer
>   (MRDS is pre-2011 and incomplete in under-documented districts). That is the conservative intent
>   ("earned"), so the build honors it — but it's worth knowing the High tier inherits MRDS's blind
>   spots. If that ever feels wrong on the map, the fix is a product decision, not a build tweak.
> - *Interpretation pinned to avoid double-counting:* "≥1 **co-elevated** pathfinder" is read as a
>   **second, different element** than the one carrying the anomaly percentile (an As anomaly can't
>   count itself as its own pathfinder). Veto if you meant otherwise — the scoring spec below builds
>   on this reading.

## Owner-resolved product calls (asked & answered 2026-07-10 — build to these)
1. **Marker granularity & zoom:** markers are **site-deduped** — one marker per sample location
   showing the location's **best** tier (co-located/duplicate samples collapse; keep `n_samples` as
   a property). **Zoom-gated:** High visible from **z≈7**, Moderate from **z≈10** (exact cutoffs
   tunable; mirror how claims z9 / waterways z10 gate density).
2. **Visual identity:** Tier B gets its **own glyph family, distinct from the MRDS gold dots** —
   star-like symbol for High, small diamond for Moderate, in a hotter hue (orange-red family);
   **MRDS styling unchanged**; the layer panel/legend labels both layers so computed-score vs
   historic-record stays legible. (MapLibre note: circles are paint-only; star/diamond glyphs need
   a symbol layer with an injected image — reuse the runtime-injected-sprite pattern from the hatch,
   *including its fail-safe lesson: give symbol layers a visible fallback* — see review finding F-5.)
3. **Sample media:** the v1 composite scores **stream-sediment samples only** (`primary_class`
   sediment) — one medium, one background distribution, and every marker honestly supports the
   upstream note. Other media may be ingested but are **unscored** in v1; say so in the docs.
4. **Upstream note (exact string, locked-#2 wording resolved):**
   *"Signal detected in this drainage — the source may be anywhere upstream of this point. Explore
   the drainage above; this is a lead, not a dig-here."*
   (Commodity-neutral by design; one string serves gold and any later commodity.)

## The data (validated in the spike — detail in `DATA_SOURCE_INVESTIGATION.md`)
- **NGDB** — the 2026 consolidated release (CC0, DOI `10.5066/P1FXE9GK`, **Parquet ≈283 MB**).
  Download-and-host. Long/tidy: `tbl_geol` (site: `latitude`/`longitude`, `state`, `primary_class`
  medium) + `tbl_chem` (elements as ROWS: `species`, `qualified_value`, `units`, `analytic_method`,
  `qualifier`).
- **WBD** — HUC12 (`hydro.nationalmap.gov/.../wbd/FeatureServer/6`, or the national / western-HU2
  GDB). Public domain. Ships EPSG:4269 → `ST_Transform` to 4326.
- **MRDS** — already ingested (`tiles.mrds`, with an `is_producer` flag) → your Signal-3 anchor.
- **⚠ The load-bearing constraint — Au is mostly below-detection** in NGDB's standard ICP assays.
  **Lead the score with pathfinder elements (As/Sb/Ag);** use Au only from the INAA/fire-assay subset
  (filter `analytic_method`). **Do not** present raw Au concentration as "gold here." Honor the other
  spike gotchas: below-detection is a **negative value** → keep it left-censored (not zero);
  normalize each sample to EPSG:4326 by its own `DATUM` before the HUC join; **ignore NGDB's own crude
  HUC codes** (do a fresh PostGIS `ST_Contains` join).
- **Closed-basin `tohuc` sinks — corrected scope:** the v1 composite does **no flow-routing** — a
  sample is grouped by the HUC12 that *contains* it, full stop, and the upstream note is static
  text. So `tohuc` text sinks (`OCEAN`, `CLOSED BASIN`, …) only need to be *tolerated at load*
  (don't type the column as a HUC code / don't crash); keep the column for the later
  waterway-intelligence work (`BACKLOG.md`), but nothing in this build routes through it.

## The build (the WHAT — you design the HOW)
1. **Ingest** NGDB (Parquet) + WBD (HUC12+HUC10) into PostGIS, download-and-host (mirror
   `scripts/etl/` patterns). Record source vintage/snapshot for honest provenance. Requirements in
   *Ingest & data-handling* below.
2. **Compute the composite once at ingest** (a precomputed static layer per §5.3), **generic over
   commodity** — Signal 1 relative anomaly per HUC12, Signal 2 pathfinder co-elevation, Signal 3
   MRDS-producer proximity → the conservative **2-tier** output. The precise default semantics are
   pinned in *Scoring spec* below (defaults, tunable within the locked tiers).
3. **Serve** it as a `tiles.<key>` table via pg_tileserv, a new `reference`-role registry entry
   (§6.13 — concretely: the same documentation-row convention the MRDS overlay used; there is no
   `sources.json` file yet), keyed so **gold is the first populated commodity**.
4. **Frontend** — a "Prospecting potential (gold)" toggle (placed with the other prospecting layers)
   + tiered markers per the *owner-resolved* glyph/zoom decisions + a click-popup showing tier,
   the anomaly element + its watershed percentile, pathfinders present, nearest MRDS producer
   (name + distance), the standard upstream note (exact string above), and a data-vintage line
   (mirror the MRDS "historic record" note pattern). Reuse the MRDS overlay's hover-highlight +
   tolerance-box click.
5. **Uphold the invariant** — the assessment engine, legality tiles, and the verdict path are
   untouched by any of this.

## Scoring spec (defaults — technical, adjustable within the locked tiers; document any deviation)
- **Per-commodity config** (the generic core; gold ships as entry #1): `indicator_elements`
  (gold: `As, Sb, Ag, Au`), per-element method filters (`Au` → INAA/fire-assay only),
  `producer_filter` (which MRDS sites anchor Signal 3; gold: `tiles.mrds.is_producer`),
  `proximity_m` (default 2,000), tier thresholds. Config lives in data/config, not code.
- **Anomaly percentile (Signal 1):** for each scored sample, compute its within-watershed
  percentile **per indicator element**, against that element's background in the containing HUC12
  (sediment samples only, per the owner call). The sample's **anomaly score = its max percentile
  across indicator elements**; the element achieving it is the reported "anomaly element".
- **Censoring (the statistics must not lie):** left-censored values (negative `qualified_value`)
  rank **below all detected values** of that element in that watershed and stay in the percentile
  denominator. A "top ~10%" claim over a pool that is >90% censored is meaningless — require a
  **minimum detected fraction** (default: ≥25% detected for that element in that background pool)
  for an element to carry an anomaly; otherwise that element contributes nothing there.
- **Method heterogeneity guard:** 25 labs / 108 methods mean detection limits differ wildly; a
  high-DL method must not fake an "elevated" rank. Default guard: compute percentiles on detected
  values only + censored-below rule above; if the reality check shows method artifacts (e.g. a
  High cluster tracking a lab boundary, not geology), tighten to per-method background pools and
  say so. Document whichever guard ships.
- **Co-elevated pathfinder (Signal 2):** a **different** indicator element than the anomaly
  element, above its own watershed **p75** (detected values only).
- **Producer proximity (Signal 3):** any commodity-matching MRDS producer within `proximity_m`
  of the sample point.
- **Tiers (locked shape, default cutoffs):** **High** = anomaly ≥ **p90** + ≥1 co-elevated
  pathfinder + producer within 2 km. **Moderate** = anomaly ≥ **p75** ("above regional background",
  §5.3's *Anomalous*) + at least one other signal (co-elevated pathfinder **or** producer
  proximity). Everything else: no row in the served table (hidden ≠ styled-invisible).
- **Thin watersheds:** HUC12 with < **10** scored samples for the element → use its HUC10
  background; HUC10 also < 10 → that element is unscored there (conservative: hide, don't
  fabricate). Report how many samples/watersheds each rule affected.
- **Site dedupe (owner call #1):** collapse co-located samples (same rounded location, default
  ~4 decimals ≈ 11 m) to one served marker carrying the best tier + `n_samples`.

## Ingest & data-handling requirements
- **NGDB volume — filter at load, and say so** (the no-silent-caps invariant allows *stated*
  bounds): `tbl_chem` is ~59M rows national. Keep only rows for the union of configured
  indicator elements, joined to `tbl_geol` sites within the 8 states. Record kept/dropped counts
  in the ingest log + docs. Parquet reads directly via GDAL/ogr2ogr (**verified: GDAL 3.13.1 on
  this machine has the Parquet driver**; the 621 MB GeoPackage is the fallback if the driver
  misbehaves — either way, DOI-pinned download, no live dependency; `mrdata.usgs.gov` was 502-ing
  during the spike).
- **Datum normalization before the HUC join** (mixed NAD27/WGS84 per record — a NAD27 shift can
  cross a HUC12 boundary), then a fresh `ST_Contains` sample→HUC12 join (never NGDB's own HUC codes).
- **WBD completeness assertion (new):** after loading, **assert every in-region scored sample
  lands in exactly one HUC12**. The spike's HU2 region list ("10, 13–18") looks incomplete —
  **eastern CO/NM drain to region 11** (Arkansas–White–Red / Canadian) — so a nonzero unmatched
  count means fetch the missing region(s), not drop the samples. Simplest safe route: the national
  GDB (2.59 GB) if disk allows.
- **WBD snapshot discipline:** pin one dated snapshot, record its date in `data_vintage`; HUC codes
  are **not stable across snapshots** — never use them as a cross-version key.
- **Idempotency + provenance:** drop-and-rebuild build script(s) like `build_mrds.sql`; every
  served row carries `source_key` + `data_vintage` (NGDB DOI + release date; WBD snapshot date).

## Architecture clarifications
- **Tiles-only — no new API endpoint.** §5.3's `/api/prospecting?bbox` idea is superseded: the
  popup reads feature properties from the vector tile, exactly like MRDS. (One less surface, no
  engine adjacency, CDN-cacheable.) Update §5.3 accordingly.
- **Tile feature properties (keep lean — tiles carry every property to every client):** `tier`,
  `commodity`, `anomaly_element`, `anomaly_pctl`, `pathfinders` (compact, e.g. "Sb,Ag"),
  `producer_name`, `producer_dist_m`, `huc12`, `n_samples`, `data_vintage`. Nothing else without
  a reason.
- **Signal-3 generality is data-limited — be honest about it:** `tiles.mrds` is **gold-filtered
  today** (`CODE_LIST LIKE '%AU%'`). Adding commodity #2 is a config entry **plus** that
  commodity's producer pull (a `pull_mrds.sh` parameterization, out of scope now). The config
  schema must *express* the producer source per commodity; the acceptance criterion below is
  worded to match this reality instead of overclaiming "config-only".

## Boundaries & permission gates
This feature is **green-lane by nature** — additive, reference-only, and never touches the verdict
engine — so **build it autonomously on a branch.** **Merge to `main` is the review checkpoint** (open
a branch; the owner reviews before merge). **Red lines — stop and ask:** anything that would touch the
legality/verdict engine, the `legality_polygons` / legality-tile schema, auth, or destructive ops.
Tier B should need *none* of these; if you believe it does, you've found a design problem — surface
it, don't route around it.

## Invariants — do NOT "fix" or cross these
- The composite never feeds or alters the legality verdict (it's `reference`-role).
- Never present raw Au as "gold is here" (it's censored) — pathfinder-led.
- Don't hard-code gold — keep the commodity generic (config/data).
- Don't over-promise: this is probabilistic *worth-checking*, not "dig here." Keep the upstream +
  uncertainty honest.
- No silent caps/sampling — if you bound coverage anywhere, say so.

## Risks & pre-flight checks (know these going in)
- **Big-join memory:** the sample→HUC join and per-watershed percentile windows run over hundreds
  of thousands of rows × 24k polygons. The dev Postgres container has **OOM-killed a whole-region
  geometry job before** (the low-zoom build, review IMP-07) — batch heavy steps (per state or per
  HU4) rather than one monolithic statement, and expect the ETL to take minutes, not seconds.
- **Disk:** NGDB Parquet 283 MB + WBD GDB up to 2.6 GB + staging tables — a few GB in Docker;
  check free space before pulling the national GDB.
- **Statistical traps:** censored percentiles and method-DL bias (mitigations pinned in the
  scoring spec) — the reality check below is the detector; if High markers trace lab/method
  boundaries instead of geology, stop and tighten the guard.
- **Tile weight:** a dense point layer can recreate the z5–8 tile-timeout problem the legality
  layer had (F-3). The zoom gates + site dedupe should prevent it — verify with a
  `tiles_lowzoom.sh`-style size/latency check and budget **< 500 KB per tile** at the layer's
  minzoom.

## Acceptance criteria (prove it works)
- Data ingested + composite computed; a **headless diag** (model it on `web/diag_mrds.mjs`) proving:
  - the toggle renders **High** glyphs over known gold country (Sierra Mother Lode viewport) at
    its minzoom, and Moderate appears by z≈10;
  - the popup shows tier + anomaly element/percentile + pathfinders + nearest producer + the exact
    upstream-note string + vintage;
  - **hide-below-Moderate is real:** a known-quiet control viewport renders **zero** Tier-B
    markers (the locked "hide everything below" is a testable property, not styling);
  - **the legality engine is untouched:** Tier-A (`run-fixtures.sh` 36/36) and Tier-B
    (`run-tier-b.sh` 45/45) still green; the `/assessment` response at a marker coordinate is
    **byte-identical** with the layer on vs off; the pg_tileserv catalog gains **only** the new
    `tiles.<key>` layer(s).
- **Golden fixtures (regression teeth, the Tier-B-fixtures idiom):** pin 2–3 expectations that
  survive an ETL re-run — e.g. a named Mother-Lode HUC12 contains ≥1 High marker; a named quiet
  control HUC12 contains none. Store them with the other fixtures + wire into the diag or a small
  check script.
- **Reality check on real data:** show a **state × tier count table** and the **top-10 HUC12s by
  High-marker count with names** — known districts (Mother Lode; the Carlin trend, where As is
  *the* classic pathfinder) should appear, and the distribution must be visibly clustered, not a
  uniform smear. If it smears, the design isn't working — investigate before shipping.
- **Prove the generic design honestly:** show a second-commodity **config stub** demonstrating
  that pathfinder set / methods / thresholds / producer-filter are all data — *and* state plainly
  that populating it additionally needs that commodity's MRDS producer pull (documented, not
  hidden).
- **ETL transparency:** kept/dropped row counts for every stated filter (media, elements, region),
  thin-watershed statistics (how many HUC12s rolled up / went unscored), and zero unmatched
  in-region samples after the WBD completeness assertion.

## Deliverables & working style
- The working feature on a branch, merge-ready.
- **Docs to the project's conventions:** a decision-log entry (`PROJECT_PLAN.md` §9 — next free
  number is **#42**), a **§5.3 update** (mark implemented per #41/#42 *and* record the supersessions:
  pathfinders As/Sb/Ag not Hg, 2-tier display, pathfinder-led scoring, tiles-only instead of
  `/api/prospecting`), a `BACKLOG.md` update, a `DATA_SOURCE_INVESTIGATION.md` note on what you
  actually ingested (vintages, counts, any surprises — incl. the WBD region-list outcome), and a
  **README runbook** for the NGDB/WBD ingest.
- A regression diag + the golden fixtures above.
- **Report honestly:** what's verified vs assumed, any data surprises, what you deferred and why.

## Clarifying-questions protocol
Four product calls were **asked and answered 2026-07-10** (see *Owner-resolved product calls*):
marker granularity/zoom, glyph identity vs MRDS, sediment-only media, and the upstream-note string —
don't re-ask those; build to them. The protocol still stands for anything new: ask the owner before
deciding any **product/UX call the locks + resolved answers don't cover** — e.g. if the data says
the ~p90 High bar or the ≥25%-detected guard produce a bad map, or a popup needs wording not
specified here. Batch questions. Everything **technical inside the locked design** (schema, SQL,
tile config, ingest mechanics, threshold tuning within the tier framework) is yours — the *Scoring
spec* defaults are the starting point, and deviations get documented, not silently applied.
