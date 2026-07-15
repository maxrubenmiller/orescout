import { useState } from 'react';
import { useUI } from '../store';
import { useActiveAssessment, useCreatePin } from '../hooks';
import type { Assessment, CollectingStatus, AmbiguityType } from '../types';
import type { MarkerProps } from '../store';
// Per-commodity strings (pathfinder "why" blurb, chemistry-earned line, upstream note) render from
// config keyed by the feature's `commodity` — never hardcoded per component (TIER_B brief).
import prospectivityConfig from '../../../config/prospectivity.json';

interface CommodityStrings {
  pathfinder_blurb: string; chemistry_earned: string; upstream_note: string; vintage_note: string;
}
const commodityStrings = (key: unknown): CommodityStrings | null =>
  prospectivityConfig.commodities.find((c) => c.key === key)?.strings ?? null;

function formatDate(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime())
    ? iso
    : d.toLocaleDateString(undefined, { year: 'numeric', month: 'short', day: 'numeric' });
}

function verdictMeta(status: CollectingStatus, amb: AmbiguityType) {
  switch (status) {
    case 'RED': return { label: 'Prohibited', cls: 'v-red', blurb: 'Do not prospect or collect here.' };
    case 'GREEN': return { label: 'Open', cls: 'v-green', blurb: 'Generally open for casual hobby use.' };
    case 'OUT_OF_REGION': return { label: 'Outside region', cls: 'v-grey', blurb: 'Legal overlay data is not available here.' };
    case 'YELLOW':
      return amb === 'UNKNOWN'
        ? { label: 'Possibly private', cls: 'v-orange', blurb: 'No land-management data — verify ownership before entering.' }
        : { label: 'Ambiguous', cls: 'v-yellow', blurb: 'Verify the specific rules with the managing agency.' };
    // Fail-safe: an unrecognized status (API/snapshot drift ahead of the UI) must degrade to a
    // cautious render, never a crash or a blank panel.
    default:
      return { label: 'Unknown status', cls: 'v-grey', blurb: 'Unrecognized status — verify the rules independently with the managing agency before you go.' };
  }
}

export default function AssessmentPanel() {
  const point = useUI((s) => s.selectedPoint);
  const open = useUI((s) => s.panelOpen);
  const close = useUI((s) => s.closePanel);
  const viewedPinId = useUI((s) => s.viewedPinId);
  const marker = useUI((s) => s.marker);
  const a = useActiveAssessment(point, viewedPinId);

  if (!open || !point) return null;

  // In snapshot view the stored snapshot renders immediately; the live fetch only powers
  // the drift check. In live view we wait on the fetch.
  const showLiveLoading = !a.isSnapshotView && a.liveLoading;
  const showLiveError = !a.isSnapshotView && a.liveError;

  return (
    <div className="panel assessment">
      <div className="panel-head">
        <strong>{a.isSnapshotView ? 'Saved location' : marker ? 'Selected site' : 'Location assessment'}</strong>
        <button className="icon-btn" onClick={close} aria-label="Close">✕</button>
      </div>
      <div className="panel-body">
        {/* Reference-marker details (from a gold/prospectivity click) render ABOVE the location
            assessment — prospectivity first, then gold — replacing the old floating map popup. */}
        {marker?.prospectivity && <ProspectivityDetails p={marker.prospectivity} />}
        {marker?.mrds && <MrdsDetails p={marker.mrds} />}
        {marker?.access && <AccessDetails p={marker.access} />}
        {marker && <div className="assess-section-head">Location assessment</div>}

        <div className="coords">{point.lat.toFixed(5)}, {point.lng.toFixed(5)}</div>

        {a.isSnapshotView && a.snapshotDate && (
          <p className="snapshot-note">📌 Saved snapshot — assessed {formatDate(a.snapshotDate)}.</p>
        )}
        {a.isSnapshotView && a.snapshotMissing && (
          <p className="muted small">No saved snapshot for this pin — showing current status.</p>
        )}
        {a.drift && a.display && a.live && <DriftBanner snapshot={a.display} live={a.live} />}
        {a.driftCheckFailed && (
          <div className="drift" role="alert">
            <div className="drift-head">⚠ Couldn’t re-check current status</div>
            <div className="small">Verify with the managing agency before you go.</div>
          </div>
        )}

        {showLiveLoading && <p className="muted">Assessing…</p>}
        {showLiveError && (
          <p className="error">Couldn’t assess this location: {(a.liveErrorObj as Error)?.message}</p>
        )}
        {a.display && (
          <Result a={a.display} lat={point.lat} lng={point.lng} showSaveForm={!a.isSnapshotView} />
        )}
      </div>
    </div>
  );
}

// Prospecting-potential marker card (was the floating map popup). Contract: tier headline, anomaly
// line, pathfinders, the pathfinder "why" blurb, producer line, chemistry-earned line, upstream note,
// vintage — static per-commodity strings from config/prospectivity.json, dynamic values from the tile.
// React escapes all text, so no manual escaping is needed.
function ProspectivityDetails({ p }: { p: MarkerProps }) {
  const strings = commodityStrings(p.commodity);
  const chem = p.tier_basis === 'chemistry';
  const headline = p.tier === 'High' ? 'High potential' : 'Moderate potential';
  const pctl = Math.round(Number(p.anomaly_pctl) * 100);
  const km = p.producer_dist_m == null ? null : (Number(p.producer_dist_m) / 1000).toFixed(1);
  return (
    <section className="marker-card prospect-pop">
      <h4 className="marker-card-head">Prospecting potential</h4>
      <strong>{headline}{chem ? ' · chemistry-earned' : ''}</strong>
      <div className="prospect-anom">{String(p.anomaly_element ?? '')} anomaly — p{pctl} in its watershed</div>
      {p.pathfinders ? <div className="prospect-path">Co-elevated: {String(p.pathfinders)}</div> : null}
      {strings ? <div className="prospect-why">{strings.pathfinder_blurb}</div> : null}
      {p.producer_name ? (
        <div className="prospect-prod">{String(p.producer_name)} — historic producer {km ?? '?'} km away</div>
      ) : null}
      {chem && strings ? <div className="prospect-chem">{strings.chemistry_earned}</div> : null}
      {strings ? <div className="prospect-note">{strings.upstream_note}</div> : null}
      <div className="prospect-vintage">{String(p.data_vintage ?? '')}</div>
    </section>
  );
}

// Gold-occurrence (MRDS) marker card (was the floating map popup). Enrichment fields
// (commodities_major/minor, ore/gangue minerals, alt names) come from build_mrds.sql and may be null.
function MrdsDetails({ p }: { p: MarkerProps }) {
  const s = (k: string) => (p[k] ? String(p[k]) : '');
  const grade = s('grade'), url = s('url');
  const majors = s('commodities_major'), minors = s('commodities_minor');
  const ore = s('ore_minerals'), gangue = s('gangue_minerals'), altNames = s('alt_names');
  return (
    <section className="marker-card mrds-pop">
      <h4 className="marker-card-head">Gold occurrence</h4>
      <strong>{s('site_name') || 'Unnamed site'}</strong>
      <div className="mrds-stat">{s('dev_stat') || '—'}{grade ? ` · grade ${grade}` : ''}</div>
      {majors ? (
        <div className="mrds-comm">
          <span className="mrds-comm-major">{majors}</span>
          {minors ? <span className="mrds-comm-minor"> · {minors}</span> : null}
        </div>
      ) : (
        <div className="mrds-comm">Commodities: {s('commodities') || '—'}</div>
      )}
      {ore || gangue ? (
        <div className="mrds-min">
          {ore ? <span className="mrds-min-ore">Ore: {ore}</span> : null}
          {ore && gangue ? ' · ' : null}
          {gangue ? <span className="mrds-min-gangue">Gangue: {gangue}</span> : null}
        </div>
      ) : null}
      {altNames ? <div className="mrds-alt">Also known as: {altNames}</div> : null}
      {url ? <a className="mrds-link" href={url} target="_blank" rel="noopener noreferrer">Full USGS record →</a> : null}
      <div className="mrds-note">Historic USGS MRDS record (pre-2011) — not current.</div>
    </section>
  );
}

// Access road/trail card (from a click on an access & trails line — §5.4). Contract per the
// brief: name · travel mode · surface · seasonal window (ADVISORY free text, never parsed) ·
// source agency · the mandatory MVUM-authority disclaimer line.
const TRAVEL_MODE_LABELS: Record<string, string> = {
  drive: 'Drive in — open to passenger vehicles',
  off_road: 'Off-road — high-clearance / 4WD / OHV',
  hike_in: 'Hike in — non-motorized',
};
function AccessDetails({ p }: { p: MarkerProps }) {
  const s = (k: string) => (p[k] ? String(p[k]) : '');
  const mode = s('travel_mode');
  const usfs = s('agency').includes('Forest Service');
  return (
    <section className="marker-card access-pop">
      <h4 className="marker-card-head">Road / trail access</h4>
      <strong>{s('name') || (p['is_road'] ? 'Unnamed road' : 'Unnamed trail')}{s('route_id') ? ` (#${s('route_id')})` : ''}</strong>
      <div className={`access-mode ${mode}`}>{TRAVEL_MODE_LABELS[mode] ?? mode}</div>
      {s('surface') ? <div className="access-attr">Surface: {s('surface')}</div> : null}
      {s('seasonal') ? <div className="access-attr">Open dates (advisory): {s('seasonal')}</div> : null}
      {s('mode_detail') ? <div className="access-detail">{s('mode_detail')}</div> : null}
      <div className="access-agency">Source: {s('agency') || '—'}</div>
      <div className="access-note">
        {usfs
          ? 'Feature data can lag the legally authoritative Motor Vehicle Use Map — confirm against the official MVUM before you go.'
          : 'Designations can change — confirm current travel rules with the local BLM office (and the official MVUM on Forest Service land) before you go.'}
      </div>
    </section>
  );
}

// Saved verdict ≠ current verdict — the safety-critical signal (§6.5). Shows what you
// saved vs what the data says now; tells the user to re-verify before acting on a stale pin.
function DriftBanner({ snapshot, live }: { snapshot: Assessment; live: Assessment }) {
  const s = verdictMeta(snapshot.collectingStatus, snapshot.ambiguityType);
  const l = verdictMeta(live.collectingStatus, live.ambiguityType);
  return (
    <div className="drift" role="alert">
      <div className="drift-head">⚠ Status may have changed since you saved this</div>
      <div className="drift-row">
        Saved as <span className={`pill ${s.cls}`}>{s.label}</span>
        {' → now '}
        <span className={`pill ${l.cls}`}>{l.label}</span>
      </div>
      <div className="small">Public-land data lags real ownership — verify with the managing agency before you go.</div>
    </div>
  );
}

function Result({ a, lat, lng, showSaveForm }: { a: Assessment; lat: number; lng: number; showSaveForm: boolean }) {
  const v = verdictMeta(a.collectingStatus, a.ambiguityType);
  return (
    <>
      <div className={`verdict ${v.cls}`}>
        <span className="verdict-label">{v.label}</span>
      </div>
      {/* Non-YELLOW: the plain reason (or verdict blurb) is the headline. YELLOW leads with the
          plain-language guidance instead (below); its raw agency/designation code is demoted to a
          de-emphasized "Basis" line, so the user never reads a cryptic code as the headline. */}
      {a.collectingStatus !== 'YELLOW' && (
        <p className="reason">{a.collectingStatusReason || v.blurb}</p>
      )}
      {/* The two kinds of YELLOW read very differently (§4.1.1) — say WHICH one this is and what to
          do about it, in plain words. This is the headline line for YELLOW. */}
      {a.collectingStatus === 'YELLOW' && (
        <p className="reason">
          {a.ambiguityType === 'UNKNOWN'
            ? 'No public-land record covers this spot — most often that means unmapped private land. Verify ownership before entering, and lean toward staying out.'
            : 'This is a recognized designation with its own rules (permits are common). Contact the managing agency for this unit\u2019s collecting policy before you go.'}
        </p>
      )}
      {/* KNOWN's raw agency/designation code — kept for detail, de-emphasized below the guidance.
          (UNKNOWN's code is redundant with the plain "no record" text, so it is omitted.) */}
      {a.collectingStatus === 'YELLOW' && a.ambiguityType !== 'UNKNOWN' && a.collectingStatusReason && (
        <p className="reason-detail muted small">Basis: {a.collectingStatusReason}</p>
      )}

      {(a.landManager || a.unitName) && (
        <dl className="facts">
          {a.landManager && (<><dt>Manager</dt><dd>{a.landManager}</dd></>)}
          {a.unitName && (<><dt>Unit</dt><dd>{a.unitName}</dd></>)}
          {a.protectionStatus && (<><dt>Protection</dt><dd>{a.protectionStatus}</dd></>)}
        </dl>
      )}

      <Claims a={a} />

      {a.warnings.length > 0 && (
        <ul className="warnings">{a.warnings.map((w, i) => <li key={i}>⚠ {w}</li>)}</ul>
      )}
      {a.dataGaps.length > 0 && (
        <ul className="datagaps">{a.dataGaps.map((g, i) => <li key={i}>ℹ {g}</li>)}</ul>
      )}

      {/* Keyed by location: the mutation state (isSuccess "✓ Saved") lives in the form instance,
          and react-query's 5-min assessment cache means Result does NOT unmount when revisiting a
          cached point — without the key, a save at point B leaks "✓ Saved" onto point A. */}
      {showSaveForm && <SaveForm key={`${lat},${lng}`} lat={lat} lng={lng} />}

      {a.cannotModel.length > 0 && (
        <p className="cannot-model">
          <span className="cannot-label">Not modeled — verify separately:</span>{' '}
          {a.cannotModel.join(', ')}
        </p>
      )}
      {a.dataVintage && <p className="vintage">Data: {a.dataVintage}</p>}
      <p className="disclaimer">{a.disclaimer}</p>
    </>
  );
}

function Claims({ a }: { a: Assessment }) {
  if (a.activeClaims === null) {
    return <p className="muted small">Mining claims: not checked (see notes).</p>;
  }
  if (a.activeClaims.length === 0) {
    return <p className="muted small">No active mining claims within 100m.</p>;
  }
  return (
    <div className="claims">
      <div className="claims-head">Active mining claims ({a.activeClaims.length})</div>
      <ul>
        {a.activeClaims.map((c) => (
          <li key={c.serialNumber}>
            <a href={c.mlrsUrl} target="_blank" rel="noreferrer">{c.serialNumber}</a>
            {' '}— {c.claimName ?? 'unnamed'} ({c.type ?? '—'}, {c.status ?? '—'})
          </li>
        ))}
      </ul>
    </div>
  );
}

function SaveForm({ lat, lng }: { lat: number; lng: number }) {
  const [openForm, setOpenForm] = useState(false);
  const [title, setTitle] = useState('');
  const [notes, setNotes] = useState('');
  const [status, setStatus] = useState<'want_to_visit' | 'visited'>('want_to_visit');
  const create = useCreatePin();

  if (create.isSuccess) return <p className="saved">✓ Saved to your pins.</p>;

  if (!openForm) {
    return <button className="btn primary" onClick={() => setOpenForm(true)}>Save this location</button>;
  }
  return (
    <form
      className="save-form"
      onSubmit={(e) => {
        e.preventDefault();
        if (!title.trim()) return;
        create.mutate({ lat, lng, title: title.trim(), notes: notes || null, status });
      }}
    >
      <input placeholder="Title (e.g. Gold Creek bend)" value={title} onChange={(e) => setTitle(e.target.value)} autoFocus />
      <textarea placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} rows={2} />
      <select value={status} onChange={(e) => setStatus(e.target.value as 'want_to_visit' | 'visited')}>
        <option value="want_to_visit">Want to visit</option>
        <option value="visited">Visited</option>
      </select>
      <div className="form-actions">
        <button type="button" className="btn" onClick={() => setOpenForm(false)}>Cancel</button>
        <button type="submit" className="btn primary" disabled={create.isPending || !title.trim()}>
          {create.isPending ? 'Saving…' : 'Save'}
        </button>
      </div>
      {create.isError && <p className="error">{(create.error as Error).message}</p>}
    </form>
  );
}
