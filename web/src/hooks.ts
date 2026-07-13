import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from './api';
import type { Assessment, CreatePinRequest, LatLng, PinStatus } from './types';

export function useAssessment(point: LatLng | null) {
  return useQuery({
    queryKey: ['assessment', point?.lat, point?.lng],
    queryFn: () => api.assess(point!.lat, point!.lng),
    enabled: point != null,
    staleTime: 5 * 60 * 1000,
  });
}

/**
 * Resolves what the assessment panel + selected marker should show for the current
 * selection (§6.5 snapshot contract):
 *  - fresh map click (viewedPinId == null) → the live assessment.
 *  - saved pin (viewedPinId set)           → that pin's IMMUTABLE stored snapshot,
 *    while still fetching live in the background to detect drift (saved verdict vs
 *    current). The snapshot is never overwritten — a stale pin is re-baselined by
 *    delete + re-save, not a refresh.
 */
export function useActiveAssessment(point: LatLng | null, viewedPinId: string | null) {
  const live = useAssessment(point);
  const { data: pins } = usePins();

  const isSnapshotView = viewedPinId != null;
  const pin = isSnapshotView ? (pins ?? []).find((p) => p.id === viewedPinId) ?? null : null;
  const snapshot = pin?.assessmentSnapshot ?? null;

  // The assessment to render: snapshot when viewing a saved pin (fall back to live if
  // the pin predates snapshotting / was saved while PostGIS was down), else live.
  const display: Assessment | null = isSnapshotView
    ? snapshot ?? live.data ?? null
    : live.data ?? null;

  const drift =
    isSnapshotView &&
    snapshot != null &&
    live.data != null &&
    (snapshot.collectingStatus !== live.data.collectingStatus ||
      snapshot.ambiguityType !== live.data.ambiguityType);

  // Snapshot view where the background live re-check FAILED: drift can't be detected, so the
  // saved verdict may be silently stale — the panel must warn rather than swallow the error.
  const driftCheckFailed = isSnapshotView && live.isError;

  return {
    display,
    isSnapshotView,
    snapshot,
    snapshotDate: pin?.assessmentDate ?? null,
    snapshotMissing: isSnapshotView && snapshot == null,
    live: live.data ?? null,
    liveLoading: live.isLoading,
    liveError: live.isError,
    liveErrorObj: live.error,
    drift,
    driftCheckFailed,
  };
}

export function usePins() {
  return useQuery({ queryKey: ['pins'], queryFn: api.listPins });
}

export function useMeta() {
  return useQuery({ queryKey: ['meta'], queryFn: api.meta, staleTime: Infinity });
}

/** Paywall seam (§6.14 / decision #45): the caller's gateable-capability set. */
export function useEntitlements() {
  return useQuery({ queryKey: ['entitlements'], queryFn: api.entitlements, staleTime: Infinity });
}

/**
 * Returns `(featureId) => entitled?`. FAIL-OPEN in the POC: while loading, or if the call fails,
 * or for an unknown id, treat as entitled so the map is never wrongly locked — the seam grants
 * everything today anyway. This gate is UX only; server-side checks (API endpoints + the future
 * tile proxy, §6.14) are the real enforcement.
 */
export function useIsEntitled(): (featureId: string) => boolean {
  const { data } = useEntitlements();
  const entitled = new Map((data?.features ?? []).map((f) => [f.id, f.entitled]));
  return (featureId: string) => entitled.get(featureId) ?? true;
}

/**
 * Type-ahead geocode suggestions for the search box. Mirrors the backend's 24h geocode
 * cache (§6.10); the ≤1 req/s upstream gate is enforced server-side, so the caller must
 * DEBOUNCE `query` (don't fire per keystroke). Disabled for <3 chars.
 */
export function useGeocode(query: string, enabled: boolean) {
  return useQuery({
    queryKey: ['geocode', query],
    queryFn: () => api.geocode(query),
    enabled: enabled && query.trim().length >= 3,
    staleTime: 24 * 60 * 60 * 1000,
  });
}

export function useCreatePin() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: CreatePinRequest) => api.createPin(body),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['pins'] }),
  });
}

export function useUpdatePin() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { id: string; title: string; notes?: string | null; status: PinStatus }) =>
      api.updatePin(v.id, { title: v.title, notes: v.notes, status: v.status }),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['pins'] }),
  });
}

export function useDeletePin() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => api.deletePin(id),
    onSuccess: () => qc.invalidateQueries({ queryKey: ['pins'] }),
  });
}
