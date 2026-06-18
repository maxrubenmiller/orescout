import { useMutation, useQuery, useQueryClient } from '@tanstack/react-query';
import { api } from './api';
import type { CreatePinRequest, LatLng, PinStatus } from './types';

export function useAssessment(point: LatLng | null) {
  return useQuery({
    queryKey: ['assessment', point?.lat, point?.lng],
    queryFn: () => api.assess(point!.lat, point!.lng),
    enabled: point != null,
    staleTime: 5 * 60 * 1000,
  });
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
