import { create } from 'zustand';
import type { LatLng } from './types';

export type Basemap = 'satellite' | 'topo' | 'street';
export type LeftTab = 'layers' | 'pins';

interface FlyTarget extends LatLng { zoom?: number; nonce: number; }

interface UIState {
  // Selected point (the dropped pin being assessed)
  selectedPoint: LatLng | null;
  panelOpen: boolean;
  // When set, the panel is showing a SAVED pin: it renders that pin's immutable
  // assessment snapshot (not a fresh live verdict) and compares it to live for drift.
  // null = a fresh map click → live assessment. (§6.5 snapshot contract.)
  viewedPinId: string | null;
  assess: (p: LatLng) => void;
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
  layers: { prohibited: boolean; ambiguous: boolean; open: boolean; claims: boolean; waterways: boolean };
  toggleLayer: (k: 'prohibited' | 'ambiguous' | 'open' | 'claims' | 'waterways') => void;

  // Imperative fly-to (MapView watches flyTarget)
  flyTarget: FlyTarget | null;
  flyTo: (lat: number, lng: number, zoom?: number) => void;
}

export const useUI = create<UIState>((set) => ({
  selectedPoint: null,
  panelOpen: false,
  viewedPinId: null,
  // A fresh map click is always a live assessment — clear any viewed-pin context.
  assess: (p) => set({ selectedPoint: p, viewedPinId: null, panelOpen: true }),
  // Opening a saved pin: show its stored snapshot (+ live drift comparison).
  viewPin: (id, p) => set({ selectedPoint: p, viewedPinId: id, panelOpen: true }),
  closePanel: () => set({ panelOpen: false, selectedPoint: null, viewedPinId: null }),

  leftPanelOpen: true,
  leftTab: 'layers',
  toggleLeftPanel: () => set((s) => ({ leftPanelOpen: !s.leftPanelOpen })),
  setLeftTab: (t) => set({ leftTab: t, leftPanelOpen: true }),

  basemap: 'satellite',
  setBasemap: (b) => set({ basemap: b }),
  layers: { prohibited: true, ambiguous: true, open: false, claims: false, waterways: false },
  toggleLayer: (k) => set((s) => ({ layers: { ...s.layers, [k]: !s.layers[k] } })),

  flyTarget: null,
  flyTo: (lat, lng, zoom) => set({ flyTarget: { lat, lng, zoom, nonce: Date.now() } }),
}));
