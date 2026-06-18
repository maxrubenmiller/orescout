import { useState } from 'react';
import { useUI } from '../store';
import { usePins } from '../hooks';
import { api } from '../api';
import { parseCoordinates } from '../coords';

export default function SearchBar() {
  const [q, setQ] = useState('');
  const [msg, setMsg] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const flyTo = useUI((s) => s.flyTo);
  const assess = useUI((s) => s.assess);
  const { data: pins } = usePins();

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault();
    const query = q.trim();
    if (!query) return;
    setMsg(null);

    // 1) Coordinates (decimal or DMS) -> fly + assess.
    const coord = parseCoordinates(query);
    if (coord) { flyTo(coord.lat, coord.lng, 12); assess(coord); return; }

    // 2) Saved-pin title match.
    const pin = pins?.find((p) => p.title.toLowerCase().includes(query.toLowerCase()));
    if (pin) { flyTo(pin.lat, pin.lng, 13); assess({ lat: pin.lat, lng: pin.lng }); return; }

    // 3) Geocode (address / place name).
    setBusy(true);
    try {
      const { results } = await api.geocode(query);
      if (results.length === 0) { setMsg('No matches found.'); return; }
      flyTo(results[0].lat, results[0].lng, 11);
    } catch {
      setMsg('Search failed.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <form className="search" onSubmit={onSubmit}>
      <input
        value={q}
        onChange={(e) => setQ(e.target.value)}
        placeholder="Search a place, or paste coordinates…"
        aria-label="Search"
      />
      <button className="btn" disabled={busy}>{busy ? '…' : 'Go'}</button>
      {msg && <span className="search-msg">{msg}</span>}
    </form>
  );
}
