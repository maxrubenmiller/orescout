import { useEffect, useRef } from 'react';
import maplibregl from 'maplibre-gl';
import 'maplibre-gl/dist/maplibre-gl.css';
import { useUI } from '../store';
import { usePins, useActiveAssessment } from '../hooks';
import { basemapTiles, buildStyle, emptyFC, makeHatch, pointFC } from '../map/style';

export default function MapView() {
  const containerRef = useRef<HTMLDivElement>(null);
  const mapRef = useRef<maplibregl.Map | null>(null);
  const loadedRef = useRef(false);

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

    map.on('click', (e) => {
      assess({ lat: e.lngLat.lat, lng: e.lngLat.lng });
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
      v('legality-open', layers.open);
      v('legality-prohibited', layers.prohibited);
      v('legality-prohibited-outline', layers.prohibited);
      v('legality-ambiguous', layers.ambiguous);
      v('mining-claims', layers.claims);
      v('waterways', layers.waterways);
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

  return <div ref={containerRef} className="map-root" />;
}
