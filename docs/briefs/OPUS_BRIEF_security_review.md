# Brief — OreScout pre-production security review

**For:** a fresh Opus session (or `/code-review ultra`, using this file as the scope).
**Written:** 2026-08-29, by the session that completed the false-GREEN remediation.
**Status of this dimension:** zero coverage from anyone. Explicitly scoped OUT of the Fable
pre-production audit and OUT of the remediation that followed. Nothing here has ever been reviewed.

---

## What OreScout is

A decision-support web app answering *"can I legally collect / pan / prospect HERE?"* with
RED / YELLOW / GREEN verdicts over public-land and mining-claim data across 8 western US states.
.NET 10 minimal API + React/MapLibre frontend + PostGIS + pg_tileserv, all local Docker today.

**It has never been deployed.** The threat model is therefore *pre-launch*: the question is not
"what is being exploited" but "what must be true before this is exposed to the public internet."

## The two jobs — please do both

**Job 1 — review the surface that exists.** Much of it will not change before launch and is worth
reviewing now: the SQL surface across the API and ETL, the database role separation, secrets
handling, CORS, the API-key middleware, the geocoder proxy, the tile server's exposure.

**Job 2 — review the auth design BEFORE it is built.** User accounts + JWT identity are the largest
remaining pre-launch build and **not a line of it is written** (`EntitlementPrincipal.FromHttpContext`
currently returns `Anonymous` unconditionally, with a `// build this from the authenticated
principal's claims` marker). Reviewing that design now is worth more than auditing it later. Please
give concrete guidance on: identity provider vs roll-your-own, token handling and storage, session
lifetime, and how per-user authorization should be enforced on the pins endpoints (see PR-4 below).

## Scope

**In:** everything under `src/OreScout.Api/`, `web/`, `docker-compose.yml`, `db/01_init.sql`
(roles/grants), the ETL scripts under `scripts/etl/` insofar as they handle credentials or build SQL
from external input, and dependency/licence posture for the NuGet and npm trees.

**Out:** the false-GREEN / legality correctness work. That has just had a full remediation and has
its own gates — see `docs/REVIEW_PREPROD_BACKLOG.md`. Do not re-audit verdict logic.

## Known surface — do not spend time re-deriving this

* **Auth is a single static API key.** `Middleware/ApiKeyMiddleware.cs`, `X-Api-Key` header, read
  from `ORESCOUT_API_KEY` env or `ApiKey` in config, `/api/v1/health` exempt. Documented as a
  single-user POC. **`appsettings.json` carries a default key value and the owner's email address in
  the Nominatim User-Agent — please check whether anything real is committed to git history.**
* **No user accounts.** Every request resolves to `EntitlementPrincipal.Anonymous` with an implicit
  full plan. `GrantAllEntitlementService` grants everything; the frontend's `useIsEntitled` is
  fail-open (tracked as PP-17).
* **Pins have no owner column and `GET /api/v1/pins` returns every pin** (tracked as PR-4). This is
  consistent with the documented single-user POC, and becomes an access-control defect the moment
  accounts land. Ownership must ship *with* auth, not after. Pins store precise lat/lng, free-text
  notes, and a full assessment snapshot. `public.pins` currently holds 0 rows.
* **The geocoder proxies the public OSM Nominatim instance** (`Services/Geocoder.cs`) — single egress
  point, 24 h in-memory cache, a process-wide ≥1 s gate, 10 s timeout. Known issues already filed:
  PR-1 (the gate and cache are per-*process* while OSM's limit is per-*application*), PR-2 (ToS —
  commercial-intent product on a free community instance), PR-3 (the gate is held across the whole
  upstream call, so the queue is unbounded and holds server threads).
* **CORS on the API is an explicit allow-list from config, never a wildcard.**
  **pg_tileserv is `TS_CORSORIGINS: "*"`** — dev-appropriate, needs an allow-list in prod. Filed as
  PR-5 and deliberately handed to you rather than assessed by me.
* **pg_tileserv connects as `tileserv_ro`**, a low-privilege role scoped to the `tiles` schema so
  `public.pins` cannot be auto-published as a tile layer. This appears to be a deliberate and
  effective control (§6.8 gap G) — worth confirming the grants actually match the intent.
* **Postgres runs in a Docker volume with the default `postgres/postgres` credentials** in
  `docker-compose.yml`, ports published to the host.

## Questions worth answering

1. Is there any injection path? Much of the ETL builds SQL by string interpolation in bash from
   `etl/sources.json`; the API uses EF Core and parameterised queries, but please verify — especially
   anywhere user-supplied text (pin titles/notes, geocode queries) reaches a query.
2. Is anything sensitive in git history — keys, tokens, connection strings?
3. What does the API leak on error? `Middleware/GlobalExceptionHandler.cs` — stack traces, SQL text,
   internal paths?
4. Is there rate limiting on anything other than the upstream geocoder call? What stops a caller
   hammering `/assessment` or creating unbounded pins?
5. Input validation: lat/lng bounds, pin title/notes length limits, `assessment_snapshot` size.
   Is stored free text ever rendered unescaped in the frontend?
6. Dependency posture across NuGet and npm — known-vulnerable versions, and licences.
7. Is the tile server safe to expose directly, or does it belong behind the API/CDN?

## Constraints — please respect these

* **Read-only first.** The database holds ~290,000 rows of real ETL output that took hours to build
  and is not backed up. Do not drop, rename or mutate `tiles.*` or `staging.*` tables. `public.pins`
  is empty and safe to exercise.
* **Do not weaken a safety gate to make something pass.** Several gates deliberately fail loudly.
* **No destructive testing, no DoS testing.** This is a local dev box.
* **Do not fabricate findings.** The prior audit's ledger format is a good model: every finding
  carries evidence observed this run, a repro, and a proposed fix. Say plainly when something is
  suspected rather than confirmed — the previous audit's honesty rule (severity is capped when the
  claim rests on outside knowledge rather than a row in this database) worked well and is worth
  keeping.
* **Flag, do not fix.** Report findings; let the owner sequence the work.

## Output wanted

A ledger in the shape of `docs/REVIEW_PREPROD_AUDIT.md` — findings with ID, severity, evidence,
repro, and proposed fix direction — plus an explicit **coverage statement** saying what you actually
examined versus what you did not. The previous audit's most useful section was the honest list of
what it never got to.

Please also give a straight answer to one question: **what must be true before this app is exposed to
the public internet?** Ranked, and separated into "blocks launch" versus "should be fixed soon."

## Context worth reading first

* `docs/REVIEW_PREPROD_PRODUCTION_TRIAGE.md` — PR-1..PR-7, the production-readiness findings. PR-4
  and PR-5 overlap your scope directly.
* `docs/LAUNCH_SEQUENCE.md` — the agreed plan: ship gold, then extend to the rockhounding market.
* `docs/PLANNING_INPUTS.md` — open decisions, including the deployment target, which is still unmade
  and materially affects several of your answers.
* `PROJECT_PLAN.md` §6.2 (auth/CORS), §6.14 (entitlements).
