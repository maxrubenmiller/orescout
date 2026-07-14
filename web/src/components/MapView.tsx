import { useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { useUI } from '../store';
import { usePins, useActiveAssessment, useMeta } from '../hooks';
import {
  basemapTiles, buildStyle, emptyFC, makeChevron, makeHatch, outOfScopeMaskFilter, pointFC,
  PROSPECTIVITY_IMAGES, PROSPECTIVITY_LAYER_IDS,
} from '../map/style';

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
  const marker = useUI((s) => s.marker);
  const { data: pins } = usePins();
  // Authoritative supported-state list for the out-of-scope grey mask (§6.13: the list lives in
  // the API's /meta, never hardcoded in the frontend). The map is created once, so we (re)apply the
  // mask filter whenever /meta resolves or changes.
  const { data: meta } = useMeta();
  const supportedStates = meta?.supportedStates;
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
    const ensureChevron = () => { if (!map.hasImage('waterway-chevron')) map.addImage('waterway-chevron', makeChevron(), { pixelRatio: 2 }); };
    // Prospectivity glyphs, registered on BOTH 'load' and 'styleimagemissing' (F-5): if they ever
    // fail anyway, the symbol layers draw nothing and the fallback circles beneath still show.
    const ensureProspectivityImages = () => {
      for (const [id, make] of Object.entries(PROSPECTIVITY_IMAGES)) {
        if (!map.hasImage(id)) map.addImage(id, make(), { pixelRatio: 2 });
      }
    };
    map.on('styleimagemissing', (e) => {
      if (e.id === 'hatch') ensureHatch();
      if (e.id === 'waterway-chevron') ensureChevron();
      if (e.id in PROSPECTIVITY_IMAGES) ensureProspectivityImages();
    });
    map.on('load', () => { ensureHatch(); ensureChevron(); ensureProspectivityImages(); loadedRef.current = true; });

    // Overlay tile failures (pg_tileserv 5xx/timeouts) must not be silent — the failure mode is
    // RED/YELLOW land rendering as blank. Basemap raster errors are excluded (third-party, and
    // the map visibly greys without them anyway).
    map.on('error', (e) => {
      const src = (e as { sourceId?: string }).sourceId;
      if (src && src !== 'basemap' && src !== 'states') setTileError(true);
    });

    // Reference-marker hit-testing (gold MRDS + prospectivity). Dots are small (2–5px) and maplibre's
    // exact-point hit-test needs a near-dead-center click — so hit-test a TOLERANCE BOX around the
    // cursor. Click details render in the assessment panel (React); hover shows a highlight ring.
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
    map.on('click', (e) => {
      // Find the reference markers under the click — both independently, since a gold occurrence and
      // a prospectivity site can share a spot. Details render in the assessment panel (not a popup);
      // the clicked marker's location drives the persistent highlight ring.
      const prospect = nearestProspect(e.point);
      const gold = nearestMrds(e.point);
      const pc = prospect ? coordsOf(prospect) : null;
      const gc = gold ? coordsOf(gold) : null;
      const point = pc ?? gc; // [lng, lat] of the clicked marker (prospectivity wins the tie)
      const markerSel = point
        ? {
            prospectivity: prospect ? (prospect.properties ?? {}) : null,
            mrds: gold ? (gold.properties ?? {}) : null,
            point: { lat: point[1], lng: point[0] },
          }
        : null;
      // Every click still assesses the spot. When a marker was hit, its details show above the
      // assessment and the dropped cursor pin is suppressed (the ring is the indicator instead).
      assess({ lat: e.lngLat.lat, lng: e.lngLat.lng }, markerSel);
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
      // Waterways: master toggle gates the layer; each flow-class sub-toggle gates its line + arrows.
      v('waterways-perennial', layers.waterways && layers.waterwaysPerennial);
      v('waterways-perennial-arrows', layers.waterways && layers.waterwaysPerennial);
      v('waterways-intermittent', layers.waterways && layers.waterwaysIntermittent);
      v('waterways-intermittent-arrows', layers.waterways && layers.waterwaysIntermittent);
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

  // Out-of-scope grey mask: the map is created before /meta resolves (mask greys nothing until
  // then), so (re)apply the filter from the authoritative supported-state list once it arrives.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const apply = () => map.setFilter('out-of-scope-mask', outOfScopeMaskFilter(supportedStates ?? []));
    if (loadedRef.current) apply(); else map.once('load', apply);
  }, [supportedStates]);

  // Saved pins -> geojson source.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const data = pointFC((pins ?? []).map((p) => ({ lat: p.lat, lng: p.lng, props: { id: p.id } })));
    const set = () => (map.getSource('pins') as maplibregl.GeoJSONSource | undefined)?.setData(data);
    if (loadedRef.current) set(); else map.once('load', set);
  }, [pins]);

  // Selected point marker — the dropped verdict pin. Suppressed when the click hit a reference
  // marker (`marker` set): the persistent highlight ring is the indicator there, not a stacked pin.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const data = selectedPoint && !marker
      ? pointFC([{ ...selectedPoint, props: { verdict: selectedVerdict } }])
      : emptyFC();
    const set = () => (map.getSource('selected') as maplibregl.GeoJSONSource | undefined)?.setData(data);
    if (loadedRef.current) set(); else map.once('load', set);
  }, [selectedPoint, selectedVerdict, marker]);

  // Persistent highlight ring on the selected reference marker — stays while its details are in the
  // panel (independent of the transient hover ring), cleared when `marker` is null.
  useEffect(() => {
    const map = mapRef.current;
    if (!map) return;
    const data = marker ? pointFC([marker.point]) : emptyFC();
    const set = () => (map.getSource('selected-marker') as maplibregl.GeoJSONSource | undefined)?.setData(data);
    if (loadedRef.current) set(); else map.once('load', set);
  }, [marker]);

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
