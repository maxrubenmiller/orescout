import { useUI, type Basemap } from '../store';
import { usePins, useDeletePin } from '../hooks';
import { api } from '../api';
import type { Pin } from '../types';

export default function LeftPanel() {
  const open = useUI((s) => s.leftPanelOpen);
  const tab = useUI((s) => s.leftTab);
  const setTab = useUI((s) => s.setLeftTab);
  if (!open) return null;

  return (
    <aside className="panel left">
      <div className="tabs">
        <button className={tab === 'layers' ? 'tab active' : 'tab'} onClick={() => setTab('layers')}>Layers</button>
        <button className={tab === 'pins' ? 'tab active' : 'tab'} onClick={() => setTab('pins')}>My Pins</button>
      </div>
      <div className="panel-body">{tab === 'layers' ? <Layers /> : <Pins />}</div>
    </aside>
  );
}

function Layers() {
  const layers = useUI((s) => s.layers);
  const toggle = useUI((s) => s.toggleLayer);
  const basemap = useUI((s) => s.basemap);
  const setBasemap = useUI((s) => s.setBasemap);

  return (
    <div className="layers">
      <section>
        <h4>Legality overlay</h4>
        <label className="chk"><input type="checkbox" checked={layers.prohibited} onChange={() => toggle('prohibited')} /> <span className="sw sw-red" /> Prohibited (red)</label>
        <label className="chk"><input type="checkbox" checked={layers.ambiguous} onChange={() => toggle('ambiguous')} /> <span className="sw sw-hatch" /> Ambiguous (grey)</label>
        <label className="chk"><input type="checkbox" checked={layers.open} onChange={() => toggle('open')} /> <span className="sw sw-open" /> Confirmed open (green)</label>
        <p className="hint">Green = confirmed open for casual collecting (opt-in). No overlay = open or unknown. A decision-support tool, not legal advice.</p>
      </section>
      <section>
        <h4>Data layers</h4>
        <label className="chk">
          <input type="checkbox" checked={layers.claims} onChange={() => toggle('claims')} /> <span className="sw sw-claims" /> Active mining claims
        </label>
        <p className="hint">Orange = recorded BLM claims (zoom to ~9+ to see them). Also listed per-location when you click the map.</p>
        <label className="chk">
          <input type="checkbox" checked={layers.waterways} onChange={() => toggle('waterways')} /> <span className="sw sw-water" /> Waterways (CA)
        </label>
        <p className="hint">Blue = streams &amp; rivers (zoom to ~10+). Reference only — does not affect the legality verdict.</p>
      </section>
      <section>
        <h4>Base map</h4>
        {(['satellite', 'topo', 'street'] as Basemap[]).map((b) => (
          <label className="chk" key={b}>
            <input type="radio" name="basemap" checked={basemap === b} onChange={() => setBasemap(b)} /> {b[0].toUpperCase() + b.slice(1)}
          </label>
        ))}
      </section>
    </div>
  );
}

function Pins() {
  const { data: pins, isLoading } = usePins();
  const flyTo = useUI((s) => s.flyTo);
  const viewPin = useUI((s) => s.viewPin);
  const del = useDeletePin();

  if (isLoading) return <p className="muted">Loading…</p>;
  if (!pins || pins.length === 0) return <p className="muted">No saved pins yet. Click the map and “Save this location”.</p>;

  // Open the saved pin = show its stored snapshot (+ drift check), NOT a fresh assessment.
  const goTo = (p: Pin) => { flyTo(p.lat, p.lng, 13); viewPin(p.id, { lat: p.lat, lng: p.lng }); };

  const exportGpx = async (p: Pin) => {
    const blob = await api.exportPin(p.id);
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = `${p.title.replace(/[^a-z0-9]+/gi, '_')}.gpx`; a.click();
    URL.revokeObjectURL(url);
  };

  return (
    <ul className="pin-list">
      {pins.map((p) => (
        <li key={p.id}>
          <button className="pin-main" onClick={() => goTo(p)}>
            <span className="pin-title">{p.title}</span>
            <span className="pin-tags">{p.tags.map((t) => <span key={t} className="tag">{t}</span>)}</span>
            <span className="pin-sub">{p.status === 'visited' ? 'Visited' : 'Want to visit'} · {p.lat.toFixed(4)}, {p.lng.toFixed(4)}</span>
          </button>
          <div className="pin-actions">
            <button className="btn small" onClick={() => exportGpx(p)}>GPX</button>
            <button className="btn small danger" onClick={() => del.mutate(p.id)}>Delete</button>
          </div>
        </li>
      ))}
    </ul>
  );
}
