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
export const CLAIMS_SRC_LAYER = 'tiles.claims_polygons';
export const WATERWAYS_SRC_LAYER = 'tiles.waterways';

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
        minzoom: 0, maxzoom: 14,
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
      selected: { type: 'geojson', data: emptyFC() },
      pins: { type: 'geojson', data: emptyFC() },
    },
    layers: [
      { id: 'basemap', type: 'raster', source: 'basemap' },

      // Confirmed-open overlay (opt-in, default off). A slight green shading affirmatively marking
      // land confirmed open for casual collecting ("GREEN must be earned", §6.4.1). Drawn FIRST so
      // the red/grey overlays win where they overlap (e.g. CA confirm-open YELLOW over former-GREEN).
      {
        id: 'legality-open', type: 'fill', source: 'legality', 'source-layer': LEGALITY_SRC_LAYER,
        filter: ['==', ['get', 'verdict'], 'GREEN'],
        layout: { visibility: 'none' },
        paint: { 'fill-color': '#3FAE5A', 'fill-opacity': 0.22 },
      },

      // Legality overlays (filter on the baked `verdict`).
      {
        id: 'legality-prohibited', type: 'fill', source: 'legality', 'source-layer': LEGALITY_SRC_LAYER,
        filter: ['==', ['get', 'verdict'], 'RED'],
        paint: { 'fill-color': '#CC2200', 'fill-opacity': 0.45 },
      },
      {
        id: 'legality-prohibited-outline', type: 'line', source: 'legality', 'source-layer': LEGALITY_SRC_LAYER,
        filter: ['==', ['get', 'verdict'], 'RED'],
        paint: { 'line-color': '#991100', 'line-width': 1 },
      },
      {
        id: 'legality-ambiguous', type: 'fill', source: 'legality', 'source-layer': LEGALITY_SRC_LAYER,
        filter: ['==', ['get', 'verdict'], 'YELLOW'],
        paint: { 'fill-pattern': 'hatch', 'fill-opacity': 0.6 },
      },

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
