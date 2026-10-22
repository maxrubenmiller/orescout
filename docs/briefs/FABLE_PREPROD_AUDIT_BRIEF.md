# Fable Pre-Production Audit Brief — OreScout

**For:** Claude Fable 5 · **Repo:** OreScout (audit `main`, current HEAD) · **Task type:** audit +
gated active-fix · **Date:** 2026-07-19

> **Run settings:** `xhigh` effort; adaptive thinking on (default). Expect multi-minute turns on the
> deep passes. You are the most capable model available — this brief is written to run you at your
> ceiling (see **§ Run this at Fable's ceiling**), not as a linear checklist. Within the hard
> boundaries below, design your own method.

## Mission
Audit **OreScout** — a decision-support web app answering *"Can I legally collect / pan / prospect
HERE?"* for amateur miners (RED / YELLOW / GREEN verdicts over public-land + mining-claim data across
8 western states). This is the **pre-production gate**: before the owner pours effort into Phase-1
productionization, find every hole that is expensive to fix once the app is under IaC + real users.
**Red-team the cardinal safety property, verify the reference-role invariant across all the new
overlays, and — for confirmed Critical/High safety bugs — fix and lock them.**

> **Security review is OUT of scope for this run** (handled separately via `/security-review` / Opus).
> Do not perform vulnerability scanning, secret scanning, or penetration testing. Your focus is
> **verdict correctness and the false-GREEN safety property** — the highest-value work and your strength.

## The cardinal safety property (red-team this above all else)
**The app must never tell a user that closed or private land is open.** A **false-GREEN** (GREEN
verdict on land that is actually private, prohibited, or ambiguous) is the catastrophic failure.
Your single highest-value output is a *constructed* false-GREEN — an actual coordinate/scenario where
`/assessment` returns GREEN (or the map paints green/open) on land that isn't. Pass-A found exactly
one this way (Alta, UT). Hunt for more, adversarially, across all 8 states and every code path that
can produce or display a verdict.

## Read first (ground yourself — do NOT re-derive settled work)
- **`docs/REVIEW_PASS_A.md`** — the prior Fable review. Findings F-1…F-7 / IMP-01…18. **Most are
  addressed** (Alta closed by confirm-open across all 8 states; tiles by the low-zoom layer; YELLOW
  fail-safes added; etc.). Your job re: Pass-A is a **regression check** — verify each fix *stayed*
  fixed and didn't get undone by later work — not to re-report them.
- **`docs/briefs/FABLE_REVIEW_BRIEF.md`** — the Pass-A brief (conventions, safety framing). Same operating ethos.
- **`docs/planning/PROJECT_PLAN.md`** — §-numbered architecture-of-record: §5 (data sources/overlays), §6.4/§6.4.1
  (verdict engine + Confirm-Open ethos — "GREEN must be earned"), §6.13 (registry-driven ETL
  invariant), §6.14 (paywall seam), §9 decision log (#42–#46), the Changelog.
- **`docs/planning/PRODUCTION_READINESS.md`** (Phases 1–4 + gates), **`docs/planning/BACKLOG.md`**, **`docs/planning/TODO.md`**, **`docs/planning/UI_CHANGES.md`**.
- **The verdict engine:** `src/OreScout.Api/Services/AssessmentService.cs` (Stage 0 in-region →
  Stage 1 most-restrictive baked verdict → Stage 2 live claims), `db/02_classifier.sql`,
  `scripts/etl/unify.sql`, `scripts/etl/confirm_open_*.sql`, `etl/sources.json` + `registry_lib.sh`.
- **The regression harnesses** (your evidence base — run them): `scripts/run-fixtures.sh` (Tier-A),
  `scripts/run-tier-b.sh` (Tier-B), `scripts/validation/run_tier1_validation.sh` +
  `validate_private_coverage.sh`, `scripts/test/*.sh`, `web/scripts/diag/diag_*.mjs`.

## Scope — what is NEW since Pass-A (the primary review surface)
All of this landed *after* Pass-A and has **not** had a dedicated adversarial review:
1. **Confirm-open expanded to all 8 states** (#44) + the **Tier-1 private-land validation** (0/1,504,
   CP UB 0.245% < 0.5%) + the **parcel-grade carve**. Red-team: does the false-GREEN gate actually
   hold in the 7 states beyond the original CA? Are the CO/NM owner-regex carves sound (false
   positives/negatives)? What about the ~0.6% SMA-resolution leak in **parcel-uncovered counties** —
   can you construct a false-GREEN there? Rural NV?
2. **§6.13 registry-driven ETL** — `etl/sources.json` single source of truth. Red-team the invariant:
   can a registry edit silently corrupt a verdict? Are the two bespoke loaders (CA calfire / UT ugrc)
   and the unguarded MRDS main URL a drift risk?
3. **Reference-role overlays** — `tiles.access` (#46), `tiles.prospectivity` (#42), `tiles.waterways`,
   `tiles.mrds`, and **`tiles.legality_display`** (the new dissolved display partition, docs/planning/UI_CHANGES.md).
   Verify the invariant **exhaustively**: NONE may influence a verdict. `/assessment` must be
   byte-identical with each layer's data present vs absent; the pg_tileserv catalog and the
   low-priv `tileserv_ro` role must be isolated; no engine code references these tables.
   **Special attention:** `tiles.legality_display` is a *display* clone of `tiles.legality_polygons` —
   confirm the engine still queries the ORIGINAL, that the display partition stays consistent with the
   most-restrictive verdict (green clipped under yellow ⇒ engine returns YELLOW there), and that the
   dev/coarse-grid low-zoom build didn't drop real prohibited/private area.
4. **Paywall/entitlements seam** (§6.14) — stub grants everything today. Verify it cannot gate or
   alter a verdict, and that the tiles-bypass-the-API gap is documented, not accidentally load-bearing.
5. **Refresh Phase A** (`refresh_lib.sh`, `public.data_sources` freshness registry) + the red-lane
   **claim-warning rewording** (2026-07-15) — verify the reworded strings + split-estate reason are
   correct and can't over/understate rights.

## Operating model — phased, gated
- **Phase 1 — AUDIT (read-only).** Find, verify, and rank. Deliver a findings report + prioritized
  remediation backlog + the reference-role invariant proof + a security sweep. Default depth: full.
- **Phase 2 — ACTIVE FIX (gated; the last-night payoff).** For findings you rate **Critical or High
  on the safety property**, fix them on a branch **and write the regression test/fixture that locks
  each** — so this run yields shippable safety fixes, not just a report. **Do NOT touch anything
  outside approved findings.** If you cannot reach the owner mid-run (headless), still do Phase 2 for
  **Critical safety findings only**, each behind its own branch + test, and leave High/Medium as a
  backlog for owner approval. Everything Medium and below stays report-only.

## Review dimensions (audit at full depth)
1. **Verdict correctness / false-GREEN** (the cardinal property — most effort here).
2. **Data/ETL integrity** — unify → confirm-open → parcel-carve → tiles; registry faithfulness;
   regression-gate coverage of the *new* surface (are there confirm-open / access / prospectivity /
   display goldens, or blind spots like Pass-A's F-4?).
3. **Reference-role invariant** across all overlays (§ Scope 3).
4. **Frontend safety** — verdict/ambiguity rendering fail-safes (Pass-A F-5 pattern); the new legality
   display repoint + the original-sourced RED outline; does any display path make prohibited/ambiguous
   land look open?
5. **Security — OUT OF SCOPE for this run** (separate pass via `/security-review` / Opus). Do not
   do vulnerability scanning, secret scanning, or pen-testing. If you happen to notice an obvious
   input-validation or injection gap while auditing correctness, note it as a one-line backlog item
   for that separate pass — but do not pursue it as a security review here.
6. **Production-readiness (triage depth only)** — flag launch blockers (geocoder ToS, tile pipeline,
   privacy/retention) but do NOT deep-dive infra; that's owner/Phase-1 work.

## Deliverables
- **`docs/REVIEW_PREPROD_AUDIT.md`** — findings (severity-ranked, each with a **runnable repro** and a
  proposed **regression test**), the reference-role invariant proof table, and a prioritized
  remediation backlog (mark which you fixed in Phase 2 vs left for approval).
- **Phase-2 branch(es)** — one per Critical/High safety fix, each with its locking test, merge-ready.
- **Updated regression coverage** — new goldens/fixtures for the new overlays where you found gaps.
- **Report honestly:** what you verified vs assumed; every finding backed by evidence; what you
  deferred and why.

## Permission gates & boundaries — STOP and respect these
- **Phase 1 is read-only.** Do not modify code during the audit.
- **Phase 2 touches code only for approved (or, headless, Critical-safety) findings**, each on its own
  branch, never merged by you — **merge is the owner's gate.**
- **Red lines — never cross:** don't change the classifier's verdict semantics without flagging it as
  a finding first; don't weaken a safety gate to make a test pass; don't touch auth beyond reporting;
  no destructive ops; do not fabricate a finding or a passing result — every claim needs a repro.

## Clarifying-questions protocol
Ask a **single bounded batch** of high-leverage questions **once at the start** (priorities, the
Phase-2 fix appetite, any area to skip), then proceed on **documented assumptions** with priority-flip
flags. If fully headless, skip the batch and rely on documented assumptions. Do **not** block
continuously — that defeats running your sub-agents in parallel.

---

# Run this at Fable's ceiling — orchestration & active mode
*(This section was added from an Anthropic-developer lens: the sections above describe a competent
review; this section is what turns it into a run that actually uses Fable-5-class capability. Prefer
these methods over a single linear read-through.)*

**1. Fan out adversarial review lenses as parallel sub-agents; you orchestrate + synthesize.**
Don't sweep the repo linearly. Spawn concurrent sub-agents, each owning one lens — (a) false-GREEN
red-team, (b) data/ETL integrity + registry faithfulness, (c) reference-role invariant, (d) frontend
verdict-display safety. Each runs blind to the others (diversity catches what redundancy can't); you
dedupe and rank their findings. This is long-horizon orchestration — your
strength; sustain the sub-agents asynchronously and intervene only when one goes off-track.

**2. Adversarially VERIFY every candidate finding before it ships.** For each finding, spawn skeptic
sub-agents whose job is to *refute* it (default to "not a real bug" unless a concrete repro survives).
Kill any finding a majority refute. This is the single biggest quality lever for a review — it kills
the plausible-but-wrong findings that make review output untrustworthy. Ship only CONFIRMED findings,
each with the repro that survived refutation.

**3. Red-team the safety property as active construction, not passive reading.** Don't just read the
verdict code hoping to spot a bug — *try to build a false-GREEN.* Enumerate: private inholdings inside
GREEN federal polygons (the Alta class) in each of the 8 states; parcel-uncovered counties (the ~0.6%
leak); split-estate + claim-converted UNKNOWN edges; boundary-exact points; the confirm-open carve's
sliver/OOM edges; REC/GAP-4 permitted-use areas. Probe live `/assessment` at candidate coordinates and
interrogate the DB for the GREEN-producing attribute tuples. A single new constructed false-GREEN is
worth more than the entire rest of the report.

**4. Loop until dry.** Keep spawning finder rounds until **2 consecutive rounds surface nothing new**
(dedupe against everything seen, not just what you confirmed). A single pass always misses the tail;
the tail is where the next Alta hides.

**5. Run a completeness critic as the last pass.** A dedicated sub-agent asks: *what surface was never
reviewed, which invariant never checked, which claim never repro'd, which of the 8 states never
probed?* Whatever it finds seeds one more round. Then state plainly what you did NOT cover.

**6. Make every finding executable — repro + locking test.** A finding without a runnable repro is a
guess; a Critical finding without a regression test recurs. For each confirmed finding, deliver the
one-command repro (a `curl`, a SQL query, a diag) AND the regression fixture/test that would have
caught it — so Phase 2's fixes are verifiable and the bug can't come back.

**7. Use the last-night window to FIX, not just find (Phase 2).** You are the most capable model the
owner has, and this is their last session with you. Don't spend it only producing a report Opus could
act on later — for the confirmed **Critical/High safety** findings, implement the fix on a branch and
write its locking test in the same run. That converts your depth into shippable safety, which is the
highest-value thing a premium model can leave behind on a legality app heading to production.

**8. Keep a findings ledger in a file as you go, and ground every claim.** Maintain a running
`docs/REVIEW_PREPROD_AUDIT.md` ledger (append as you confirm findings) rather than holding it all in
context — it survives compaction across a long run and is your source of truth. Before reporting any
result, audit the claim against an actual tool result; report failures with the output, skipped
checks as skipped, and confirmed fixes plainly. Do not report a green result you did not observe.

**9. Expand the regression net for the new overlays.** Pass-A's F-4 was a false-GREEN that the gate
*missed* because no fixture covered that path. The new surface (access, prospectivity, waterways,
legality_display, confirm-open in 7 new states) is exactly where that failure mode repeats. Where you
find a path with no golden, add one — the audit should leave the harness stronger than it found it.

**10. Scale depth to a token budget if the owner sets one.** If given a budget, run more finder/verify
rounds and more sub-agent lenses until it's spent; if not, default to the loop-until-dry stop. Bias
toward exhaustiveness — this is a safety audit before launch, and thoroughness beats brevity here.
