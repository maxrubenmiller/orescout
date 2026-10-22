# Opus Brief — Surface `cannotModel` in the assessment panel (IMP-16a)

**Task type:** frontend presentation · **Effort:** S · **Branch:** one branch, one commit; owner merges.
**Product intent (locked):** OreScout is a safety tool; the list of things the verdict does NOT
model (RMP local rules, Monument proclamations, ESA closures, riparian setbacks) is currently the
*least* visible text on the panel — collapsed behind a `<details>` ("What this doesn't model",
`web/src/components/AssessmentPanel.tsx` ~line 124). Blind spots should be visible by default.

## What to do
1. Make the `cannotModel` items visible without a click, but **compact** — the panel is a narrow
   sidebar and already long. Recommended shape (yours to refine): keep a one-line heading
   ("Not modeled — verify separately:") followed by the items as a tight comma-joined line or
   small-text list, styled muted-but-legible (mirror `.datagaps`/`.warnings` idioms in
   `web/src/index.css`). Dropping the `<details>` entirely is fine.
2. Do NOT change: the items' text (they come from the API), the disclaimer paragraph, the
   warnings/dataGaps rendering, any engine/API code, or the verdict/ambiguity lines added by the
   2026-07-11 polish pass (`.yellow-kind` etc.).
3. Mobile sanity: the panel becomes a bottom sheet on small screens — check it doesn't blow up
   the sheet height unreasonably (viewport 390×844 screenshot).

## Acceptance
- `npx tsc -b` + `npx eslint src` clean (repo is currently at ZERO lint errors — keep it there).
- Full frontend diag suite still green against http://localhost:5173 (they exercise the panel):
  `node web/scripts/diag/diag_states.mjs` (11), `./web/scripts/diag/diag_snapshot.sh` (12 — run from repo root),
  `node web/scripts/diag/diag_failsafe.mjs http://localhost:5173`, `node web/scripts/diag/diag_mrds.mjs`,
  `node web/scripts/diag/diag_prospectivity.mjs`. None of them assert the `<details>` element, but verify.
- Desktop + mobile screenshots of a verdict panel showing the visible not-modeled block.

## Coordination
(Updated 2026-07-12: no concurrent work in flight.) You touch only `AssessmentPanel.tsx` +
`index.css`. Note `MapView.tsx`/`style.ts` changed on 2026-07-12 (supported-states now come from
`/meta`) — not your files, don't be surprised by the diff context. The dev stack (API :5167, key
`dev-local-key-change-me`, vite :5173) hot-reloads. If you create test pins, delete them.
