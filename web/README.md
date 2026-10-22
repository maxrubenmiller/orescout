# OreScout web app

The map UI: React 19 + TypeScript + Vite, MapLibre GL JS for the map, TanStack Query for server
state, Zustand for UI state.

```bash
cp .env.example .env    # API base URL, dev API key, tile server URL
npm ci
npm run dev             # http://localhost:5173 (expects the API on :5167 and tiles on :7800)
npm run lint
npm run build
```

| Path | What |
|---|---|
| `src/components/MapView.tsx` | Map, overlay layers, click-to-assess |
| `src/components/AssessmentPanel.tsx` | The verdict panel |
| `src/components/LeftPanel.tsx` | Layer toggles and saved pins |
| `src/map/style.ts` | Overlay styling (the verdict color grammar) |
| `src/api.ts`, `src/hooks.ts` | API client and React Query hooks |
| `src/store.ts` | UI state (Zustand) |
| `scripts/diag/` | Headless-browser (Playwright) checks of the running app, e.g. `node scripts/diag/diag.mjs` |

See the [project README](../README.md) for the full stack and setup.
