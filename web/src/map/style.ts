import type { StyleSpecification } from 'maplibre-gl';
import type { FeatureCollection } from 'geojson';
import { tileBaseUrl, mapboxToken } from '../api';
import type { Basemap } from '../store';

// The MapLibre map is created once on mount; Fast Refresh won't recreate it, so edits to the
// map style/source-layers would otherwise leave a stale map until a hard refresh. Force a full
// reload when this module changes during dev.
if (import.meta.hot) import.meta.hot.accept(() => window.location.reload());

const SUPPORTED = ['NV', 'CA', 'AZ', 'CO', 'UT', 'NM', 'OR', 'ID'];

// MVT vector-layer name as ENCODED IN THE TILE by pg_tileserv = the full schema-qualified
// table id (verified by decoding a .pbf). NOTE: the TileJSON `vector_layers[].id` reports it
// WITHOUT the schema, which is misleading — the tile itself uses `tiles.legality_polygons`.
export const LEGALITY_SRC_LAYER = 'tiles.legality_polygons';
export const LEGALITY_LOWZOOM_SRC_LAYER = 'tiles.legality_lowzoom';
export const CLAIMS_SRC_LAYER = 'tiles.claims_polygons';
export const WATERWAYS_SRC_LAYER = 'tiles.waterways';
export const MRDS_SRC_LAYER = 'tiles.mrds';
export const PROSPECTIVITY_SRC_LAYER = 'tiles.prospectivity';

// Prospecting-potential zoom gates (owner call #1): High from z7, Moderate from z10
// (mirrors how claims z9 / waterways z10 gate density).
export const PROSPECTIVITY_HIGH_MINZOOM = 7;
export const PROSPECTIVITY_MODERATE_MINZOOM = 10;

// All prospectivity layer ids — MapView toggles/hit-tests the whole set (symbols + the
// F-5 fallback circles beneath them).
export const PROSPECTIVITY_LAYER_IDS = [
  'prospectivity-high-fallback',
  'prospectivity-moderate-fallback',
  'prospectivity-high-producer',
  'prospectivity-high-chemistry',
  'prospectivity-moderate',
];

// Below this zoom the legality overlay renders from the generalized `tiles.legality_lowzoom`
// layer (simplified + sub-pixel polygons dropped at ETL, scripts/etl/build_lowzoom.sql). The
// full-resolution table produced 1-3 MB tiles at z5-6 that blew pg_tileserv's 10s statement
// timeout under a normal concurrent viewport fetch -> HTTP 500 -> RED/YELLOW land silently
// rendered blank at state-wide zooms (IMP-07 / review finding F-3).
export const LOWZOOM_SPLIT = 9;

export function basemapTiles(b: Basemap): { tiles: string[]; attribution: string } {
  if (b === 'satellite') {
    if (mapboxToken) {
      return {
        tiles: [`https://api.mapbox.com/v4/mapbox.satellite/{z}/{x}/{y}@2x.jpg?access_token=${mapboxToken}`],
        attribution: '© Mapbox © Maxar',
      };
    }
    // Keyless fallback for local dev (Esri World Imagery). See PROJECT_PLAN.md §7.
    return {
      tiles: ['https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}'],
      attribution: 'Imagery © Esri',
    };
  }
  if (b === 'topo') {
    return {
      tiles: ['https://basemap.nationalmap.gov/arcgis/rest/services/USGSTopo/MapServer/tile/{z}/{y}/{x}'],
      attribution: 'USGS The National Map',
    };
  }
  return {
    tiles: ['https://a.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}.png'],
    attribution: '© OpenStreetMap © CARTO',
  };
}

export function buildStyle(basemap: Basemap): StyleSpecification {
  const bm = basemapTiles(basemap);
  return {
    version: 8,
    glyphs: 'https://demotiles.maplibre.org/font/{fontstack}/{range}.pbf',
    sources: {
      basemap: { type: 'raster', tiles: bm.tiles, tileSize: 256, attribution: bm.attribution },
      states: { type: 'geojson', data: '/assets/us-states.geojson' },
      legality: {
        type: 'vector',
        tiles: [`${tileBaseUrl}/tiles.legality_polygons/{z}/{x}/{y}.pbf`],
        // Never fetched below the split (all its layers carry minzoom) — belt & braces.
        minzoom: LOWZOOM_SPLIT, maxzoom: 14,
      },
      legality_lowzoom: {
        type: 'vector',
        tiles: [`${tileBaseUrl}/tiles.legality_lowzoom/{z}/{x}/{y}.pbf`],
        minzoom: 0, maxzoom: LOWZOOM_SPLIT,
      },
      claims: {
        type: 'vector',
        tiles: [`${tileBaseUrl}/tiles.claims_polygons/{z}/{x}/{y}.pbf`],
        minzoom: 0, maxzoom: 14,
      },
      waterways: {
        type: 'vector',
        tiles: [`${tileBaseUrl}/tiles.waterways/{z}/{x}/{y}.pbf`],
        minzoom: 0, maxzoom: 14,
      },
      mrds: {
        type: 'vector',
        tiles: [`${tileBaseUrl}/tiles.mrds/{z}/{x}/{y}.pbf`],
        minzoom: 0, maxzoom: 14,
      },
      'mrds-hover': { type: 'geojson', data: emptyFC() },
      prospectivity: {
        type: 'vector',
        tiles: [`${tileBaseUrl}/tiles.prospectivity/{z}/{x}/{y}.pbf`],
        // Never rendered below the High gate (all its layers carry minzoom) — belt & braces,
        // and skips fetching tiles that could never draw.
        minzoom: PROSPECTIVITY_HIGH_MINZOOM, maxzoom: 14,
      },
      'prospectivity-hover': { type: 'geojson', data: emptyFC() },
      selected: { type: 'geojson', data: emptyFC() },
      pins: { type: 'geojson', data: emptyFC() },
    },
    layers: [
      { id: 'basemap', type: 'raster', source: 'basemap' },

      // Legality overlays, twice: generalized low-zoom set (z < LOWZOOM_SPLIT) + full-resolution
      // detail set (z >= LOWZOOM_SPLIT). Identical styling; only source + zoom band differ.
      ...legalityLayerSet('legality_lowzoom', LEGALITY_LOWZOOM_SRC_LAYER, '-lowzoom', { maxzoom: LOWZOOM_SPLIT }),
      ...legalityLayerSet('legality', LEGALITY_SRC_LAYER, '', { minzoom: LOWZOOM_SPLIT }),

      // Active mining claims (nightly tiles — empty until ingested; renders nothing if 404).
      {
        id: 'mining-claims', type: 'fill', source: 'claims', 'source-layer': CLAIMS_SRC_LAYER,
        minzoom: 9, layout: { visibility: 'none' },
        paint: { 'fill-color': '#FF8C00', 'fill-opacity': 0.35, 'fill-outline-color': '#CC6600' },
      },

      // Waterways (reference-only — CA streams; never feeds the verdict engine, §6.13).
      // 740k dense polylines: minzoom 10 keeps low zooms readable (cf. claims minzoom 9).
      {
        id: 'waterways', type: 'line', source: 'waterways', 'source-layer': WATERWAYS_SRC_LAYER,
        minzoom: 10, layout: { visibility: 'none', 'line-cap': 'round', 'line-join': 'round' },
        paint: {
          'line-color': '#2f6fb0',
          'line-opacity': 0.85,
          // taper width with zoom so dense networks stay legible
          'line-width': ['interpolate', ['linear'], ['zoom'], 10, 0.5, 14, 1.6, 17, 3],
        },
      },

      // Gold occurrences (reference-only — USGS MRDS, gold-filtered; never feeds the verdict
      // engine, §6.13). Points are dense in mining districts: minzoom 8 + small radius keeps it
      // legible. Past/producers rendered brighter + larger (the stronger prospecting signal).
      {
        id: 'mrds', type: 'circle', source: 'mrds', 'source-layer': MRDS_SRC_LAYER,
        minzoom: 8, layout: { visibility: 'none' },
        paint: {
          'circle-color': ['case', ['get', 'is_producer'], '#FFC64B', '#C79A3A'],
          'circle-radius': ['interpolate', ['linear'], ['zoom'],
            8, ['case', ['get', 'is_producer'], 3, 1.8],
            14, ['case', ['get', 'is_producer'], 7, 4.5]],
          'circle-stroke-color': '#4a3600',
          'circle-stroke-width': ['case', ['get', 'is_producer'], 1, 0.4],
          'circle-opacity': 0.9,
        },
      },

      // Hover highlight ring for gold dots (driven by a geojson source updated on mousemove).
      {
        id: 'mrds-hover', type: 'circle', source: 'mrds-hover',
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 8, 6, 14, 11],
          'circle-color': 'rgba(255,214,90,0.22)',
          'circle-stroke-color': '#FFD37A',
          'circle-stroke-width': 2,
        },
      },

      // Prospecting potential (reference-only computed composite, §5.3 / #41-#42 — never feeds
      // the verdict engine). Own glyph family, distinct from the MRDS gold dots, in a hotter
      // orange-red hue: filled star = High/producer-anchored, hollow star = High/chemistry-earned,
      // small diamond = Moderate. Zoom-gated per owner call #1 (High z7+, Moderate z10+).
      //
      // Fail-safe under-layers first (review finding F-5): a symbol layer renders NOTHING if its
      // image is missing — these subtle same-filter circles sit beneath the symbols so a sprite
      // failure degrades to visible dots instead of an invisible layer.
      {
        id: 'prospectivity-high-fallback', type: 'circle', source: 'prospectivity',
        'source-layer': PROSPECTIVITY_SRC_LAYER, minzoom: PROSPECTIVITY_HIGH_MINZOOM,
        filter: ['==', ['get', 'tier'], 'High'],
        layout: { visibility: 'none' },
        paint: {
          'circle-color': '#E8590C', 'circle-radius': 3, 'circle-opacity': 0.85,
          'circle-stroke-color': '#7A2E06', 'circle-stroke-width': 0.6,
        },
      },
      {
        id: 'prospectivity-moderate-fallback', type: 'circle', source: 'prospectivity',
        'source-layer': PROSPECTIVITY_SRC_LAYER, minzoom: PROSPECTIVITY_MODERATE_MINZOOM,
        filter: ['==', ['get', 'tier'], 'Moderate'],
        layout: { visibility: 'none' },
        paint: {
          'circle-color': '#F76707', 'circle-radius': 2.2, 'circle-opacity': 0.8,
          'circle-stroke-color': '#8A3D05', 'circle-stroke-width': 0.5,
        },
      },
      // The glyph symbols (images injected at runtime by MapView — makeProspectivityImages).
      {
        id: 'prospectivity-high-producer', type: 'symbol', source: 'prospectivity',
        'source-layer': PROSPECTIVITY_SRC_LAYER, minzoom: PROSPECTIVITY_HIGH_MINZOOM,
        filter: ['all', ['==', ['get', 'tier'], 'High'], ['==', ['get', 'tier_basis'], 'producer']],
        layout: {
          visibility: 'none', 'icon-image': 'prospect-star-filled',
          'icon-allow-overlap': true, 'icon-ignore-placement': true,
        },
      },
      {
        id: 'prospectivity-high-chemistry', type: 'symbol', source: 'prospectivity',
        'source-layer': PROSPECTIVITY_SRC_LAYER, minzoom: PROSPECTIVITY_HIGH_MINZOOM,
        filter: ['all', ['==', ['get', 'tier'], 'High'], ['==', ['get', 'tier_basis'], 'chemistry']],
        layout: {
          visibility: 'none', 'icon-image': 'prospect-star-hollow',
          'icon-allow-overlap': true, 'icon-ignore-placement': true,
        },
      },
      {
        id: 'prospectivity-moderate', type: 'symbol', source: 'prospectivity',
        'source-layer': PROSPECTIVITY_SRC_LAYER, minzoom: PROSPECTIVITY_MODERATE_MINZOOM,
        filter: ['==', ['get', 'tier'], 'Moderate'],
        layout: {
          visibility: 'none', 'icon-image': 'prospect-diamond',
          'icon-allow-overlap': true, 'icon-ignore-placement': true,
        },
      },

      // Hover highlight ring for prospectivity markers (same idiom as mrds-hover).
      {
        id: 'prospectivity-hover', type: 'circle', source: 'prospectivity-hover',
        paint: {
          'circle-radius': ['interpolate', ['linear'], ['zoom'], 7, 8, 14, 13],
          'circle-color': 'rgba(232,89,12,0.18)',
          'circle-stroke-color': '#FF8A50',
          'circle-stroke-width': 2,
        },
      },

      // Out-of-scope states mask (grey everything except the 8 supported).
      {
        id: 'out-of-scope-mask', type: 'fill', source: 'states',
        filter: ['!', ['in', ['get', 'STUSAB'], ['literal', SUPPORTED]]],
        paint: { 'fill-color': '#444444', 'fill-opacity': 0.55 },
      },

      // Saved pins + the temporary selected point.
      {
        id: 'pins', type: 'circle', source: 'pins',
        paint: {
          'circle-radius': 6, 'circle-color': '#2563eb',
          'circle-stroke-color': '#ffffff', 'circle-stroke-width': 2,
        },
      },
      {
        // The dropped click pin, colored by the assessment verdict (grey while loading /
        // out-of-region). White stroke keeps it visible over a same-colored overlay.
        id: 'selected', type: 'circle', source: 'selected',
        paint: {
          'circle-radius': 8,
          'circle-color': [
            'match', ['get', 'verdict'],
            'GREEN', '#2e9e4f',   // confirmed open
            'YELLOW', '#f59e0b',  // ambiguous / verify (amber)
            'RED', '#cc2200',     // prohibited
            /* loading / OUT_OF_REGION / unknown */ '#9aa0a6',
          ],
          'circle-stroke-color': '#ffffff', 'circle-stroke-width': 2,
        },
      },
    ],
  };
}

// The five legality overlay layers for one source/zoom band. `suffix` distinguishes the ids
// (''=detail, '-lowzoom'); MapView toggles both variants of each id.
function legalityLayerSet(
  source: string,
  srcLayer: string,
  suffix: string,
  zoom: { minzoom?: number; maxzoom?: number },
): StyleSpecification['layers'] {
  return [
    // Confirmed-open overlay (opt-in, default off). A slight green shading affirmatively marking
    // land confirmed open for casual collecting ("GREEN must be earned", §6.4.1). Drawn FIRST so
    // the red/grey overlays win where they overlap (e.g. CA confirm-open YELLOW over former-GREEN).
    {
      id: `legality-open${suffix}`, type: 'fill', source, 'source-layer': srcLayer, ...zoom,
      filter: ['==', ['get', 'verdict'], 'GREEN'],
      layout: { visibility: 'none' },
      paint: { 'fill-color': '#3FAE5A', 'fill-opacity': 0.22 },
    },
    // Legality overlays (filter on the baked `verdict`).
    {
      id: `legality-prohibited${suffix}`, type: 'fill', source, 'source-layer': srcLayer, ...zoom,
      filter: ['==', ['get', 'verdict'], 'RED'],
      paint: { 'fill-color': '#CC2200', 'fill-opacity': 0.45 },
    },
    {
      id: `legality-prohibited-outline${suffix}`, type: 'line', source, 'source-layer': srcLayer, ...zoom,
      filter: ['==', ['get', 'verdict'], 'RED'],
      paint: { 'line-color': '#991100', 'line-width': 1 },
    },
    // Fail-safe under-layer for YELLOW: a fill-pattern layer renders NOTHING if the 'hatch'
    // sprite is missing (fill-color is ignored when a pattern is set), which would silently
    // hide ambiguous land. This subtle grey-yellow tint sits beneath the hatch so a missing
    // sprite degrades to a visible wash instead of invisible.
    {
      id: `legality-ambiguous-base${suffix}`, type: 'fill', source, 'source-layer': srcLayer, ...zoom,
      filter: ['==', ['get', 'verdict'], 'YELLOW'],
      paint: { 'fill-color': '#B0A44E', 'fill-opacity': 0.18 },
    },
    {
      id: `legality-ambiguous${suffix}`, type: 'fill', source, 'source-layer': srcLayer, ...zoom,
      filter: ['==', ['get', 'verdict'], 'YELLOW'],
      paint: { 'fill-pattern': 'hatch', 'fill-opacity': 0.6 },
    },
    // Fail-safe catch-all: any baked verdict outside the known enum is a data bug — paint it
    // loud magenta so it can never render as silent blank "open-looking" land.
    {
      id: `legality-unknown-verdict${suffix}`, type: 'fill', source, 'source-layer': srcLayer, ...zoom,
      filter: ['!', ['in', ['get', 'verdict'], ['literal', ['RED', 'YELLOW', 'GREEN']]]],
      paint: { 'fill-color': '#FF00CC', 'fill-opacity': 0.5 },
    },
  ];
}

export function emptyFC(): FeatureCollection {
  return { type: 'FeatureCollection', features: [] };
}

export function pointFC(points: { lat: number; lng: number; props?: Record<string, unknown> }[]): FeatureCollection {
  return {
    type: 'FeatureCollection',
    features: points.map((p) => ({
      type: 'Feature',
      geometry: { type: 'Point', coordinates: [p.lng, p.lat] },
      properties: p.props ?? {},
    })),
  };
}

// Prospectivity glyphs (owner call #2/#6): canvas-drawn at 2x, registered with pixelRatio 2 by
// MapView on 'load' + 'styleimagemissing' (the makeHatch/ensureHatch idiom). Rendered sizes:
// ~18px stars (filled = producer-anchored High, hollow = chemistry-earned High), ~12px diamond
// (Moderate). Hue family around #E8590C — hotter than the MRDS gold dots by design.
export const PROSPECTIVITY_IMAGES: Record<string, () => { width: number; height: number; data: Uint8Array }> = {
  'prospect-star-filled': () => makeStar(true),
  'prospect-star-hollow': () => makeStar(false),
  'prospect-diamond': makeDiamond,
};

function makeStar(filled: boolean): { width: number; height: number; data: Uint8Array } {
  const size = 36; // 2x → renders ~18px
  const canvas = document.createElement('canvas');
  canvas.width = size; canvas.height = size;
  const ctx = canvas.getContext('2d')!;
  const cx = size / 2, cy = size / 2, outer = size / 2 - 4, inner = outer * 0.45;
  ctx.beginPath();
  for (let i = 0; i < 10; i++) {
    const r = i % 2 === 0 ? outer : inner;
    const a = -Math.PI / 2 + (i * Math.PI) / 5;
    const x = cx + r * Math.cos(a), y = cy + r * Math.sin(a);
    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
  }
  ctx.closePath();
  ctx.lineJoin = 'round';
  if (filled) {
    ctx.fillStyle = '#E8590C';
    ctx.fill();
    ctx.strokeStyle = '#7A2E06'; ctx.lineWidth = 2; ctx.stroke();
  } else {
    // Hollow/outlined variant — same size + hue family as the filled star.
    ctx.strokeStyle = '#E8590C'; ctx.lineWidth = 3.5; ctx.stroke();
  }
  const img = ctx.getImageData(0, 0, size, size);
  return { width: size, height: size, data: new Uint8Array(img.data) };
}

function makeDiamond(): { width: number; height: number; data: Uint8Array } {
  const size = 24; // 2x → renders ~12px
  const canvas = document.createElement('canvas');
  canvas.width = size; canvas.height = size;
  const ctx = canvas.getContext('2d')!;
  const cx = size / 2, cy = size / 2, m = 3;
  ctx.beginPath();
  ctx.moveTo(cx, m); ctx.lineTo(size - m, cy); ctx.lineTo(cx, size - m); ctx.lineTo(m, cy);
  ctx.closePath();
  ctx.fillStyle = '#F76707';
  ctx.fill();
  ctx.strokeStyle = '#8A3D05'; ctx.lineWidth = 1.5; ctx.stroke();
  const img = ctx.getImageData(0, 0, size, size);
  return { width: size, height: size, data: new Uint8Array(img.data) };
}

// 12px diagonal cross-hatch sprite for the "ambiguous" fill (MapLibre has no native hatch).
export function makeHatch(): { width: number; height: number; data: Uint8Array } {
  const size = 12;
  const canvas = document.createElement('canvas');
  canvas.width = size; canvas.height = size;
  const ctx = canvas.getContext('2d')!;
  ctx.strokeStyle = 'rgba(120,120,120,0.85)';
  ctx.lineWidth = 1.5;
  ctx.beginPath();
  ctx.moveTo(0, size); ctx.lineTo(size, 0);
  ctx.moveTo(-size / 2, size / 2); ctx.lineTo(size / 2, -size / 2);
  ctx.moveTo(size / 2, size * 1.5); ctx.lineTo(size * 1.5, size / 2);
  ctx.stroke();
  const img = ctx.getImageData(0, 0, size, size);
  return { width: size, height: size, data: new Uint8Array(img.data) };
}
