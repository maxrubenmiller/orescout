// Single typed API client (docs/planning/PROJECT_PLAN.md §6.12). All requests go through here:
// injects base URL + X-Api-Key, centralizes error handling against { error: { code, message } }.
import type {
  Assessment, CreatePinRequest, Entitlements, GeocodeResult, Meta, Pin, PinStatus,
} from './types';

// API runs on 5167 (not 5000 — macOS AirPlay Receiver squats 5000). See docs/planning/PROJECT_PLAN.md §6.8 / #34.
const BASE = import.meta.env.VITE_API_BASE_URL ?? 'http://localhost:5167/api/v1';
const KEY = import.meta.env.VITE_API_KEY ?? '';

export class ApiError extends Error {
  code: string;
  status: number;
  constructor(code: string, message: string, status: number) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    ...init,
    headers: {
      'X-Api-Key': KEY,
      ...(init?.body ? { 'Content-Type': 'application/json' } : {}),
      ...init?.headers,
    },
  });
  if (res.status === 204) return undefined as T;
  if (!res.ok) {
    let code = 'error';
    let message = `Request failed (${res.status})`;
    try {
      const body = await res.json();
      if (body?.error) { code = body.error.code; message = body.error.message; }
    } catch { /* non-JSON error body */ }
    throw new ApiError(code, message, res.status);
  }
  return res.json() as Promise<T>;
}

export const api = {
  assess: (lat: number, lng: number) =>
    request<Assessment>(`/assessment?lat=${lat}&lng=${lng}`),

  listPins: () => request<Pin[]>('/pins'),

  createPin: (body: CreatePinRequest) =>
    request<Pin>('/pins', { method: 'POST', body: JSON.stringify(body) }),

  updatePin: (id: string, body: { title: string; notes?: string | null; status: PinStatus }) =>
    request<Pin>(`/pins/${id}`, { method: 'PUT', body: JSON.stringify(body) }),

  deletePin: (id: string) => request<void>(`/pins/${id}`, { method: 'DELETE' }),

  exportPin: async (id: string, format: 'gpx' | 'kml' = 'gpx'): Promise<Blob> => {
    const res = await fetch(`${BASE}/pins/${id}/export?format=${format}`, { headers: { 'X-Api-Key': KEY } });
    if (!res.ok) throw new ApiError('export_failed', 'Export failed', res.status);
    return res.blob();
  },

  geocode: (q: string) =>
    request<{ results: GeocodeResult[] }>(`/geocode?q=${encodeURIComponent(q)}`),

  meta: () => request<Meta>('/meta'),

  // Paywall seam (§6.14): the caller's gateable-capability set. Grants everything today.
  entitlements: () => request<Entitlements>('/entitlements'),
};

export const tileBaseUrl = import.meta.env.VITE_TILE_BASE_URL ?? 'http://localhost:7800';
export const mapboxToken = import.meta.env.VITE_MAPBOX_TOKEN ?? '';
