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
  };
}

export function usePins() {
  return useQuery({ queryKey: ['pins'], queryFn: api.listPins });
}

export function useMeta() {
  return useQuery({ queryKey: ['meta'], queryFn: api.meta, staleTime: Infinity });
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
