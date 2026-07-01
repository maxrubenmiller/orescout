# Fable Review Brief — OreScout architecture, correctness & production-readiness audit

> **Status: DRAFT for review.** Read-only review brief for a parallel agent. Not yet committed.

## Mission & operating model
You are reviewing **OreScout**, a decision-support web app that answers *"Can I legally
collect/pan/prospect HERE?"* for amateur miners. It overlays public land-management + mining-claim
data on a map with RED/YELLOW/GREEN verdicts. Your job: **spot holes, red-team the safety property,
and fine-tune the future-state design toward a production launch.**

This is **phased, gated work — you STOP at each gate:**

- **Pass A (this brief) — review + backlog. Read-only, no code changes.** Audit correctness,
  architecture, and (at triage depth) production-readiness; red-team the cardinal safety property;
  then deliver a findings report, an executable improvement backlog, open questions, and a scoped
  recommendation for Pass B. **Then stop.**
- **Pass B (optional, gated) — deep production-readiness & threat-model.** A deeper engagement on
  whatever Pass A flags as warranting it (e.g. a full threat model, a legal/ToS analysis, a cost/scale
  model). **You do not start Pass B** — you scope and recommend it at the end of Pass A and wait for
  the owner to green-light it. This is your "what next once A is done."
- **Execution (gated) — implementing backlog items.** You do not modify anything until specific items
  are approved. See **Permission gates** at the end.

**One pass vs. two:** the owner may either fold Pass B into Pass A (a single, broader pass — simpler,
less depth per area) or run them separately (Pass A now, Pass B later — more depth). **Default: two
passes.** Do Pass A now at review/triage depth across *all* dimensions below, and **tee up Pass B**
rather than going deep on the production/threat-model dimensions yourself — unless the owner says to
do one combined pass.

**Clarifying questions — ask up front, once, then proceed.** If you can reach the owner: at the *start*
of Pass A, batch a small set of **high-leverage** clarifying questions — anything about priorities,
constraints, timeline, or intent that would materially change the backlog's shape or prioritization
(where a few answers save a whole misdirected backlog). Keep it **one bounded, front-loaded batch — do
NOT block continuously** (that defeats running in parallel). For everything else, proceed on
**explicitly-documented assumptions** (record them in Part 3) and flag where a different answer would
flip a finding or its priority. **If you are running fully headless** (no way to reach the owner
mid-run), skip the batch entirely and rely on documented assumptions + priority-flip flags, resolved
at the review gate.

Review the committed `main` HEAD (the PAD-US 4.1 upgrade just landed at `7204f52`; the tree is clean
and current).

## Stack (orientation)
ASP.NET Core C# API · PostgreSQL 16 + PostGIS · pg_tileserv (vector tiles) · React + Vite + TS +
MapLibre GL.

**How it works, in one paragraph:** PAD-US land data → a SQL rules classifier bakes a RED/YELLOW/GREEN
`verdict` per polygon into `tiles.legality_polygons` (the offline "unify"). The C# `/assessment` engine
then does **Stage 0** in-region gate → **Stage 1** read the baked verdict via a most-restrictive point
lookup → **Stage 2** live BLM MLRS claims overlay. Overlays are served as vector tiles from a `tiles`
schema; MapLibre filters on `verdict`.

## Start here (reading path)
1. `PROJECT_PLAN.md` — the design bible. Priorities: **§5** (rules engine), **§6.2** (canonical API),
   **§6.3** (failure behavior), **§6.4 / 6.4.1 / 6.4.2** (rules engine, Confirm-Open, fixtures),
   **§6.6.1** (ETL), **§6.13** (per-state source registry + the 🔒 invariant), **§9** (the 35-entry
   decision log).
2. `TODO.md` (Definition of Done + done/open), `PRODUCTION_READINESS.md` (post-POC scope),
   `DATA_SOURCE_INVESTIGATION.md` (data decisions).
3. Code: `src/OreScout.Api/` (`Endpoints/ApiEndpoints.cs`, `Services/AssessmentService.cs`,
   `Services/*ClaimsService*`, `Middleware/`, `Models/Models.cs`, `Data/`), `db/02_classifier.sql`,
   `scripts/etl/*.sql` + `*.sh`, `web/src/` (`hooks.ts`, `api.ts`, `map/style.ts`, `store.ts`,
   `components/`).

## How to review — RUN it, don't just read it (verification mandate)
Reading code alone produces plausible-but-wrong findings, which are worse than none. **Ground every
claim empirically:**
- **Stand the app up** (`docker compose up -d`; API on :5167; web on :5173 — see README quick start)
  and **run every test harness**, reporting empirical pass/fail:
  `./scripts/run-fixtures.sh` (Tier-A classifier), `./scripts/run-tier-b.sh` (Tier-B golden
  coordinates), `scripts/test/postgis_down_503.sh` (503 path), the `web/diag_*.mjs` headless checks.
  Then **try to add cases that break them.**
- **Every finding needs a reproduction** — a command, coordinate, or request that demonstrates it.
  Anything you can't reproduce or verify goes under **Open questions**, not Findings.
- **Rate confidence** (High / Med / Low) on every finding.

## Red-team the cardinal safety property (named task, do this explicitly)
**False-GREEN — telling a user land is open when it isn't — is the one failure that can cause real
harm** (trespass, fines, liability). Don't just "scrutinize"; **actively try to produce one:**
- Enumerate **every code path that can yield GREEN** (engine Stage 0/1/2 + the SQL classifier +
  the CA confirm-open step) and, for each, construct an input (coordinate / attribute tuple) that
  *should* be more restrictive, then check what the engine actually returns.
- Probe the known-thin spots: overlapping PAD-US polygons, new/unmapped designation codes, the
  no-data↔GREEN boundary, the CA CAL-FIRE confirm-open difference, stale-data cases, and Stage-2
  claim gaps (MLRS timeout/partial).
- Report any false-GREEN you find (with a repro), or state clearly that you exercised the enumerated
  paths and could not.

## Invariants & intentional decisions — DO NOT flag these as bugs
Deliberate; verify they are *honored*, don't argue against them:
- **Confirm-Open (#30): "GREEN must be earned."** Unconfirmed → cautious YELLOW. **Over-cautious YELLOW
  is correct; false-GREEN is the cardinal sin.** No-data → YELLOW/`UNKNOWN` is intentional, not an error.
- **Verdict semantics + "most restrictive wins"** (RED > YELLOW > GREEN > none).
- **§6.13 registry invariant:** adding a state/source = a JSON entry + a small classifier mapping; the
  engine, tiles, and UI never change. `reference`-role overlays (waterways) **never touch the verdict
  engine** — by design.
- **Saved-pin snapshot is immutable (#32):** viewing a pin shows the stored snapshot + a live *drift
  banner*, not a re-assessment. There is no "refresh."
- **POC posture:** the single static API key is a deterrent, **not** real auth (§6.2); single-user;
  real auth + multi-user + Azure hosting are **post-POC** (#29). PAD-US ingest is a **browser-gated
  manual annual download by design** (#35). *(Flag these as production gaps in the backlog — just
  don't report them as "bugs.")*

## Review dimensions

**Correctness & architecture (Pass A core):**
1. **Legality-engine correctness & safety** — highest priority; see the red-team task above.
2. **Architecture consistency** — does the code honor the invariants? Abstraction leaks, engine/
   reference coupling, per-state branching, verdict-contract violations?
3. **Data model / ETL robustness** — staging → unify → confirm_open → tiles: idempotency, failure
   modes, provenance/vintage, the `ST_Subdivide` confirm-open path.
4. **API contract soundness** — the canonical `/assessment` schema, `503`/`500` handling, the pins
   snapshot contract, CORS/auth posture (POC vs prod).
5. **Plan/doc coherence** — planning docs + decision log internally consistent and current? Stale or
   contradictory decisions? Any gap in the Definition of Done?

**Production-launch readiness — anchor to the committed future: PUBLIC, multi-user w/ accounts,
Azure-hosted, cost-minimized.** *(Pass A triages these — surface, cite, prioritize, feed the backlog.
Pass B goes deep on whatever warrants it.)*
6. **Legal / liability *(highest production risk)*** — the app renders legality determinations; a wrong
   "open" answer can lead to trespass or fines. Is the disclaimer / ToS / accuracy posture defensible
   for a public launch? Where can a wrong answer cause real harm, and is it surfaced honestly?
7. **Security threat model** — auth (API key is a deterrent, not auth); **authorization — pins have no
   `user_id`, so per-user isolation is unbuilt**; input validation / injection; **DoS — every
   assessment fires a live BLM MLRS call**; secrets management; rate limiting.
8. **Privacy / data governance** — saved pins are **sensitive user *location* data** (where someone
   prospects); retention, PII, GDPR/CCPA for a public app.
9. **Third-party dependency, ToS & cost at scale** — map each external dependency's failure mode + ToS
   + cost: **Nominatim geocoding (its public-instance usage policy forbids heavy use — a real launch
   blocker)**, live BLM MLRS per request, tile serving (Esri / Mapbox), ScienceBase. Cost-model the
   per-request path (the owner prioritizes minimizing cost).
10. **Data-staleness → confidently-wrong answer** — PAD-US lags reality by months–years; claims are
    nightly. The drift banner covers *saved* pins, but a *fresh* assessment on stale data can be wrong.
    Is that communicated honestly? (Ties straight back to #6.)
11. **Scalability & cost model** — single Postgres + pg_tileserv + a DB query *and* an external call
    per click; caching / CDN; what it costs at N users.
12. **Observability / SLOs, CI & test maturity, accessibility (a11y).**

**Concrete deliverable for the production half:** validate and extend `PRODUCTION_READINESS.md`
against a real launch checklist for a legal-adjacent public geo app, and flag what's missing.

## Out of scope (in-flight — don't flag)
The frontend-polish items already being worked: **geocode results dropdown**, **loading/empty/error-
state QA**, and the **KNOWN-vs-UNKNOWN ("possibly private") message wording** (see `TODO.md` → "Frontend
follow-ups"). Skip these.

## Severity rubric (so severities actually mean something — use it, don't inflate)
- **Critical** — can produce a **false-GREEN**, expose/leak **user data**, or create **legal exposure**;
  or a data-integrity defect in the verdict pipeline.
- **High** — a correctness or security issue with a narrow blast radius or a workaround; a
  production-launch blocker (e.g. a third-party ToS violation at scale).
- **Medium** — a real, non-blocking issue; architectural debt that will bite at scale.
- **Low** — minor (but not the style nitpicks we've excluded).

## Deliverable — Part 1: Findings report (high-signal)
A single markdown report. Structure:
- **Executive summary:** overall health read + the top 3–5 findings that actually matter.
- **Findings**, each with: **Severity** (per the rubric) · **Confidence** (H/M/L) · **Category**
  (Correctness-Safety / Architecture / Data-ETL / API / Docs-Plan / Legal / Security / Privacy /
  Dependency-Cost / Staleness / Scalability / Observability) · **specific `file:line` or `§section`** ·
  the issue · why it matters · a **reproduction** · a concrete suggested action.
- **Sorted** by severity, **deduped**, **split** into: *fix before POC-closed* (correctness / DoD) vs
  *pre-public-launch* (production gates) vs *nice-to-have*.
- **Rules of the road:** no style/formatting nitpicks; don't re-flag the intentional decisions above;
  if you find many Low items, **summarize them in one table** rather than expanding each. Tie every
  claim to evidence in the code/docs.

## Deliverable — Part 2: Improvement backlog (executable, but NOT yet executed)
A **prioritized backlog of concrete, executable work items** derived from the findings — a *plan for
approval*, not work you do now. Each item:
- **ID** (`IMP-01`…) · **Title** · **Priority** (**P0** fix-before-POC-close / **P1** pre-public-launch /
  **P2** nice-to-have) · **Category** (same taxonomy).
- **What & why** — the change and the finding it resolves.
- **Files/areas likely touched** and **acceptance criteria** (done-definition + how to verify).
- **Rough effort** (S/M/L), **dependencies**, and **risk / blast radius** — flag anything touching the
  **verdict engine, DB/tiles/schema, or shared frontend files**, and anything that would **collide with
  the in-flight frontend polish** or need a schema/tile rebuild.
Order so P0 items are clearly separated from P1/P2.

## Deliverable — Part 3: Open questions / couldn't verify / assumptions
Everything you couldn't confirm, the assumptions you made, and questions whose answers would change
your findings. **The unknowns are as valuable as the findings** — don't paper over them.

## Deliverable — Part 4: Pass B recommendation
Based on what surfaced, **scope and recommend Pass B** (the deep production-readiness / threat-model
engagement): is it warranted? which dimensions need depth (e.g. a full STRIDE threat model, a legal/ToS
deep-dive, a cost/load model)? rough effort, and what it would produce. This is the explicit **"what to
do next once A is done"** — the owner will green-light Pass B, fold it into a follow-up, or defer it.

## Permission gates — STOP and ask (do not proceed unprompted)
**Do not modify any code, schema, or data in Pass A.** Deliver Parts 1–4, then **STOP.** Three things
each need the owner's explicit, separate go-ahead:
1. **Executing backlog items** — which specific items to implement.
2. **Running Pass B** — the deep production-readiness / threat-model pass.
3. **Anything outward-facing or irreversible** — always confirm first.

When (and only when) **execution** is approved:
- Work on an **isolated `git` branch / worktree** — parallel changes are happening on `main`; do not
  commit to `main` or touch uncommitted work.
- Keep each change **scoped to the approved item**, respect every invariant above, and re-confirm
  before anything irreversible or outward-facing.
- Prefer **one branch/PR per backlog item** (or tight cluster) so each can be reviewed independently.
