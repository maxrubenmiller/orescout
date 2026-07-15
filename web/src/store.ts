import { create } from 'zustand';
import type { LatLng } from './types';

export type Basemap = 'satellite' | 'topo' | 'street';
export type LeftTab = 'layers' | 'pins';

interface FlyTarget extends LatLng { zoom?: number; nonce: number; }

// Vector-tile feature properties for a clicked reference marker (untyped like the tile payload).
export type MarkerProps = Record<string, unknown>;
// A marker click carries the reference details (prospectivity and/or MRDS and/or an access
// road/trail segment at that spot — any may be null) plus the marker location, which drives the
// persistent highlight ring on the map. When set, the assessment panel renders these ABOVE the
// location assessment and the dropped cursor pin is suppressed (the ring is the "you're here"
// indicator instead).
export interface MarkerSelection {
  prospectivity: MarkerProps | null;
  mrds: MarkerProps | null;
  access: MarkerProps | null;
  point: LatLng;
}

interface UIState {
  // Selected point (the dropped pin being assessed)
  selectedPoint: LatLng | null;
  panelOpen: boolean;
  // When set, the panel is showing a SAVED pin: it renders that pin's immutable
  // assessment snapshot (not a fresh live verdict) and compares it to live for drift.
  // null = a fresh map click → live assessment. (§6.5 snapshot contract.)
  viewedPinId: string | null;
  // Set when the click landed on a reference marker (gold/prospectivity); null for bare-ground clicks.
  marker: MarkerSelection | null;
  assess: (p: LatLng, marker?: MarkerSelection | null) => void;
  viewPin: (id: string, p: LatLng) => void;
  closePanel: () => void;

  // Left panel
  leftPanelOpen: boolean;
  leftTab: LeftTab;
  toggleLeftPanel: () => void;
  setLeftTab: (t: LeftTab) => void;

  // Map config
  basemap: Basemap;
  setBasemap: (b: Basemap) => void;
  // waterways = master toggle; waterwaysPerennial/waterwaysIntermittent = the flow-class sub-toggles
  // (both default on) nested under it. Each class shows only when the master AND its sub-flag are on.
  // access mirrors the same nesting: access = master, accessDrive/accessOffRoad/accessHikeIn = the
  // travel-mode sub-toggles (default on, master default off — waterways parity).
  layers: { prohibited: boolean; ambiguous: boolean; open: boolean; claims: boolean; waterways: boolean; waterwaysPerennial: boolean; waterwaysIntermittent: boolean; mrds: boolean; prospectivity: boolean; access: boolean; accessDrive: boolean; accessOffRoad: boolean; accessHikeIn: boolean };
  toggleLayer: (k: 'prohibited' | 'ambiguous' | 'open' | 'claims' | 'waterways' | 'waterwaysPerennial' | 'waterwaysIntermittent' | 'mrds' | 'prospectivity' | 'access' | 'accessDrive' | 'accessOffRoad' | 'accessHikeIn') => void;

  // Imperative fly-to (MapView watches flyTarget)
  flyTarget: FlyTarget | null;
  flyTo: (lat: number, lng: number, zoom?: number) => void;
}

export const useUI = create<UIState>((set) => ({
  selectedPoint: null,
  panelOpen: false,
  viewedPinId: null,
  marker: null,
  // A fresh map click is always a live assessment — clear any viewed-pin context. `marker` is set
  // only when the click hit a reference marker (defaults to clearing it on a bare-ground click).
  assess: (p, marker = null) => set({ selectedPoint: p, viewedPinId: null, panelOpen: true, marker }),
  // Opening a saved pin: show its stored snapshot (+ live drift comparison); no marker context.
  viewPin: (id, p) => set({ selectedPoint: p, viewedPinId: id, panelOpen: true, marker: null }),
  closePanel: () => set({ panelOpen: false, selectedPoint: null, viewedPinId: null, marker: null }),

  leftPanelOpen: true,
  leftTab: 'layers',
  toggleLeftPanel: () => set((s) => ({ leftPanelOpen: !s.leftPanelOpen })),
  setLeftTab: (t) => set({ leftTab: t, leftPanelOpen: true }),

  basemap: 'satellite',
  setBasemap: (b) => set({ basemap: b }),
  layers: { prohibited: true, ambiguous: true, open: false, claims: false, waterways: false, waterwaysPerennial: true, waterwaysIntermittent: true, mrds: false, prospectivity: false, access: false, accessDrive: true, accessOffRoad: true, accessHikeIn: true },
  toggleLayer: (k) => set((s) => ({ layers: { ...s.layers, [k]: !s.layers[k] } })),

  flyTarget: null,
  flyTo: (lat, lng, zoom) => set({ flyTarget: { lat, lng, zoom, nonce: Date.now() } }),
}));
