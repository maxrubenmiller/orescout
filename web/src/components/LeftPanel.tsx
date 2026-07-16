import { useState } from 'react';
import { useUI, type Basemap } from '../store';
import { usePins, useDeletePin, useMeta, useIsEntitled } from '../hooks';
import { FEATURES } from '../features';
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
  // Paywall seam (§6.14): data overlays are gateable capabilities. Fail-open today (everything
  // granted) — a locked layer disables its toggle and shows an upgrade chip, no behavior change now.
  const isEntitled = useIsEntitled();

  return (
    <div className="layers">
      <section>
        <h4>Legality overlay</h4>
        <label className="chk"><input type="checkbox" checked={layers.prohibited} onChange={() => toggle('prohibited')} /> <span className="sw sw-red" /> Prohibited (red)</label>
        <p className="hint">Closed to prospecting and mineral collection — protected or restricted land such as Wilderness, national parks and monuments, wildlife refuges, and tribal land.</p>
        <label className="chk"><input type="checkbox" checked={layers.ambiguous} onChange={() => toggle('ambiguous')} /> <span className="sw sw-hatch" /> Ambiguous (grey)</label>
        <p className="hint">We can't confirm whether prospecting or mineral collection is allowed in these areas — verify the specific rules yourself before collecting.</p>
        <label className="chk"><input type="checkbox" checked={layers.open} onChange={() => toggle('open')} /> <span className="sw sw-open" /> Confirmed open (green)</label>
        <p className="hint">Public land affirmatively confirmed open to casual hand-tool collecting. This shading is conservative — an area without it isn't necessarily closed, just not <strong>confirmed</strong> open.</p>
      </section>
      <section>
        <h4>Data layers</h4>
        <label className={isEntitled(FEATURES.layerClaims) ? 'chk' : 'chk locked'}>
          <input type="checkbox" checked={layers.claims} disabled={!isEntitled(FEATURES.layerClaims)} onChange={() => toggle('claims')} /> <span className="sw sw-claims" /> Active mining claims
          {!isEntitled(FEATURES.layerClaims) && <span className="lock-chip">🔒 Upgrade</span>}
        </label>
        <p className="hint">Orange = recorded BLM claims (zoom to ~9+ to see them). Also listed per-location when you click the map.</p>
        <label className={isEntitled(FEATURES.layerWaterways) ? 'chk' : 'chk locked'}>
          <input type="checkbox" checked={layers.waterways} disabled={!isEntitled(FEATURES.layerWaterways)} onChange={() => toggle('waterways')} /> <span className="sw sw-water" /> Waterways
          {!isEntitled(FEATURES.layerWaterways) && <span className="lock-chip">🔒 Upgrade</span>}
        </label>
        {layers.waterways && (
          <div className="sub-toggles">
            <label className="chk sub">
              <input type="checkbox" checked={layers.waterwaysPerennial} onChange={() => toggle('waterwaysPerennial')} /> <span className="sw sw-water" /> Perennial
            </label>
            <label className="chk sub">
              <input type="checkbox" checked={layers.waterwaysIntermittent} onChange={() => toggle('waterwaysIntermittent')} /> <span className="sw sw-water-dash" /> Intermittent
            </label>
          </div>
        )}
        <p className="hint">Blue = streams &amp; rivers (USGS NHDPlus HR; zoom ~10+). Solid = perennial, dashed = intermittent; chevrons show flow direction (zoom ~12+). Reference only — does not affect the legality verdict.</p>
        <label className={isEntitled(FEATURES.layerMrds) ? 'chk' : 'chk locked'}>
          <input type="checkbox" checked={layers.mrds} disabled={!isEntitled(FEATURES.layerMrds)} onChange={() => toggle('mrds')} /> <span className="sw sw-gold" /> Gold occurrences (MRDS)
          {!isEntitled(FEATURES.layerMrds) && <span className="lock-chip">🔒 Upgrade</span>}
        </label>
        <p className="hint">Gold dots = historic gold sites (USGS MRDS; brighter = past producers). Zoom to ~8+ and click a dot for details. A pre-2011 record — historical, not current — and reference only: it does not affect the legality verdict.</p>
        <label className={isEntitled(FEATURES.layerAccess) ? 'chk' : 'chk locked'}>
          <input type="checkbox" checked={layers.access} disabled={!isEntitled(FEATURES.layerAccess)} onChange={() => toggle('access')} /> <span className="sw sw-access" /> Access &amp; trails
          {!isEntitled(FEATURES.layerAccess) && <span className="lock-chip">🔒 Upgrade</span>}
        </label>
        {layers.access && (
          <div className="sub-toggles">
            <label className="chk sub">
              <input type="checkbox" checked={layers.accessDrive} onChange={() => toggle('accessDrive')} /> <span className="sw sw-access-drive" /> Drive
            </label>
            <label className="chk sub">
              <input type="checkbox" checked={layers.accessOffRoad} onChange={() => toggle('accessOffRoad')} /> <span className="sw sw-access-offroad" /> Off-road
            </label>
            <label className="chk sub">
              <input type="checkbox" checked={layers.accessHikeIn} onChange={() => toggle('accessHikeIn')} /> <span className="sw sw-access-hikein" /> Hike-in
            </label>
          </div>
        )}
        <p className="hint">Roads &amp; trails colored by travel mode (USFS MVUM/NFS trails + BLM GTLF). Solid pink = passenger-vehicle roads, dashed = high-clearance/OHV, teal = non-motorized. Trails from zoom ~9, roads ~10; click a line for details. Seasonal dates are advisory — confirm against the official MVUM before you go. Reference only — does not affect the legality verdict.</p>
        <label className={isEntitled(FEATURES.layerProspectivity) ? 'chk' : 'chk locked'}>
          <input type="checkbox" checked={layers.prospectivity} disabled={!isEntitled(FEATURES.layerProspectivity)} onChange={() => toggle('prospectivity')} /> <span className="sw sw-prospect" /> Prospecting potential (gold)
          {!isEntitled(FEATURES.layerProspectivity) && <span className="lock-chip">🔒 Upgrade</span>}
        </label>
        <p className="hint prospect-legend">
          ★ High potential — producer-anchored<br />
          ☆ High potential — chemistry-earned<br />
          ◆ Moderate potential
        </p>
        <p className="hint">Computed from USGS stream-sediment geochemistry + historic producers — where it&apos;s worth checking, not &quot;gold here&quot;. Zoom to ~7+ (High) / ~10+ (Moderate) and click a marker for details. Reference only — it does not affect the legality verdict.</p>
      </section>
      <section>
        <h4>Base map</h4>
        {(['satellite', 'topo', 'street'] as Basemap[]).map((b) => (
          <label className="chk" key={b}>
            <input type="radio" name="basemap" checked={basemap === b} onChange={() => setBasemap(b)} /> {b[0].toUpperCase() + b.slice(1)}
          </label>
        ))}
      </section>
      <DataVintage />
    </div>
  );
}

// Data vintage (IMP-10): surface how old the overlays are next to their toggles. Claims are
// refreshed nightly, so >48h means the pipeline is behind — flag it in the warning style.
// Staleness is judged against page-load time (module scope keeps render pure); a 48h
// threshold doesn't need a ticking clock.
const LOADED_AT = Date.now();

function DataVintage() {
  const { data: meta } = useMeta();
  if (!meta) return null;

  // claimsAsOf arrives as Postgres timestamptz text ("2026-06-18 23:18:10.139105+00") — make it
  // ISO-parseable ("T" separator, full "+00:00" offset) before Date() sees it.
  const claims = meta.claimsAsOf
    ? new Date(meta.claimsAsOf.replace(' ', 'T').replace(/([+-]\d{2})$/, '$1:00'))
    : null;
  const claimsValid = claims != null && !Number.isNaN(claims.getTime());
  const claimsStale = claimsValid && LOADED_AT - claims.getTime() > 48 * 60 * 60 * 1000;
  const claimsLabel = claimsValid
    ? claims.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' })
    : meta.claimsAsOf ?? 'unknown';

  // Generic freshness badges from the registry (docs/DATA_REFRESH_PLAN.md). The two lines above
  // stay as-is (padus + claims have bespoke wording the diags pin); the registry renders every
  // OTHER refreshable source, so new sources get a badge with zero UI changes. Static sources
  // (maxAgeDays null) are skipped — nothing actionable to say.
  const registryBadges = (meta.dataSources ?? []).filter(
    (d) => !['padus', 'mlrs_claims'].includes(d.sourceKey) && d.maxAgeDays != null,
  );

  return (
    <section className="vintage">
      <p className="hint">Land data: {meta.padUsVersion ?? 'unknown'} ({meta.padUsDate ?? 'date unknown'})</p>
      <p className={claimsStale ? 'hint warn' : 'hint'}>
        Claims data as of {claimsLabel}
        {claimsStale && ' — ⚠ claims overlay may be stale'}
      </p>
      {registryBadges.map((d) => (
        <p key={d.sourceKey} className={d.stale ? 'hint warn' : 'hint'}>
          {SOURCE_LABELS[d.sourceKey] ?? d.sourceKey}: {d.refreshedAt ? new Date(d.refreshedAt).toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' }) : 'unknown'}
          {d.stale && ' — ⚠ may be outdated'}
        </p>
      ))}
    </section>
  );
}

// Friendly names for registry keys (fallback: the key itself, so unknown sources still render).
const SOURCE_LABELS: Record<string, string> = {
  calfire_ca: 'CA ownership (CAL FIRE)',
  ugrc_ut: 'UT ownership (SGID)',
  ngdb_prospectivity: 'Prospecting geochemistry',
  wbd: 'Watersheds (WBD)',
  access: 'Access & trails (MVUM/GTLF)',
};

function Pins() {
  const { data: pins, isLoading } = usePins();
  const flyTo = useUI((s) => s.flyTo);
  const viewPin = useUI((s) => s.viewPin);
  const del = useDeletePin();
  // Per-pin action feedback (export/delete failures were previously silent — an unhandled
  // rejection and a no-op button respectively).
  const [actionErr, setActionErr] = useState<{ id: string; msg: string } | null>(null);

  if (isLoading) return <p className="muted">Loading…</p>;
  if (!pins || pins.length === 0) return <p className="muted">No saved pins yet. Click the map and “Save this location”.</p>;

  // Open the saved pin = show its stored snapshot (+ drift check), NOT a fresh assessment.
  const goTo = (p: Pin) => { flyTo(p.lat, p.lng, 13); viewPin(p.id, { lat: p.lat, lng: p.lng }); };

  const exportPin = async (p: Pin, format: 'gpx' | 'kml') => {
    setActionErr(null);
    try {
      const blob = await api.exportPin(p.id, format);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = `${p.title.replace(/[^a-z0-9]+/gi, '_')}.${format}`; a.click();
      URL.revokeObjectURL(url);
    } catch (e) {
      setActionErr({ id: p.id, msg: `Export failed: ${(e as Error).message}` });
    }
  };

  const deletePin = (p: Pin) => {
    setActionErr(null);
    del.mutate(p.id, {
      onError: (e) => setActionErr({ id: p.id, msg: `Delete failed: ${(e as Error).message}` }),
    });
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
            <button className="btn small" onClick={() => exportPin(p, 'gpx')}>GPX</button>
            <button className="btn small" onClick={() => exportPin(p, 'kml')}>KML</button>
            <button className="btn small danger" disabled={del.isPending} onClick={() => deletePin(p)}>
              {del.isPending && del.variables === p.id ? 'Deleting…' : 'Delete'}
            </button>
          </div>
          {actionErr?.id === p.id && <p className="error small">{actionErr.msg}</p>}
        </li>
      ))}
    </ul>
  );
}
