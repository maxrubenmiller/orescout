import { useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { useUI } from '../store';
import { usePins, useActiveAssessment } from '../hooks';
import {
  basemapTiles, buildStyle, emptyFC, makeHatch, pointFC,
  PROSPECTIVITY_IMAGES, PROSPECTIVITY_LAYER_IDS,
} from '../map/style';
// Per-commodity strings (pathfinder "why" blurb, chemistry-earned line, upstream note, vintage
// note) render from config keyed by the feature's `commodity` — never hardcoded in components,
// never duplicated per tile feature (TIER_B brief, architecture clarifications).
import prospectivityConfig from '../../../config/prospectivity.json';

interface CommodityStrings {
  pathfinder_blurb: string; chemistry_earned: string; upstream_note: string; vintage_note: string;
}
const commodityStrings = (key: unknown): CommodityStrings | null =>
  prospectivityConfig.commodities.find((c) => c.key === key)?.strings ?? null;

export default function MapView() {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const loadedRef = useRef(false);
  // Fail-loud on overlay tile failures (IMP-07): a failed legality/claims tile means restricted
  // land silently renders as blank/open-looking — surface it instead of swallowing it.
  const [tileError, setTileError] = useState(false);

  const assess = useUI((s) => s.assess);
  const flyTarget = useUI((s) => s.flyTarget);
  const layers = useUI((s) => s.layers);
  const basemap = useUI((s) => s.basemap);
  const selectedPoint = useUI((s) => s.selectedPoint);
  const viewedPinId = useUI((s) => s.viewedPinId);
  const { data: pins } = usePins();
  // Same resolver the panel uses (React Query dedupes by key) — drives the pin's verdict
  // color. For a viewed saved pin this is the SNAPSHOT verdict, not a fresh live one.
  const active = useActiveAssessment(selectedPoint, viewedPinId);
  const selectedVerdict = active.display?.collectingStatus ?? 'LOADING';

  // Create the map once.
  useEffect(() => {
    if (!containerRef.current) return;
    const map = new maplibregl.Map({
      container: containerRef.current,
      style: buildStyle(useUI.getState().basemap),
      center: [-117, 39],
      zoom: 6,
    });
    mapRef.current = map;
    if (import.meta.env.DEV) (window as unknown as { __map: maplibregl.Map }).__map = map;
    map.addControl(new maplibregl.NavigationControl(), 'bottom-right');

    const ensureHatch = () => { if (!map.hasImage('hatch')) map.addImage('hatch', makeHatch()); };
    // Prospectivity glyphs, registered on BOTH 'load' and 'styleimagemissing' (F-5): if they ever
    // fail anyway, the symbol layers draw nothing and the fallback circles beneath still show.
    const ensureProspectivityImages = () => {
      for (const [id, make] of Object.entries(PROSPECTIVITY_IMAGES)) {
        if (!map.hasImage(id)) map.addImage(id, make(), { pixelRatio: 2 });
      }
    };
    map.on('styleimagemissing', (e) => {
      if (e.id === 'hatch') ensureHatch();
      if (e.id in PROSPECTIVITY_IMAGES) ensureProspectivityImages();
    });
    map.on('load', () => { ensureHatch(); ensureProspectivityImages(); loadedRef.current = true; });

    // Overlay tile failures (pg_tileserv 5xx/timeouts) must not be silent — the failure mode is
    // RED/YELLOW land rendering as blank. Basemap raster errors are excluded (third-party, and
    // the map visibly greys without them anyway).
    map.on('error', (e) => {
      const src = (e as { sourceId?: string }).sourceId;
      if (src && src !== 'basemap' && src !== 'states') setTileError(true);
    });

    // MRDS gold-occurrence reference popup + hover. Dots are small (2–5px), and maplibre's
    // exact-point hit-test needs a near-dead-center click — so hit-test a TOLERANCE BOX around the
    // cursor instead (that's the fix for "dots don't respond to clicks"). site_name/url are
    // external data → escape before injecting as HTML.
    const esc = (s: unknown) => String(s ?? '')
      .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    const HIT = 8; // px click/hover tolerance around a dot
    const coordsOf = (f: maplibregl.MapGeoJSONFeature): [number, number] | null =>
      f.geometry.type === 'Point' ? (f.geometry.coordinates as [number, number]) : null;
    const layerVisible = (id: string) => !!map.getLayer(id) && map.getLayoutProperty(id, 'visibility') !== 'none';
    // Tolerance-box hit-test, generic over point layers (missing layers filtered out —
    // queryRenderedFeatures throws on unknown layer ids).
    const nearestIn = (pt: maplibregl.Point, layerIds: string[]): maplibregl.MapGeoJSONFeature | null => {
      const layers = layerIds.filter((id) => map.getLayer(id));
      if (layers.length === 0) return null;
      const fs = map.queryRenderedFeatures([[pt.x - HIT, pt.y - HIT], [pt.x + HIT, pt.y + HIT]], { layers });
      let best: maplibregl.MapGeoJSONFeature | null = null, bd = Infinity;
      for (const f of fs) {
        const c = coordsOf(f); if (!c) continue;
        const p = map.project(c); const d = (p.x - pt.x) ** 2 + (p.y - pt.y) ** 2;
        if (d < bd) { bd = d; best = f; }
      }
      return best;
    };
    const nearestMrds = (pt: maplibregl.Point): maplibregl.MapGeoJSONFeature | null =>
      layerVisible('mrds') ? nearestIn(pt, ['mrds']) : null;
    // Hit-test the whole prospectivity set — symbols plus the F-5 fallback circles, so markers
    // stay clickable even if the glyph images failed to register.
    const nearestProspect = (pt: maplibregl.Point): maplibregl.MapGeoJSONFeature | null =>
      layerVisible('prospectivity-high-producer') ? nearestIn(pt, PROSPECTIVITY_LAYER_IDS) : null;
    // closeOnClick:false — opening a popup with closeOnClick inside a click handler self-closes on
    // the same event in maplibre; we manage dismissal ourselves.
    const mrdsPopup = new maplibregl.Popup({ closeButton: true, closeOnClick: false, maxWidth: '260px' });
    const prospectPopup = new maplibregl.Popup({ closeButton: true, closeOnClick: false, maxWidth: '280px' });

    // Prospecting-potential popup (contract: tier headline, anomaly line, pathfinders, the
    // pathfinder "why" blurb, producer line, chemistry-earned line, upstream note, vintage —
    // static per-commodity strings from config/prospectivity.json, dynamic values from the tile).
    const prospectHtml = (p: Record<string, unknown>): string => {
      const strings = commodityStrings(p.commodity);
      const chem = p.tier_basis === 'chemistry';
      const headline = p.tier === 'High' ? 'High potential' : 'Moderate potential';
      const pctl = Math.round(Number(p.anomaly_pctl) * 100);
      const km = p.producer_dist_m == null ? null : (Number(p.producer_dist_m) / 1000).toFixed(1);
      return (
        `<div class="prospect-pop"><strong>${headline}${chem ? ' · chemistry-earned' : ''}</strong>` +
        `<div class="prospect-anom">${esc(p.anomaly_element)} anomaly — p${pctl} in its watershed</div>` +
        (p.pathfinders ? `<div class="prospect-path">Co-elevated: ${esc(p.pathfinders)}</div>` : '') +
        (strings ? `<div class="prospect-why">${esc(strings.pathfinder_blurb)}</div>` : '') +
        (p.producer_name
          ? `<div class="prospect-prod">${esc(p.producer_name)} — historic producer ${km ?? '?'} km away</div>` : '') +
        (chem && strings ? `<div class="prospect-chem">${esc(strings.chemistry_earned)}</div>` : '') +
        (strings ? `<div class="prospect-note">${esc(strings.upstream_note)}</div>` : '') +
        `<div class="prospect-vintage">${esc(p.data_vintage)}</div></div>`
      );
    };

    map.on('click', (e) => {
      // Prospectivity first — its symbols render above the MRDS dots, so it wins the click.
      const prospect = nearestProspect(e.point);
      const pc = prospect && coordsOf(prospect);
      const gold = prospect && pc ? null : nearestMrds(e.point);
      const c = gold && coordsOf(gold);
      if (prospect && pc) {
        mrdsPopup.remove();
        prospectPopup.setLngLat(pc).setHTML(prospectHtml(prospect.properties ?? {})).addTo(map);
      } else if (gold && c) {
        prospectPopup.remove();
        const p = gold.properties ?? {};
        const grade = esc(p.grade);
        const url = esc(p.url); // escaped for the href="" attribute (& → &amp;, decoded on navigate)
        mrdsPopup.setLngLat(c).setHTML(
          `<div class="mrds-pop"><strong>${esc(p.site_name) || 'Unnamed site'}</strong>` +
          `<div class="mrds-stat">${esc(p.dev_stat) || '—'}${grade ? ` · grade ${grade}` : ''}</div>` +
          `<div class="mrds-comm">Commodities: ${esc(p.commodities) || '—'}</div>` +
          (url ? `<a class="mrds-link" href="${url}" target="_blank" rel="noopener noreferrer">Full USGS record →</a>` : '') +
          `<div class="mrds-note">Historic USGS MRDS record (pre-2011) — not current.</div></div>`,
        ).addTo(map);
      } else {
        mrdsPopup.remove();
        prospectPopup.remove();
      }
      // Core interaction is preserved: every click still assesses the spot (the popups are additive).
      assess({ lat: e.lngLat.lat, lng: e.lngLat.lng });
    });

    // Hover affordance: pointer cursor + a highlight ring when the cursor is near a marker
    // (prospectivity takes precedence, matching the click priority).
    map.on('mousemove', (e) => {
      const prospect = nearestProspect(e.point);
      const pc = prospect ? coordsOf(prospect) : null;
      const gold = pc ? null : nearestMrds(e.point);
      const c = gold ? coordsOf(gold) : null;
      map.getCanvas().style.cursor = pc || c ? 'pointer' : '';
      (map.getSource('mrds-hover') as maplibregl.GeoJSONSource | undefined)
        ?.setData(c ? pointFC([{ lng: c[0], lat: c[1] }]) : emptyFC());
      (map.getSource('prospectivity-hover') as maplibregl.GeoJSONSource | undefined)
        ?.setData(pc ? pointFC([{ lng: pc[0], lat: pc[1] }]) : emptyFC());
    });

    return () => { map.remove(); mapRef.current = null; loadedRef.current = false; };
  }, [assess]);

  // Fly-to requests.
  useEffect(() => {
    if (!flyTarget || !mapRef.current) return;
    mapRef.current.flyTo({ center: [flyTarget.lng, flyTarget.lat], zoom: flyTarget.zoom ?? 12 });
  }, [flyTarget]);

  // Layer visibility toggles.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const apply = () => {
      const v = (id: string, on: boolean) =>
        map.getLayer(id) && map.setLayoutProperty(id, 'visibility', on ? 'visible' : 'none');
      // Each legality layer exists twice: detail ('') + generalized low-zoom ('-lowzoom').
      for (const sfx of ['', '-lowzoom']) {
        v(`legality-open${sfx}`, layers.open);
        v(`legality-prohibited${sfx}`, layers.prohibited);
        v(`legality-prohibited-outline${sfx}`, layers.prohibited);
        v(`legality-ambiguous-base${sfx}`, layers.ambiguous);
        v(`legality-ambiguous${sfx}`, layers.ambiguous);
      }
      v('mining-claims', layers.claims);
      v('waterways', layers.waterways);
      v('mrds', layers.mrds);
      // ALL prospectivity layers — symbols + their F-5 fallback circles.
      for (const id of PROSPECTIVITY_LAYER_IDS) v(id, layers.prospectivity);
    };
    if (loadedRef.current) apply(); else map.once('load', apply);
  }, [layers]);

  // Basemap switch.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const src = map.getSource('basemap') as maplibregl.RasterTileSource | undefined;
    if (src) src.setTiles(basemapTiles(basemap).tiles);
  }, [basemap]);

  // Saved pins -> geojson source.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const data = pointFC((pins ?? []).map((p) => ({ lat: p.lat, lng: p.lng, props: { id: p.id } })));
    const set = () => (map.getSource('pins') as maplibregl.GeoJSONSource | undefined)?.setData(data);
    if (loadedRef.current) set(); else map.once('load', set);
  }, [pins]);

  // Selected point marker.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const data = selectedPoint
      ? pointFC([{ ...selectedPoint, props: { verdict: selectedVerdict } }])
      : emptyFC();
    const set = () => (map.getSource('selected') as maplibregl.GeoJSONSource | undefined)?.setData(data);
    if (loadedRef.current) set(); else map.once('load', set);
  }, [selectedPoint, selectedVerdict]);

  return (
    <div ref={containerRef} className="map-root">
      {tileError && (
        <div className="map-tile-error" role="alert">
          ⚠ Some map overlay data failed to load — areas may be missing their red/grey shading.
          Zoom or pan to retry.
          <button onClick={() => setTileError(false)} aria-label="Dismiss">✕</button>
        </div>
      )}
    </div>
  );
}
