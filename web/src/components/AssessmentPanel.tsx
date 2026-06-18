import { useState } from 'react';
import { useUI } from '../store';
import { useAssessment, useCreatePin } from '../hooks';
import type { Assessment, CollectingStatus, AmbiguityType } from '../types';

function verdictMeta(status: CollectingStatus, amb: AmbiguityType) {
  switch (status) {
    case 'RED': return { label: 'Prohibited', cls: 'v-red', blurb: 'Do not prospect or collect here.' };
    case 'GREEN': return { label: 'Open', cls: 'v-green', blurb: 'Generally open for casual hobby use.' };
    case 'OUT_OF_REGION': return { label: 'Outside region', cls: 'v-grey', blurb: 'Legal overlay data is not available here.' };
    case 'YELLOW':
      return amb === 'UNKNOWN'
        ? { label: 'Possibly private', cls: 'v-orange', blurb: 'No land-management data — verify ownership before entering.' }
        : { label: 'Ambiguous', cls: 'v-yellow', blurb: 'Verify the specific rules with the managing agency.' };
  }
}

export default function AssessmentPanel() {
  const point = useUI((s) => s.selectedPoint);
  const open = useUI((s) => s.panelOpen);
  const close = useUI((s) => s.closePanel);
  const { data, isLoading, isError, error } = useAssessment(point);

  if (!open || !point) return null;

  return (
    <div className="panel assessment">
      <div className="panel-head">
        <strong>Location assessment</strong>
        <button className="icon-btn" onClick={close} aria-label="Close">✕</button>
      </div>
      <div className="panel-body">
        <div className="coords">{point.lat.toFixed(5)}, {point.lng.toFixed(5)}</div>
        {isLoading && <p className="muted">Assessing…</p>}
        {isError && <p className="error">Couldn’t assess this location: {(error as Error).message}</p>}
        {data && <Result a={data} lat={point.lat} lng={point.lng} />}
      </div>
    </div>
  );
}

function Result({ a, lat, lng }: { a: Assessment; lat: number; lng: number }) {
  const v = verdictMeta(a.collectingStatus, a.ambiguityType);
  return (
    <>
      <div className={`verdict ${v.cls}`}>
        <span className="verdict-label">{v.label}</span>
      </div>
      <p className="reason">{a.collectingStatusReason || v.blurb}</p>

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

      <SaveForm lat={lat} lng={lng} />

      <details className="cannot">
        <summary>What this doesn’t model</summary>
        <ul>{a.cannotModel.map((c, i) => <li key={i}>{c}</li>)}</ul>
      </details>
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
