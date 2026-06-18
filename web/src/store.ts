import { create } from 'zustand';
import type { LatLng } from './types';

export type Basemap = 'satellite' | 'topo' | 'street';
export type LeftTab = 'layers' | 'pins';

interface FlyTarget extends LatLng { zoom?: number; nonce: number; }

interface UIState {
  // Selected point (the dropped pin being assessed)
  selectedPoint: LatLng | null;
  panelOpen: boolean;
  assess: (p: LatLng) => void;
  closePanel: () => void;

  // Left panel
  leftPanelOpen: boolean;
  leftTab: LeftTab;
  toggleLeftPanel: () => void;
  setLeftTab: (t: LeftTab) => void;

  // Map config
  basemap: Basemap;
  setBasemap: (b: Basemap) => void;
  layers: { prohibited: boolean; ambiguous: boolean; claims: boolean };
  toggleLayer: (k: 'prohibited' | 'ambiguous' | 'claims') => void;

  // Imperative fly-to (MapView watches flyTarget)
  flyTarget: FlyTarget | null;
  flyTo: (lat: number, lng: number, zoom?: number) => void;
}

export const useUI = create<UIState>((set) => ({
  selectedPoint: null,
  panelOpen: false,
  assess: (p) => set({ selectedPoint: p, panelOpen: true }),
  closePanel: () => set({ panelOpen: false, selectedPoint: null }),

  leftPanelOpen: true,
  leftTab: 'layers',
  toggleLeftPanel: () => set((s) => ({ leftPanelOpen: !s.leftPanelOpen })),
  setLeftTab: (t) => set({ leftTab: t, leftPanelOpen: true }),

  basemap: 'satellite',
  setBasemap: (b) => set({ basemap: b }),
  layers: { prohibited: true, ambiguous: true, claims: false },
  toggleLayer: (k) => set((s) => ({ layers: { ...s.layers, [k]: !s.layers[k] } })),

  flyTarget: null,
  flyTo: (lat, lng, zoom) => set({ flyTarget: { lat, lng, zoom, nonce: Date.now() } }),
}));
