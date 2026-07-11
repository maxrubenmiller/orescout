import { useEffect, useRef, useState } from 'react';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { useUI } from '../store';
import { usePins, useActiveAssessment } from '../hooks';
import { basemapTiles, buildStyle, emptyFC, makeHatch, pointFC } from '../map/style';

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
    map.on('styleimagemissing', (e) => { if (e.id === 'hatch') ensureHatch(); });
    map.on('load', () => { ensureHatch(); loadedRef.current = true; });

    // Overlay tile failures (pg_tileserv 5xx/timeouts) must not be silent — the failure mode is
    // RED/YELLOW land rendering as blank. Basemap raster errors are excluded (third-party, and
    // the map visibly greys without them anyway).
    map.on('error', (e) => {
      const src = (e as { sourceId?: string }).sourceId;
      if (src && src !== 'basemap' && src !== 'states') setTileError(true);
    });

    // Gold-occurrence reference popup (MRDS). Defined before the click handler so a plain map
    // click can dismiss it. site_name is external data → escape before injecting as HTML.
    const esc = (s: unknown) => String(s ?? '')
      .replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;');
    // closeOnClick:false — opening a popup with closeOnClick inside a click handler self-closes on
    // the same event in maplibre; we dismiss it explicitly on a non-gold click instead.
    const mrdsPopup = new maplibregl.Popup({ closeButton: true, closeOnClick: false, maxWidth: '260px' });

    map.on('click', (e) => {
      assess({ lat: e.lngLat.lat, lng: e.lngLat.lng });
      // A plain map click (not on a gold dot) dismisses any open MRDS popup.
      const onGold = !!map.getLayer('mrds') && map.queryRenderedFeatures(e.point, { layers: ['mrds'] }).length > 0;
      if (!onGold) mrdsPopup.remove();
    });

    // Clicking a gold dot shows its historic record (assess still fires above, additively).
    map.on('click', 'mrds', (e) => {
      const p = e.features?.[0]?.properties ?? {};
      const grade = esc(p.grade);
      const url = esc(p.url); // escaped for the href="" attribute (& → &amp;, decoded on navigate)
      mrdsPopup.setLngLat(e.lngLat).setHTML(
        `<div class="mrds-pop"><strong>${esc(p.site_name) || 'Unnamed site'}</strong>` +
        `<div class="mrds-stat">${esc(p.dev_stat) || '—'}${grade ? ` · grade ${grade}` : ''}</div>` +
        `<div class="mrds-comm">Commodities: ${esc(p.commodities) || '—'}</div>` +
        (url ? `<a class="mrds-link" href="${url}" target="_blank" rel="noopener noreferrer">Full USGS record →</a>` : '') +
        `<div class="mrds-note">Historic USGS MRDS record (pre-2011) — not current.</div></div>`,
      ).addTo(map);
    });
    map.on('mouseenter', 'mrds', () => { map.getCanvas().style.cursor = 'pointer'; });
    map.on('mouseleave', 'mrds', () => { map.getCanvas().style.cursor = ''; });

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
