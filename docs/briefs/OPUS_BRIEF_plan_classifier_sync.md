# Opus Brief — Sync §6.4 / §6.6.1 with the live classifier (IMP-17)

**Task type:** documentation-only · **Effort:** S · **Branch:** one branch, one commit; owner merges.
**Hard rule: `db/02_classifier.sql` is the single source of truth. You are changing the DOCS to
match the CODE — never the reverse. Any edit to the classifier itself is out of scope (red-lane).**

## The problem
`PROJECT_PLAN.md` §6.4 (Stage-1 decision table) and the §6.6.1 code sample predate two
reconciliations and drift from the shipped classifier:
- §6.4 PRIORITY 1 / the §6.6.1 sample still list **`NWRA`** and **`WIL`** — codes deliberately
  dropped 2026-06-18 when the real PAD-US domain was confirmed (they don't occur).
- The classifier's RED list has **`TRIBL`, `SW`** and the YELLOW list has
  **`WSR`, `NSBV`, `REA`, `RANE`, `HCAE`** (#35) **+ `REC`, `SDA`, `HCA`, `LHCA`, `SHCA`, `RMA`,
  `SCA`, `UNKE`** (#36) — §6.4 PRIORITY 3 was updated for #36 but verify every list end-to-end.
- The manager lists in §6.4 PRIORITY 2/4 vs `orescout_classify_sma` likewise need a line-by-line
  check (the classifier gained many codes in the 8-state reconciliation).

## What to do
1. Read `db/02_classifier.sql` (the four functions + header) — extract the exact current lists.
2. Correct §6.4's PRIORITY 1–4 lists and the §6.6.1 inline SQL sample to match, preserving the
   document's format and per-code parenthetical descriptions (add brief ones for new codes).
3. Add one note at the top of the §6.4 Stage-1 block: *"The authoritative lists live in
   `db/02_classifier.sql` (Tier-A fixtures lock them); this table mirrors them as of <date> —
   if they ever disagree, the classifier is right."*
4. Check the §6.4.2 Tier-A fixture table for the same stale codes; fix if present.

## Acceptance
- Every code in §6.4's lists appears in the corresponding classifier list and vice versa
  (show a diff-style check in your report — e.g. sorted lists side by side).
- `git diff` touches ONLY `PROJECT_PLAN.md` (+ a changelog line at the file bottom if the doc's
  convention calls for it).
- `./scripts/run-fixtures.sh` still 36/36 (proves you didn't touch the classifier).

## Machine gotchas
`~/.curlrc` adds retries (use `curl -q` if you probe anything); docker compose from the main
checkout works as-is. See also the coordination note in `TODO.md` — Fable is working ETL threads
concurrently; you touch only PROJECT_PLAN.md, so no collision.
