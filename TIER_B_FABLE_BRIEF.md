# Tier B — Prospecting-Potential Composite: Fable Build Brief

**For:** Claude Fable 5 · **Repo:** OreScout (build off `main`) · **Task type:** build (not review) ·
**Date:** 2026-07-10

This is a **goal + constraints + acceptance** brief, not a step-by-step script. You are the capable
builder — design the implementation. What's *locked* below is locked (owner's product calls);
everything technical inside those constraints is yours to decide. When a genuine product/UX ambiguity
appears that the locked decisions don't cover, **ask the owner** — a short question beats a wrong rebuild.

## Mission
Build OreScout's **prospecting-potential overlay** (`PROJECT_PLAN.md` §5.3): a map layer that answers
*"where is it genuinely worth checking for gold?"* from USGS geochemistry. The whole point is to
surface **where it's worth looking — not where gold atoms happen to exist** (trace gold is
everywhere). It is a display-only overlay that **never touches the legality verdict engine**.

## Read first (ground yourself — don't re-derive what's settled)
- `PROJECT_PLAN.md` **§5.3** (the composite design: the three signals, tier output, upstream caveat,
  the precomputed-static approach), **§6.13** (per-state source registry + the invariant guarantee),
  **§6.4.1** (Confirm-Open ethos — "must be earned").
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
  HUC codes** (do a fresh PostGIS `ST_Contains` join); closed-basin `tohuc` sinks are common in the
  Great Basin — handle them.

## The build (the WHAT — you design the HOW)
1. **Ingest** NGDB (Parquet) + WBD (HUC12) into PostGIS, download-and-host (mirror `scripts/etl/`
   patterns). Record source vintage/snapshot for honest provenance.
2. **Compute the composite once at ingest** (a precomputed static layer per §5.3), **generic over
   commodity**:
   - *Signal 1 — relative anomaly* per **HUC12 watershed** (regional-background percentiles; roll up
     to HUC10 where a HUC12 holds too few samples for a stable background).
   - *Signal 2 — pathfinder co-elevation* (per-commodity pathfinder set; gold = As/Sb/Ag).
   - *Signal 3 — proximity to a historic MRDS **producer*** (`tiles.mrds.is_producer`, ~2 km).
   - → the conservative **2-tier** output (High / Moderate; hide the rest).
3. **Serve** it as a `tiles.<key>` table via pg_tileserv, a new `reference`-role registry entry
   (§6.13), keyed so **gold is the first populated commodity**.
4. **Frontend** — a "Prospecting potential (gold)" toggle + tiered markers (High vs Moderate, per the
   §5.3 styling) + a click-popup showing tier, pathfinders present, nearest MRDS record, and the
   standard upstream note. Reuse the MRDS overlay's hover-highlight + tolerance-box click.
5. **Uphold the invariant** — the assessment engine, legality tiles, and the verdict path are
   untouched by any of this.

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

## Acceptance criteria (prove it works)
- Data ingested + composite computed; a **headless diag** (model it on `web/diag_mrds.mjs`) proving:
  the toggle renders tiered markers over known gold country; the popup shows tier + pathfinders +
  nearest MRDS + the upstream note; and **the legality engine is untouched** — Tier-A (`run-fixtures.sh`)
  and Tier-B (`run-tier-b.sh`) still green, and a verdict at a marker is identical with the layer on vs off.
- **Reality check on real data:** High-Potential markers concentrate where they should (e.g. the
  Sierra Mother Lode, the Carlin trend) and are *not* smeared uniformly — evidence the
  "relative-anomaly, not raw-concentration" design is actually working. Show the distribution.
- **Prove the generic design:** adding a second commodity is demonstrably a config entry (show the
  config, even if you don't populate it).

## Deliverables & working style
- The working feature on a branch, merge-ready.
- **Docs to the project's conventions:** a decision-log entry (`PROJECT_PLAN.md` §9), a §5.3
  "implemented" status note, a `BACKLOG.md` update, a `DATA_SOURCE_INVESTIGATION.md` note on what you
  actually ingested (vintages, counts, any surprises), and a **README runbook** for the NGDB/WBD ingest.
- A regression diag + any fixtures.
- **Report honestly:** what's verified vs assumed, any data surprises, what you deferred and why.

## Clarifying-questions protocol
Ask the owner before deciding anything that's a **product/UX call the four locked decisions don't
cover** — e.g. if the data suggests the ~10% High bar is wrong, marker styling specifics, or the exact
wording of the upstream note. Batch questions where you can. Everything **technical inside the locked
design** (schema, SQL, tile config, ingest mechanics, thresholds within the tier framework) is yours.
