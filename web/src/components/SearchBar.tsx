import { useEffect, useMemo, useRef, useState } from 'react';
import { useUI } from '../store';
import { usePins, useGeocode } from '../hooks';
import { parseCoordinates } from '../coords';

/** Returns `value` after it has stopped changing for `ms` (debounce). */
function useDebounced<T>(value: T, ms: number): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

type Item =
  | { kind: 'coord'; label: string; lat: number; lng: number }
  | { kind: 'pin'; label: string; lat: number; lng: number }
  | { kind: 'geo'; label: string; lat: number; lng: number };

const ICON: Record<Item['kind'], string> = { coord: '📍', pin: '📌', geo: '🔎' };
const KIND_LABEL: Record<Item['kind'], string> = { coord: 'coordinates', pin: 'saved pin', geo: 'place' };

export default function SearchBar() {
  const [q, setQ] = useState('');
  const [open, setOpen] = useState(false);
  const [active, setActive] = useState(0);
  const [hint, setHint] = useState<string | null>(null);
  const boxRef = useRef<HTMLDivElement>(null);

  const flyTo = useUI((s) => s.flyTo);
  const assess = useUI((s) => s.assess);
  const { data: pins } = usePins();

  // Coordinates resolve instantly (no upstream call); everything else is debounced.
  const coord = useMemo(() => parseCoordinates(q.trim()), [q]);
  const dq = useDebounced(q.trim(), 350);
  const geoEnabled = open && !coord && dq.length >= 3;
  const geo = useGeocode(dq, geoEnabled);

  // Candidate list, priority: coordinates > saved pins > geocoded places.
  const items: Item[] = useMemo(() => {
    if (coord) return [{ kind: 'coord', label: `${coord.lat.toFixed(5)}, ${coord.lng.toFixed(5)}`, lat: coord.lat, lng: coord.lng }];
    const ql = q.trim().toLowerCase();
    const pinItems: Item[] = ql
      ? (pins ?? [])
          .filter((p) => p.title.toLowerCase().includes(ql))
          .slice(0, 3)
          .map((p) => ({ kind: 'pin' as const, label: p.title, lat: p.lat, lng: p.lng }))
      : [];
    const geoItems: Item[] = (geo.data?.results ?? []).map((r) => ({ kind: 'geo' as const, label: r.label, lat: r.lat, lng: r.lng }));
    return [...pinItems, ...geoItems];
  }, [coord, q, pins, geo.data]);

  // Reset the keyboard highlight when the list changes or the dropdown (re)opens — done during
  // render (the documented adjust-state-on-prop-change pattern) rather than in an effect, which
  // avoids a flash of stale highlight and satisfies react-hooks/set-state-in-effect.
  const [prevList, setPrevList] = useState<{ len: number; open: boolean }>({ len: items.length, open });
  if (prevList.len !== items.length || prevList.open !== open) {
    setPrevList({ len: items.length, open });
    setActive(0);
  }

  // Dismiss the dropdown on any click outside the search box.
  useEffect(() => {
    if (!open) return;
    const onDown = (e: PointerEvent) => {
      if (boxRef.current && !boxRef.current.contains(e.target as Node)) setOpen(false);
    };
    document.addEventListener('pointerdown', onDown);
    return () => document.removeEventListener('pointerdown', onDown);
  }, [open]);

  const select = (it: Item) => {
    setOpen(false);
    if (it.kind === 'geo') {
      // Place search = navigation, not a legality question. Fly only — we do NOT stamp a verdict
      // on an imprecise town/centroid point (decision #40, PROJECT_PLAN §9 / §4.3). The user then
      // clicks the exact spot to get the assessment.
      flyTo(it.lat, it.lng, 11);
      setHint(`Flew to ${it.label.split(',')[0]} — click the map to check a spot.`);
    } else {
      // Coordinates or a saved pin = a precise, deliberately-chosen point → fly AND assess.
      flyTo(it.lat, it.lng, it.kind === 'coord' ? 12 : 13);
      assess({ lat: it.lat, lng: it.lng });
      setHint(null);
    }
  };

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === 'ArrowDown') { e.preventDefault(); setOpen(true); setActive((a) => Math.min(a + 1, items.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setActive((a) => Math.max(a - 1, 0)); }
    else if (e.key === 'Enter') { if (items[active]) { e.preventDefault(); select(items[active]); } }
    else if (e.key === 'Escape') { setOpen(false); }
  };

  const showDrop = open && (items.length > 0 || (geoEnabled && (geo.isFetching || geo.isError || geo.isFetched)));

  return (
    <div className="search" ref={boxRef}>
      <form className="search-form" role="search" onSubmit={(e) => { e.preventDefault(); if (items[active]) select(items[active]); }}>
        <input
          value={q}
          onChange={(e) => { setQ(e.target.value); setOpen(true); setHint(null); }}
          onFocus={() => setOpen(true)}
          onKeyDown={onKeyDown}
          placeholder="Search a place, or paste coordinates…"
          aria-label="Search"
          role="combobox"
          aria-expanded={showDrop}
          aria-controls="geo-listbox"
          aria-activedescendant={showDrop && items[active] ? `geo-opt-${active}` : undefined}
          autoComplete="off"
        />
        <button className="btn" type="submit">Go</button>
      </form>

      {showDrop && (
        <ul className="geo-drop" id="geo-listbox" role="listbox">
          {items.map((it, i) => (
            <li
              key={`${it.kind}-${i}-${it.lat}-${it.lng}`}
              id={`geo-opt-${i}`}
              role="option"
              aria-selected={i === active}
              className={`geo-item${i === active ? ' active' : ''}`}
              onMouseEnter={() => setActive(i)}
              onMouseDown={(e) => { e.preventDefault(); select(it); }}
            >
              <span className="geo-ic" aria-hidden="true">{ICON[it.kind]}</span>
              <span className="geo-label" title={it.label}>{it.label}</span>
              <span className="geo-kind">{KIND_LABEL[it.kind]}</span>
            </li>
          ))}
          {geoEnabled && geo.isFetching && items.length === 0 && <li className="geo-empty">Searching…</li>}
          {geoEnabled && geo.isError && <li className="geo-empty">Search failed — try again.</li>}
          {geoEnabled && geo.isFetched && !geo.isError && items.length === 0 && <li className="geo-empty">No places found.</li>}
        </ul>
      )}

      {hint && !showDrop && <span className="search-hint">{hint}</span>}
    </div>
  );
}
